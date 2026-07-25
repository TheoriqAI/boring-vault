// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMorpho } from "src/interfaces/IMorpho.sol";
import { IMidnight } from "src/interfaces/IMidnight.sol";

/**
 * @title ManagerWithMerkleAndTokenBalanceVerification
 * @notice Extends ManagerWithMerkleVerification with an OPTIONAL, opt-in per-call layer that brackets a
 *         merkle-verified batch with vault token-balance snapshots and reverts unless every listed
 *         token's net balance delta meets a caller-supplied minimum.
 * @dev The merkle root still governs WHICH calls are allowed (the anti-malice boundary). The delta check
 *      governs the OUTCOME of the whole batch (execution quality: slippage / MEV / bad fills / fat-finger),
 *      atomically and independently of any per-router `minReturn`. Because the min-deltas are
 *      CALLER-supplied, this does NOT constrain a malicious strategist — the merkle root already does that;
 *      it protects an honest strategist against a hostile environment.
 * @dev Native ETH is not covered (`balanceOf` is ERC20-only) — verify a wrapped token (e.g. WETH) instead.
 * @dev The inherited `manageVaultWithMerkleVerification` (no balance check), Balancer flash-loan path,
 *      admin, and pause behaviour are unchanged. This contract ADDS: (1) the balance-delta entrypoint, and
 *      (2) Morpho flash-loan support — Blue (`morphoFlashLoan`/`onMorphoFlashLoan`, solo) and "Midnight"
 *      (`midnightFlashLoan`/`onFlashLoan`, multi-token). Both use a root-pinned provider (not immutable)
 *      guarded by `expectedFlashLoanCaller`, and repay via approve+pull (`forceApprove`) rather than
 *      Balancer's push model.
 * @dev UNAUDITED — intentionally NOT wired into the deploy scripts. Do not use in production until reviewed.
 * @custom:security-contact security@molecularlabs.io
 */
contract ManagerWithMerkleAndTokenBalanceVerification is ManagerWithMerkleVerification {

    using SafeTransferLib for ERC20;
    using SafeERC20 for IERC20;

    //============================== CONSTANTS ===============================

    /**
     * @notice Value `onFlashLoan` must return or the Midnight provider reverts.
     * @dev keccak256("morpho.midnight.callbackSuccess").
     */
    bytes32 internal constant MIDNIGHT_CALLBACK_SUCCESS =
        0x7f87788ea698181ea4d28d1576d0ba4fc92c0dbe5bf75b43692af2ce91dbaea2;

    //============================== STATE ===============================

    /**
     * @notice The Morpho deployment expected to invoke `onMorphoFlashLoan` during an active flash loan.
     * @dev Set by `morphoFlashLoan` to the (root-pinned) provider it is about to call and cleared when the
     *      loan settles. The callback requires `msg.sender == expectedFlashLoanCaller`, giving the same
     *      caller guarantee as an immutable provider while still allowing any root-authorized Morpho
     *      deployment (Blue, forks, or the future "Midnight" protocol) without a redeploy.
     */
    address internal expectedFlashLoanCaller;

    //============================== STRUCTS ===============================

    /**
     * @notice A single token whose net vault-balance change over the batch is bounded.
     * @param token The ERC20 whose vault balance is snapshotted before and after the batch.
     * @param minDelta Minimum acceptable net delta (after - before). Signed: negative permits a bounded loss.
     */
    struct TokenDeltaCheck {
        address token;
        int256 minDelta;
    }

    //============================== ERRORS ===============================

    error ManagerWithMerkleAndTokenBalanceVerification__InvalidTokenArrayLength();
    error ManagerWithMerkleAndTokenBalanceVerification__TokenDeltaViolation(
        address token, uint256 balanceBefore, uint256 balanceAfter, int256 balanceDelta, int256 minBalanceDelta
    );
    error ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanOnlyCallableByBoringVault();
    error ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanOnlyCallableByProvider();
    error ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanNotInProgress();
    error ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanBadIntentHash();
    error ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanNotExecuted();
    error ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanOnlyCallableByBoringVault();
    error ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanOnlyCallableByProvider();
    error ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanNotInProgress();
    error ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanBadIntentHash();
    error ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanInvalidCaller();
    error ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanNotExecuted();
    error ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanInconsistentInput();

    //============================== EVENTS ===============================

    event BoringVaultManagedWithBalanceVerification(TokenDeltaCheck[] deltaChecks);
    event MorphoFlashLoanInitiated(address indexed provider, address indexed token, uint256 assets);
    event MidnightFlashLoanInitiated(address indexed provider, address[] tokens, uint256[] assets);

    //============================== CONSTRUCTOR ===============================

    constructor(
        address _owner,
        address _vault,
        address _balancerVault
    )
        ManagerWithMerkleVerification(_owner, _vault, _balancerVault)
    { }

    //============================== STRATEGIST FUNCTIONS ===============================

    /**
     * @notice Same as `manageVaultWithMerkleVerification`, but records each listed token's vault balance
     *         before and after the batch and reverts unless every net delta (after - before) is >= the
     *         corresponding caller-supplied minimum (which may be negative to permit a bounded loss).
     * @param manageProofs Merkle proof for each call (see inherited entrypoint).
     * @param decodersAndSanitizers Decoder used to extract the sanitized addresses for each call.
     * @param targets Address each call is made to.
     * @param targetData Calldata for each call.
     * @param values Native value forwarded with each call.
     * @param deltaChecks Tokens whose vault balance delta is bounded across the batch, each with its minimum.
     * @dev Reverts `...__InvalidTokenArrayLength` if `deltaChecks` is empty.
     * @dev Reverts `...__TokenDeltaViolation` if any token's delta falls below its minimum.
     * @dev Callable by STRATEGIST_ROLE (same capability class as the inherited entrypoint).
     */
    function manageVaultWithMerkleAndBalanceVerification(
        bytes32[][] calldata manageProofs,
        address[] calldata decodersAndSanitizers,
        address[] calldata targets,
        bytes[] calldata targetData,
        uint256[] calldata values,
        TokenDeltaCheck[] calldata deltaChecks
    )
        external
        requiresAuth
    {
        if (deltaChecks.length == 0) {
            revert ManagerWithMerkleAndTokenBalanceVerification__InvalidTokenArrayLength();
        }

        // Snapshot, run the merkle-verified batch, then enforce the outcome bounds. The batch and the
        // snapshots share one call frame, so the deltas capture the batch's full net effect (incl. any
        // flash loan, which settles synchronously within it). Split into helpers to avoid stack-too-deep.
        uint256[] memory balancesBefore = _vaultTokenBalances(deltaChecks);
        _runMerkleBatch(manageProofs, decodersAndSanitizers, targets, targetData, values);
        _checkTokenDeltas(deltaChecks, balancesBefore);

        emit BoringVaultManagedWithBalanceVerification(deltaChecks);
    }

    //============================== MORPHO FLASH LOAN FUNCTIONS ===============================

    /**
     * @notice Initiates a Morpho Blue (solo, no-fee) flash loan. Mirrors the inherited Balancer flow:
     *         1) the merkle root must contain a leaf authorizing
     *            `vault.manage(manager, morphoFlashLoan(provider, token, assets, userData))`,
     *         2) the strategist initiates it via a manage entrypoint,
     *         3) `provider` MUST call back into `onMorphoFlashLoan` with the same `userData`.
     * @param morphoProvider The Morpho deployment to borrow from (pinned in the merkle leaf, not immutable).
     * @param token The token to flash-borrow.
     * @param assets The amount to flash-borrow.
     * @param userData ABI-encoded `(token, manageProofs, decodersAndSanitizers, targets, targetData, values)`
     *        — the token repeated so the callback (which is not passed a token) can recover it.
     * @dev Only callable by the BoringVault (i.e. via a merkle-verified manage call), like the inherited
     *      `flashLoan`. The provider is recorded so the callback can verify `msg.sender`.
     */
    function morphoFlashLoan(address morphoProvider, address token, uint256 assets, bytes calldata userData) external {
        if (msg.sender != address(vault)) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanOnlyCallableByBoringVault();
        }

        flashLoanIntentHash = keccak256(userData);
        performingFlashLoan = true;
        expectedFlashLoanCaller = morphoProvider;

        emit MorphoFlashLoanInitiated(morphoProvider, token, assets);
        IMorpho(morphoProvider).flashLoan(token, assets, userData);

        performingFlashLoan = false;
        delete expectedFlashLoanCaller;
        // If the callback did not run (and reset the intent hash), the loan was not executed as intended.
        if (flashLoanIntentHash != bytes32(0)) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanNotExecuted();
        }
    }

    /**
     * @notice Morpho Blue flash-loan callback. Forwards the borrowed token to the vault, runs the
     *         merkle-verified strategy, then claws the exact borrowed amount back and approves the provider
     *         to pull it (Morpho repays via `transferFrom`, unlike Balancer's push model).
     * @dev Guarded three ways: `msg.sender` must be the provider recorded by `morphoFlashLoan`,
     *      `performingFlashLoan` must be set, and `keccak256(data)` must match the single-use intent hash.
     */
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != expectedFlashLoanCaller) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanOnlyCallableByProvider();
        }
        if (!performingFlashLoan) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanNotInProgress();
        }
        if (keccak256(data) != flashLoanIntentHash) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanBadIntentHash();
        }
        // Single-use: reset before running the strategy so a re-entrant callback cannot replay it.
        flashLoanIntentHash = bytes32(0);

        _executeMorphoFlashLoan(assets, data, msg.sender);
    }

    //============================== MIDNIGHT FLASH LOAN FUNCTIONS ===============================

    /**
     * @notice Initiates a Morpho "Midnight" (multi-token, no-fee) flash loan. Same shape as the Blue path
     *         but with parallel `tokens`/`assets` arrays, and Midnight sends the funds to — and pulls them
     *         back from — the `callback` contract (this manager), not msg.sender.
     * @param midnightProvider The Midnight deployment to borrow from (pinned in the merkle leaf).
     * @param tokens The tokens to flash-borrow (parallel to `assets`).
     * @param assets The amount of each token to flash-borrow.
     * @param userData ABI-encoded `(manageProofs, decodersAndSanitizers, targets, targetData, values)`. Unlike
     *        the Blue path this does NOT prefix the token(s): the callback receives `tokens`/`assets` directly.
     * @dev Only callable by the BoringVault (via a merkle-verified manage call). `tokens`/`assets` are pinned
     *      by the initiator's merkle leaf and relayed verbatim by the trusted provider to the callback.
     */
    function midnightFlashLoan(
        address midnightProvider,
        address[] calldata tokens,
        uint256[] calldata assets,
        bytes calldata userData
    )
        external
    {
        if (msg.sender != address(vault)) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanOnlyCallableByBoringVault();
        }
        if (tokens.length != assets.length) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanInconsistentInput();
        }

        flashLoanIntentHash = keccak256(userData);
        performingFlashLoan = true;
        expectedFlashLoanCaller = midnightProvider;

        emit MidnightFlashLoanInitiated(midnightProvider, tokens, assets);
        IMidnight(midnightProvider).flashLoan(tokens, assets, address(this), userData);

        performingFlashLoan = false;
        delete expectedFlashLoanCaller;
        if (flashLoanIntentHash != bytes32(0)) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanNotExecuted();
        }
    }

    /**
     * @notice Midnight flash-loan callback. Forwards each borrowed token to the vault, runs the
     *         merkle-verified strategy, then claws each exact amount back and approves the provider to pull
     *         it. MUST return `MIDNIGHT_CALLBACK_SUCCESS` or the provider reverts.
     * @dev Guarded four ways: `msg.sender` must be the provider recorded by `midnightFlashLoan`, `caller`
     *      (the initiator) must be this contract, `performingFlashLoan` must be set, and `keccak256(data)`
     *      must match the single-use intent hash.
     */
    function onFlashLoan(
        address caller,
        address[] calldata tokens,
        uint256[] calldata assets,
        bytes calldata data
    )
        external
        returns (bytes32)
    {
        if (msg.sender != expectedFlashLoanCaller) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanOnlyCallableByProvider();
        }
        if (!performingFlashLoan) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanNotInProgress();
        }
        if (caller != address(this)) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanInvalidCaller();
        }
        if (keccak256(data) != flashLoanIntentHash) {
            revert ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanBadIntentHash();
        }
        flashLoanIntentHash = bytes32(0);

        _executeMidnightFlashLoan(tokens, assets, data, msg.sender);
        return MIDNIGHT_CALLBACK_SUCCESS;
    }

    //============================== INTERNAL HELPERS ===============================

    /**
     * @notice Body of `onMorphoFlashLoan`, split out to keep the callback's stack shallow.
     * @dev The claw-back `vault.manage(token, transfer(this, assets))` is a direct (non-merkle) call, the
     *      same trust posture as the inherited Balancer repayment; it runs inside the guarded callback and
     *      moves exactly the borrowed amount. `forceApprove` (not the removed OZ `safeApprove`) handles the
     *      approve-to-zero-first requirement of non-standard tokens; the allowance nets to zero once Morpho
     *      pulls `assets`.
     */
    function _executeMorphoFlashLoan(uint256 assets, bytes calldata data, address provider) internal {
        (
            address token,
            bytes32[][] memory manageProofs,
            address[] memory decodersAndSanitizers,
            address[] memory targets,
            bytes[] memory targetData,
            uint256[] memory values
        ) = abi.decode(data, (address, bytes32[][], address[], address[], bytes[], uint256[]));

        // Hand the borrowed token to the vault so the strategy can use it.
        ERC20(token).safeTransfer(address(vault), assets);

        // Run the merkle-verified strategy. External self-call (requires this contract to hold the internal
        // manager role), identical to the inherited Balancer `receiveFlashLoan` path.
        ManagerWithMerkleVerification(address(this)).manageVaultWithMerkleVerification(
            manageProofs, decodersAndSanitizers, targets, targetData, values
        );

        // Claw the exact borrowed amount back from the vault, then let Morpho pull it.
        vault.manage(token, abi.encodeWithSelector(ERC20.transfer.selector, address(this), assets), 0);
        IERC20(token).forceApprove(provider, assets);
    }

    /**
     * @notice Body of `onFlashLoan` (Midnight), split out to keep the callback's stack shallow. Forwards
     *         each borrowed token to the vault, runs the strategy, then claws each amount back and approves
     *         the provider. Same trust posture and repayment model as the Blue helper, looped per token.
     */
    function _executeMidnightFlashLoan(
        address[] calldata tokens,
        uint256[] calldata assets,
        bytes calldata data,
        address provider
    )
        internal
    {
        for (uint256 i; i < tokens.length; ++i) {
            ERC20(tokens[i]).safeTransfer(address(vault), assets[i]);
        }

        (
            bytes32[][] memory manageProofs,
            address[] memory decodersAndSanitizers,
            address[] memory targets,
            bytes[] memory targetData,
            uint256[] memory values
        ) = abi.decode(data, (bytes32[][], address[], address[], bytes[], uint256[]));
        ManagerWithMerkleVerification(address(this)).manageVaultWithMerkleVerification(
            manageProofs, decodersAndSanitizers, targets, targetData, values
        );

        for (uint256 i; i < tokens.length; ++i) {
            vault.manage(tokens[i], abi.encodeWithSelector(ERC20.transfer.selector, address(this), assets[i]), 0);
            IERC20(tokens[i]).forceApprove(provider, assets[i]);
        }
    }

    /**
     * @notice Runs a merkle-verified batch. Mirrors the inherited `manageVaultWithMerkleVerification`
     *         body (pause guard, length checks, verify+manage loop, constant-total-supply invariant) so
     *         the whole batch executes inside this contract's call frame rather than via an external
     *         self-call. `_verifyCallData`, `manageRoot`, `isPaused`, and `vault` are inherited.
     */
    function _runMerkleBatch(
        bytes32[][] calldata manageProofs,
        address[] calldata decodersAndSanitizers,
        address[] calldata targets,
        bytes[] calldata targetData,
        uint256[] calldata values
    )
        internal
    {
        if (isPaused) revert ManagerWithMerkleVerification__Paused();
        uint256 targetsLength = targets.length;
        if (targetsLength != manageProofs.length) revert ManagerWithMerkleVerification__InvalidManageProofLength();
        if (targetsLength != targetData.length) revert ManagerWithMerkleVerification__InvalidTargetDataLength();
        if (targetsLength != values.length) revert ManagerWithMerkleVerification__InvalidValuesLength();
        if (targetsLength != decodersAndSanitizers.length) {
            revert ManagerWithMerkleVerification__InvalidDecodersAndSanitizersLength();
        }

        bytes32 strategistManageRoot = manageRoot[msg.sender];
        uint256 totalSupply = vault.totalSupply();
        for (uint256 i; i < targetsLength; ++i) {
            _verifyCallData(
                strategistManageRoot, manageProofs[i], decodersAndSanitizers[i], targets[i], values[i], targetData[i]
            );
            vault.manage(targets[i], targetData[i], values[i]);
        }
        if (totalSupply != vault.totalSupply()) {
            revert ManagerWithMerkleVerification__TotalSupplyMustRemainConstantDuringManagement();
        }
        emit BoringVaultManaged(targetsLength);
    }

    /**
     * @notice Reverts unless every token's net vault-balance delta (after - before) is >= its minimum.
     */
    function _checkTokenDeltas(TokenDeltaCheck[] calldata deltaChecks, uint256[] memory balancesBefore) internal view {
        for (uint256 i; i < deltaChecks.length; ++i) {
            uint256 balanceAfter = ERC20(deltaChecks[i].token).balanceOf(address(vault));
            // Token balances are always < 2^255, so the int256 casts and checked subtraction cannot overflow.
            int256 balanceDelta = int256(balanceAfter) - int256(balancesBefore[i]);
            if (balanceDelta < deltaChecks[i].minDelta) {
                revert ManagerWithMerkleAndTokenBalanceVerification__TokenDeltaViolation(
                    deltaChecks[i].token, balancesBefore[i], balanceAfter, balanceDelta, deltaChecks[i].minDelta
                );
            }
        }
    }

    /**
     * @notice Returns the BoringVault's balance of each token in `deltaChecks`.
     */
    function _vaultTokenBalances(TokenDeltaCheck[] calldata deltaChecks)
        internal
        view
        returns (uint256[] memory balances)
    {
        balances = new uint256[](deltaChecks.length);
        for (uint256 i; i < deltaChecks.length; ++i) {
            balances[i] = ERC20(deltaChecks[i].token).balanceOf(address(vault));
        }
    }

}
