// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { IDepositPolicy } from "src/interfaces/IDepositPolicy.sol";
import { IERC7540Deposit } from "src/interfaces/IERC7540Deposit.sol";

/**
 * @title EpochDepositor  (DRAFT — NOT AUDITED, NOT WIRED INTO DEPLOY)
 * @notice Epoch-batched, ERC-7540-aligned asynchronous depositor for a BoringVault. Users `requestDeposit`
 *         a single base asset into the current open epoch (assets escrowed here). After the epoch's
 *         settle time anyone calls `closeEpoch`, which snapshots the accountant rate, mints the whole
 *         epoch's shares at that ONE clearing price, and opens the next epoch. Depositors then `claim`
 *         (or are pushed via `disperse`) their pro-rata shares.
 *
 * @dev Requirement mapping:
 *      (a) `deposited[epoch][controller]` accumulates on request and decrements on cancel; a request must
 *          leave the running total >= `minDepositPerEpoch`.
 *      (b) a partial cancel that would leave 0 < remaining < min reverts — the controller stays above the
 *          floor or exits fully via `cancelAll` (no dust positions).
 *      (c) `closeEpoch` clears the whole epoch at a single accountant-rate snapshot.
 *      (d) epoch settlement timing is retunable, but frozen within `GUARD_WINDOW` (24h) of settlement.
 *      + refunds (cancel, or `refundEpoch` for a stuck settlement), a pluggable `IDepositPolicy` auth hook
 *      (predicate/attestation-friendly), a trusted `atomicMint` (sync, optional fee), permissionless
 *      `disperse` batch claim, and the ERC-7540 deposit surface.
 *
 * @dev Roles use `requiresAuth` (no hardcoded roles). The contract must be granted the BoringVault's
 *      `enter` capability so it can mint at settlement/atomic-mint. Deposit caps/asset-support are NOT
 *      re-checked here (single configured asset + accountant rate only). Claim rounding dust (sub-wei
 *      shares) accrues to this contract.
 * @dev ASSUMPTIONS / KNOWN LIMITS (audited draft):
 *      - Fee-on-transfer and rebasing deposit assets are NOT supported. Request/atomic-mint credit the
 *        actual received balance so escrow accounting stays consistent, but settlement mints against the
 *        nominal amount, so a fee-on-transfer asset would under-collateralize the vault. Use a standard ERC20.
 *      - The accountant is trusted; `closeEpoch`/`atomicMint` guard only the degenerate zero-shares case
 *        (a bad rate reverts, leaving the epoch recoverable via `refundEpoch`).
 *      - `retimeCurrentEpoch` guarantees >= GUARD_WINDOW of certainty measured from the retime; outside the
 *        window an operator may still bring a far-out settlement in to `now + GUARD_WINDOW` (never sooner,
 *        never into the past).
 *      - ERC-7540 allows crediting a `controller != owner` ("gifting"); a griefer can bloat a victim's
 *        `_liveEpochs` and force `AmbiguousClaim` on the `deposit`/`mint` convenience path. The victim is
 *        unharmed (they keep the gifted assets) and always claims via `claim(epoch, ...)`.
 * @custom:security-contact security@molecularlabs.io
 */
contract EpochDepositor is Auth, ReentrancyGuard, IERC7540Deposit {

    using SafeTransferLib for ERC20;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    //============================== CONSTANTS ===============================

    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_ATOMIC_FEE_BPS = 1000; // hard 10% ceiling on the atomic-mint fee
    uint64 public constant GUARD_WINDOW = 24 hours; // settlement timing frozen this long before settle

    //============================== IMMUTABLES ===============================

    ERC20 public immutable depositAsset; // the single asset accepted (ERC-7540 asset())
    BoringVault public immutable vault; // the share token (ERC-7540 share())
    AccountantWithRateProviders public immutable accountant;
    uint256 internal immutable ONE_SHARE; // 10 ** vault.decimals()

    //============================== STRUCTS ===============================

    /**
     * @param start when the epoch opened.
     * @param settleTime when the epoch becomes closeable (and its timing freezes GUARD_WINDOW before).
     * @param settled whether `closeEpoch` has run.
     * @param refundable whether settlement is abandoned and deposits can be reclaimed via `refundEpoch`.
     * @param totalAssets total assets deposited (net of cancels); fixed once settled.
     * @param sharesMinted shares minted for the epoch at close.
     * @param clearingRate accountant rate snapshot at close (asset per share, in asset decimals).
     */
    struct Epoch {
        uint64 start;
        uint64 settleTime;
        bool settled;
        bool refundable;
        uint256 totalAssets;
        uint256 sharesMinted;
        uint256 clearingRate;
    }

    //============================== STATE ===============================

    uint256 public currentEpoch; // the open epoch accepting deposits
    uint256 public minDepositPerEpoch; // per-controller floor within an epoch (0 = no floor)
    uint64 public epochDuration; // length applied to newly opened epochs
    IDepositPolicy public depositPolicy; // 0 = permissionless
    address public feeRecipient; // atomic-mint fee sink
    uint16 public atomicFeeBps; // optional fee on atomicMint

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => mapping(address => uint256)) public deposited; // epoch => controller => assets
    mapping(address => mapping(address => bool)) public isOperator; // controller => operator => approved

    // enumerable set of epochs a controller currently has a live (unclaimed) position in
    mapping(address => uint256[]) internal _liveEpochs;
    mapping(address => mapping(uint256 => uint256)) internal _liveIdx; // controller => epoch => index+1

    //============================== ERRORS ===============================

    error EpochDepositor__ZeroAddress();
    error EpochDepositor__EpochNotOpen();
    error EpochDepositor__BelowMinimum();
    error EpochDepositor__NothingToCancel();
    error EpochDepositor__NotYetSettleable();
    error EpochDepositor__AlreadySettled();
    error EpochDepositor__NotSettled();
    error EpochDepositor__NothingClaimable();
    error EpochDepositor__AmbiguousClaim();
    error EpochDepositor__ClaimMismatch();
    error EpochDepositor__Unauthorized();
    error EpochDepositor__TimingGuardActive();
    error EpochDepositor__InvalidTiming();
    error EpochDepositor__FeeTooHigh();
    error EpochDepositor__MinSharesNotMet();
    error EpochDepositor__NotRefundable();
    error EpochDepositor__ZeroAmount();

    //============================== EVENTS ===============================

    event EpochOpened(uint256 indexed epoch, uint64 start, uint64 settleTime);
    event DepositCancelled(uint256 indexed epoch, address indexed controller, uint256 assets, bool full);
    event EpochSettled(uint256 indexed epoch, uint256 totalAssets, uint256 sharesMinted, uint256 clearingRate);
    event Claimed(uint256 indexed epoch, address indexed controller, address indexed receiver, uint256 shares);
    event EpochMarkedRefundable(uint256 indexed epoch);
    event Refunded(uint256 indexed epoch, address indexed controller, uint256 assets);
    event AtomicMinted(address indexed caller, address indexed receiver, uint256 assetsIn, uint256 shares, uint256 fee);
    event MinDepositUpdated(uint256 minDeposit);
    event EpochDurationUpdated(uint64 duration);
    event EpochRetimed(uint256 indexed epoch, uint64 settleTime);
    event DepositPolicyUpdated(address policy);
    event FeeConfigUpdated(address feeRecipient, uint16 atomicFeeBps);

    //============================== CONSTRUCTOR ===============================

    constructor(
        address _owner,
        address _vault,
        address _accountant,
        address _depositAsset,
        uint64 _epochDuration,
        uint256 _minDepositPerEpoch,
        address _feeRecipient
    )
        Auth(_owner, Authority(address(0)))
    {
        if (_vault == address(0) || _accountant == address(0) || _depositAsset == address(0)) {
            revert EpochDepositor__ZeroAddress();
        }
        if (_epochDuration == 0) revert EpochDepositor__InvalidTiming();
        vault = BoringVault(payable(_vault));
        accountant = AccountantWithRateProviders(_accountant);
        depositAsset = ERC20(_depositAsset);
        ONE_SHARE = 10 ** ERC20(_vault).decimals();
        epochDuration = _epochDuration;
        minDepositPerEpoch = _minDepositPerEpoch;
        feeRecipient = _feeRecipient;
        _openEpoch(0);
    }

    //============================== ADMIN (requiresAuth) ===============================

    /// @notice Sets the per-controller minimum deposit within an epoch. Applies to future requests only.
    function setMinDepositPerEpoch(uint256 newMin) external requiresAuth {
        minDepositPerEpoch = newMin;
        emit MinDepositUpdated(newMin);
    }

    /// @notice Sets the duration applied to newly opened epochs (does not retime the current one).
    /// @dev Must be non-zero, else a future epoch would open already-closeable (zero deposit window).
    function setEpochDuration(uint64 newDuration) external requiresAuth {
        if (newDuration == 0) revert EpochDepositor__InvalidTiming();
        epochDuration = newDuration;
        emit EpochDurationUpdated(newDuration);
    }

    /// @notice Retimes the current open epoch's settlement. Frozen within GUARD_WINDOW of the current
    ///         settle time, and the new time must itself be at least GUARD_WINDOW out — so depositors get
    ///         >= 24h of certainty before their epoch clears (requirement d).
    function retimeCurrentEpoch(uint64 newSettleTime) external requiresAuth {
        Epoch storage e = epochs[currentEpoch];
        if (e.settled) revert EpochDepositor__AlreadySettled();
        if (block.timestamp + GUARD_WINDOW > e.settleTime) revert EpochDepositor__TimingGuardActive();
        if (newSettleTime < block.timestamp + GUARD_WINDOW || newSettleTime <= e.start) {
            revert EpochDepositor__InvalidTiming();
        }
        e.settleTime = newSettleTime;
        emit EpochRetimed(currentEpoch, newSettleTime);
    }

    /// @notice Sets the compliance policy hook (0 = permissionless).
    function setDepositPolicy(address newPolicy) external requiresAuth {
        depositPolicy = IDepositPolicy(newPolicy);
        emit DepositPolicyUpdated(newPolicy);
    }

    /// @notice Sets the atomic-mint fee recipient and rate (bps, capped at MAX_ATOMIC_FEE_BPS).
    function setFeeConfig(address newFeeRecipient, uint16 newAtomicFeeBps) external requiresAuth {
        if (newAtomicFeeBps > MAX_ATOMIC_FEE_BPS) revert EpochDepositor__FeeTooHigh();
        if (newAtomicFeeBps > 0 && newFeeRecipient == address(0)) revert EpochDepositor__ZeroAddress();
        feeRecipient = newFeeRecipient;
        atomicFeeBps = newAtomicFeeBps;
        emit FeeConfigUpdated(newFeeRecipient, newAtomicFeeBps);
    }

    /// @notice Abandons settlement of the stuck current epoch (e.g. mint permanently reverts), unlocking
    ///         `refund` for its depositors and opening the next epoch so the queue keeps moving.
    /// @dev Only when the current epoch's settle time has passed but it has not settled. Only the current
    ///      epoch can be unsettled (all prior epochs are settled before the queue advances).
    function refundEpoch() external requiresAuth {
        uint256 epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        if (e.settled) revert EpochDepositor__AlreadySettled();
        if (block.timestamp < e.settleTime) revert EpochDepositor__NotYetSettleable();
        e.refundable = true;
        emit EpochMarkedRefundable(epoch);
        _openEpoch(epoch + 1);
    }

    //============================== ERC-7540: REQUEST / CANCEL ===============================

    /// @inheritdoc IERC7540Deposit
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256) {
        return _requestDeposit(assets, controller, owner, "");
    }

    /// @notice Request variant carrying an authorization payload for the deposit policy (e.g. a predicate
    ///         attestation). Behaves identically to the ERC-7540 `requestDeposit` otherwise.
    function requestDeposit(
        uint256 assets,
        address controller,
        address owner,
        bytes calldata authData
    )
        external
        returns (uint256)
    {
        return _requestDeposit(assets, controller, owner, authData);
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev Full cancel of the controller's position in the current open epoch.
    function cancelDepositRequest(uint256 requestId, address controller) external {
        _cancel(requestId, controller, deposited[requestId][controller]);
    }

    /// @notice Cancels `assets` of the controller's position in the current open epoch. Reverts if the
    ///         remaining position would be non-zero but below `minDepositPerEpoch` (requirement b).
    function cancelDeposit(uint256 assets, address controller) external {
        _cancel(currentEpoch, controller, assets);
    }

    /// @notice Full cancel of the controller's position in the current open epoch.
    function cancelAll(address controller) external {
        _cancel(currentEpoch, controller, deposited[currentEpoch][controller]);
    }

    //============================== SETTLEMENT ===============================

    /// @notice Permissionlessly settles the current epoch at one accountant-rate snapshot and opens the
    ///         next. Callable once the epoch's settle time has passed (requirement c).
    function closeEpoch() external nonReentrant returns (uint256 sharesMinted) {
        uint256 epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        if (block.timestamp < e.settleTime) revert EpochDepositor__NotYetSettleable();
        if (e.settled) revert EpochDepositor__AlreadySettled(); // unreachable (settled epoch isn't current)

        uint256 total = e.totalAssets;
        uint256 rate = accountant.getRateInQuoteSafe(depositAsset); // asset per share, snapshotted
        if (total > 0) {
            sharesMinted = total.mulDivDown(ONE_SHARE, rate);
            // Degenerate rate guard: never sweep assets into the vault for zero shares. Reverting leaves the
            // epoch unsettled and recoverable via `refundEpoch` rather than destroying depositor value.
            if (sharesMinted == 0) revert EpochDepositor__MinSharesNotMet();
            // Mint the whole epoch's shares to this contract; depositors claim their pro-rata slice.
            IERC20(address(depositAsset)).forceApprove(address(vault), total);
            vault.enter(address(this), depositAsset, total, address(this), sharesMinted);
        }
        e.settled = true;
        e.sharesMinted = sharesMinted;
        e.clearingRate = rate;
        emit EpochSettled(epoch, total, sharesMinted, rate);

        _openEpoch(epoch + 1);
    }

    //============================== CLAIM ===============================

    /// @notice Claims the controller's pro-rata shares from a settled epoch to `receiver`.
    function claim(uint256 epoch, address controller, address receiver) public nonReentrant returns (uint256 shares) {
        _checkController(controller);
        shares = _claim(epoch, controller, receiver);
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev Claims the controller's sole settled epoch; `assets` must equal that epoch's claimable.
    function deposit(uint256 assets, address receiver, address controller) external nonReentrant returns (uint256) {
        _checkController(controller);
        uint256 epoch = _soleClaimableEpoch(controller);
        if (deposited[epoch][controller] != assets) revert EpochDepositor__ClaimMismatch();
        return _claim(epoch, controller, receiver);
    }

    /// @inheritdoc IERC7540Deposit
    /// @dev Claims the controller's sole settled epoch; `shares` must equal that epoch's claimable shares.
    function mint(
        uint256 shares,
        address receiver,
        address controller
    )
        external
        nonReentrant
        returns (uint256 assets)
    {
        _checkController(controller);
        uint256 epoch = _soleClaimableEpoch(controller);
        assets = deposited[epoch][controller]; // capture before _claim zeroes it
        if (_previewClaim(epoch, controller) != shares) revert EpochDepositor__ClaimMismatch();
        _claim(epoch, controller, receiver);
    }

    /// @notice Permissionless batch claim: pushes each controller's settled-epoch shares to themselves.
    /// @dev Skips controllers with nothing claimable in `epoch`. Bounded by the caller-supplied array.
    function disperse(uint256 epoch, address[] calldata controllers) external nonReentrant {
        if (!epochs[epoch].settled) revert EpochDepositor__NotSettled();
        for (uint256 i; i < controllers.length; ++i) {
            if (deposited[epoch][controllers[i]] > 0) _claim(epoch, controllers[i], controllers[i]);
        }
    }

    //============================== REFUND ===============================

    /// @notice Reclaims a controller's assets from an epoch marked refundable by `refundEpoch`.
    function refund(uint256 epoch, address controller) external nonReentrant returns (uint256 assets) {
        _checkController(controller);
        if (!epochs[epoch].refundable) revert EpochDepositor__NotRefundable();
        assets = deposited[epoch][controller];
        if (assets == 0) revert EpochDepositor__NothingClaimable();
        deposited[epoch][controller] = 0;
        _removeLive(controller, epoch);
        depositAsset.safeTransfer(controller, assets);
        emit Refunded(epoch, controller, assets);
    }

    //============================== ATOMIC MINT (trusted, requiresAuth) ===============================

    /// @notice Synchronously mints vault shares to `receiver` for `assetsIn` pulled from the caller,
    ///         skipping the epoch queue. An optional fee (`atomicFeeBps`) is skimmed to `feeRecipient`.
    /// @dev Callable only by an authorized (trusted) address. Priced at the live accountant rate.
    function atomicMint(
        address receiver,
        uint256 assetsIn,
        uint256 minShares
    )
        external
        requiresAuth
        nonReentrant
        returns (uint256 shares)
    {
        if (receiver == address(0)) revert EpochDepositor__ZeroAddress();
        if (assetsIn == 0) revert EpochDepositor__ZeroAmount();

        // Pull first, then price the actually-received amount (balance delta).
        uint256 balBefore = depositAsset.balanceOf(address(this));
        depositAsset.safeTransferFrom(msg.sender, address(this), assetsIn);
        uint256 received = depositAsset.balanceOf(address(this)) - balBefore;

        uint256 fee = (uint256(atomicFeeBps) * received) / BPS;
        uint256 net = received - fee;

        uint256 rate = accountant.getRateInQuoteSafe(depositAsset);
        shares = net.mulDivDown(ONE_SHARE, rate);
        // Never mint zero shares for non-zero assets (degenerate rate / dust), and honor the caller's floor.
        if (shares == 0 || shares < minShares) revert EpochDepositor__MinSharesNotMet();

        if (fee > 0) depositAsset.safeTransfer(feeRecipient, fee);
        IERC20(address(depositAsset)).forceApprove(address(vault), net);
        vault.enter(address(this), depositAsset, net, receiver, shares);

        emit AtomicMinted(msg.sender, receiver, received, shares, fee);
    }

    //============================== ERC-7540: OPERATOR ===============================

    /// @inheritdoc IERC7540Deposit
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    //============================== VIEWS ===============================

    /// @inheritdoc IERC7540Deposit
    function asset() external view returns (address) {
        return address(depositAsset);
    }

    /// @inheritdoc IERC7540Deposit
    function share() external view returns (address) {
        return address(vault);
    }

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        return epochs[requestId].settled ? 0 : deposited[requestId][controller];
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        return epochs[requestId].settled ? deposited[requestId][controller] : 0;
    }

    /// @notice The shares a controller would receive by claiming a settled epoch now.
    function previewClaim(uint256 epoch, address controller) external view returns (uint256) {
        if (!epochs[epoch].settled) return 0;
        return _previewClaim(epoch, controller);
    }

    /// @notice The epochs a controller currently holds a live (unclaimed) position in.
    function liveEpochs(address controller) external view returns (uint256[] memory) {
        return _liveEpochs[controller];
    }

    //============================== INTERNAL ===============================

    function _openEpoch(uint256 epoch) internal {
        uint64 start = uint64(block.timestamp);
        uint64 settleTime = start + epochDuration;
        epochs[epoch] = Epoch({
            start: start,
            settleTime: settleTime,
            settled: false,
            refundable: false,
            totalAssets: 0,
            sharesMinted: 0,
            clearingRate: 0
        });
        currentEpoch = epoch;
        emit EpochOpened(epoch, start, settleTime);
    }

    function _requestDeposit(
        uint256 assets,
        address controller,
        address owner,
        bytes memory authData
    )
        internal
        nonReentrant
        returns (uint256 epoch)
    {
        if (assets == 0) revert EpochDepositor__ZeroAmount();
        if (controller == address(0)) revert EpochDepositor__ZeroAddress();
        if (msg.sender != owner && !isOperator[owner][msg.sender]) revert EpochDepositor__Unauthorized();

        epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        if (block.timestamp >= e.settleTime) revert EpochDepositor__EpochNotOpen();

        if (address(depositPolicy) != address(0)) {
            depositPolicy.authorizeDeposit(msg.sender, controller, assets, authData);
        }

        // Credit the actually-received amount (balance delta) so per-controller accounting always sums to
        // the escrowed balance — this closes the refund-drain vector for a fee-on-transfer asset. Such
        // assets are still not supported end-to-end (see the contract notice), but escrow stays consistent.
        uint256 balBefore = depositAsset.balanceOf(address(this));
        depositAsset.safeTransferFrom(owner, address(this), assets);
        uint256 received = depositAsset.balanceOf(address(this)) - balBefore;

        uint256 newBalance = deposited[epoch][controller] + received;
        if (newBalance < minDepositPerEpoch) revert EpochDepositor__BelowMinimum();
        deposited[epoch][controller] = newBalance;
        e.totalAssets += received;
        _addLive(controller, epoch);

        emit DepositRequest(controller, owner, epoch, msg.sender, received);
    }

    function _cancel(uint256 epoch, address controller, uint256 assets) internal nonReentrant {
        _checkController(controller);
        Epoch storage e = epochs[epoch];
        if (e.settled) revert EpochDepositor__AlreadySettled();
        if (block.timestamp >= e.settleTime) revert EpochDepositor__EpochNotOpen();

        uint256 bal = deposited[epoch][controller];
        if (assets == 0 || assets > bal) revert EpochDepositor__NothingToCancel();

        uint256 remaining = bal - assets;
        // No dust: a partial cancel must keep the position at or above the floor (requirement b).
        if (remaining != 0 && remaining < minDepositPerEpoch) revert EpochDepositor__BelowMinimum();

        deposited[epoch][controller] = remaining;
        e.totalAssets -= assets;
        if (remaining == 0) _removeLive(controller, epoch);

        depositAsset.safeTransfer(controller, assets);
        emit DepositCancelled(epoch, controller, assets, remaining == 0);
    }

    function _claim(uint256 epoch, address controller, address receiver) internal returns (uint256 shares) {
        Epoch storage e = epochs[epoch];
        if (!e.settled) revert EpochDepositor__NotSettled();
        if (receiver == address(0)) revert EpochDepositor__ZeroAddress();

        uint256 bal = deposited[epoch][controller];
        if (bal == 0) revert EpochDepositor__NothingClaimable();

        shares = bal.mulDivDown(e.sharesMinted, e.totalAssets);
        deposited[epoch][controller] = 0;
        _removeLive(controller, epoch);
        if (shares > 0) ERC20(address(vault)).safeTransfer(receiver, shares);
        emit Claimed(epoch, controller, receiver, shares);
    }

    function _previewClaim(uint256 epoch, address controller) internal view returns (uint256) {
        Epoch storage e = epochs[epoch];
        if (e.totalAssets == 0) return 0; // settled-but-empty epoch: avoid 0/0
        return deposited[epoch][controller].mulDivDown(e.sharesMinted, e.totalAssets);
    }

    function _soleClaimableEpoch(address controller) internal view returns (uint256 epoch) {
        uint256[] storage live = _liveEpochs[controller];
        bool found;
        for (uint256 i; i < live.length; ++i) {
            if (epochs[live[i]].settled) {
                if (found) revert EpochDepositor__AmbiguousClaim();
                epoch = live[i];
                found = true;
            }
        }
        if (!found) revert EpochDepositor__NothingClaimable();
    }

    function _checkController(address controller) internal view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) revert EpochDepositor__Unauthorized();
    }

    function _addLive(address controller, uint256 epoch) internal {
        if (_liveIdx[controller][epoch] == 0) {
            _liveEpochs[controller].push(epoch);
            _liveIdx[controller][epoch] = _liveEpochs[controller].length;
        }
    }

    function _removeLive(address controller, uint256 epoch) internal {
        uint256 idx = _liveIdx[controller][epoch];
        if (idx == 0) return;
        uint256 len = _liveEpochs[controller].length;
        if (idx != len) {
            uint256 lastEpoch = _liveEpochs[controller][len - 1];
            _liveEpochs[controller][idx - 1] = lastEpoch;
            _liveIdx[controller][lastEpoch] = idx;
        }
        _liveEpochs[controller].pop();
        _liveIdx[controller][epoch] = 0;
    }

}
