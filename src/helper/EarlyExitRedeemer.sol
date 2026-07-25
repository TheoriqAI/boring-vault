// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { IRedeemPolicy } from "src/interfaces/IRedeemPolicy.sol";

/**
 * @title EarlyExitRedeemer  (DRAFT — NOT AUDITED, NOT WIRED INTO DEPLOY)
 * @notice Operator-executed discounted early exit beside the gated interval window, in three flavors:
 *   1. SLICE      (`fillEarlyExit`): exiter gets the uniform fixed-weight asset slice minus a fee.
 *   2. ALL-CASH via UNDERWRITER (`fillAllCash`): exiter gets a single payout stable; a third-party
 *      underwriter buys the illiquid legs (EIP-712 dual-consent) and funds the illiquid portion.
 *   3. ALL-CASH from VAULT (`fillAllCashFromVault`): the VAULT underwrites — it funds the cash from its
 *      stable sleeve and KEEPS the illiquid, capturing the WHOLE fee for remaining holders (the extra
 *      spread an external underwriter would otherwise take). The operator's "front-of-line" lever.
 *
 * @dev In every mode the discount ACCRETES to the vault (fee's worth of assets returned to `shareToken`);
 *      shares are fully burned via teller.bulkWithdraw (needs SOLVER_ROLE). Fills are `requiresAuth` — wire
 *      the caller via the RolesAuthority: RECOMMENDED to gate to a dedicated operator/executor role (the
 *      approved party gates WHEN to execute, which with `maxNavAge` freshness, the fee band, the exiter's
 *      self-signed `minStableOut`, and the per-period cap is the anti-arb defense). It CAN be made public
 *      (`setPublicCapability`) if you accept that a permissionless filler can time a stale NAV; the owner
 *      always passes. A third-party underwriter still funds via signature and can never self-execute.
 *      Accretion invariant (external-underwriter mode): fee f must cover the underwriter haircut on the
 *      illiquid portion, f >= illiquidWeight * u, enforced on-chain as `cashPot >= payout`.
 *
 * SECURITY: design sketch; unaudited. Keep the fee band tight, the per-period cap small, and the operator/
 *      underwriter trusted/timelocked.
 */
contract EarlyExitRedeemer is Auth, ReentrancyGuard {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_FEE_BPS = 2_000; // hard 20% ceiling on the discount band (fat-finger guard)

    struct BasketLeg {
        ERC20 asset;
        uint16 weightBps;
        bool illiquid; // true => routed to the underwriter in the external-underwriter all-cash mode
    }

    struct Order {
        address user;
        uint256 shares;
        uint16 maxFeeBps; // worst discount the user will accept
        bool closed;
        bool allowAllCash; // exiter opted into all-cash fills
        uint256 minStableOut; // exiter self-signed floor on the stable payout (0 if not opted in)
    }

    /// @dev Underwriter's EIP-712-signed bid for an external all-cash fill.
    struct UnderwriterBid {
        address underwriter;
        uint256 cashIn; // exact payout-stable the underwriter pays (cannot be exceeded)
        ERC20[] illiquidAssets; // preimage of illiquidTermsHash; must equal the basket's illiquid legs in order
        uint256[] minUnits; // per-illiquid-asset minimum units the underwriter must receive
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @dev Chain- and contract-bound to prevent cross-chain / cross-contract replay (WithdrawQueue style).
    bytes32 public constant FILL_ALL_CASH_TYPEHASH = keccak256(
        "FillAllCash(uint256 orderId,address payoutStable,uint256 cashIn,bytes32 illiquidTermsHash,address underwriter,uint256 nonce,uint256 deadline,address verifyingContract,uint256 chainId)"
    );

    TellerWithMultiAssetSupport public immutable teller;
    AccountantWithRateProviders public immutable accountant;
    BoringVault public immutable shareToken;
    uint256 public immutable ONE_SHARE;

    BasketLeg[] public basket; // uniform fixed-weight slice; weights sum to BPS
    uint16 public feeMinBps; // discount band floor (protects stayers), > 0
    uint16 public feeMaxBps; // discount band ceiling (protects exiters), <= MAX_FEE_BPS
    uint64 public maxNavAge; // max accountant-NAV age to fill; 0 => off
    uint256 public minRequestShares; // per-order dust floor
    IRedeemPolicy public policy; // optional KYC hook, checked at request and fill

    // all-cash config
    ERC20 public payoutStable; // the single cash asset all-cash exiters receive
    uint16 public maxUnderwriterHaircutBps; // hard ceiling on the external underwriter haircut; 0 => off
    bool public underwriterAllowlistEnabled;
    mapping(address => bool) public allowedUnderwriter;
    mapping(address => uint256) public underwriterNonces;

    // per-period volume cap (rolling window)
    uint256 public maxSharesPerPeriod; // 0 => uncapped
    uint64 public periodLength;
    uint64 public periodStart;
    uint256 public sharesFilledInPeriod;

    mapping(uint256 => Order) public orders;
    uint256 public orderCount;

    event Requested(uint256 indexed orderId, address indexed user, uint256 shares, uint16 maxFeeBps, bool allCash);
    event Cancelled(uint256 indexed orderId, address indexed user, uint256 shares);
    event Filled(uint256 indexed orderId, address indexed user, uint256 shares, uint16 feeBps);
    event FilledAllCash(
        uint256 indexed orderId,
        address indexed user,
        address indexed underwriter, // == address(shareToken) when the vault underwrote
        uint256 shares,
        uint16 feeBps,
        uint256 payout,
        uint256 remainderToVault
    );
    event BasketUpdated();
    event FeeBandUpdated(uint16 feeMinBps, uint16 feeMaxBps);
    event MaxNavAgeUpdated(uint64 maxNavAge);
    event PeriodCapUpdated(uint256 maxSharesPerPeriod, uint64 periodLength);
    event MinRequestSharesUpdated(uint256 minRequestShares);
    event PolicyUpdated(IRedeemPolicy indexed policy);
    event PayoutStableUpdated(ERC20 indexed payoutStable);
    event MaxUnderwriterHaircutUpdated(uint16 bps);
    event UnderwriterUpdated(address indexed underwriter, bool allowed);
    event UnderwriterAllowlistToggled(bool enabled);

    error ZeroAddress();
    error ZeroShares();
    error BelowMinRequest(uint256 shares, uint256 min);
    error EmptyBasket();
    error BadWeights(uint256 sum);
    error AssetNotWithdrawSupported(ERC20 asset);
    error NoPricing(ERC20 asset);
    error DuplicateAsset(ERC20 asset);
    error BadFeeBand();
    error BadPeriodCap();
    error BadHaircut();
    error OrderClosed(uint256 orderId);
    error NotOrderOwner(uint256 orderId);
    error FeeOutOfBand(uint16 feeBps);
    error NavStale();
    error PeriodCapExceeded();
    error MinOutLengthMismatch();
    error SlippageOut(uint256 out, uint256 minOut);
    error OrderTooSmallForSlice();
    error NotOptedIntoAllCash(uint256 orderId);
    error PayoutStableNotSet();
    error LiquidLegNotPayoutStable(ERC20 asset);
    error UnderwriterNotAllowed(address underwriter);
    error BadUnderwriterSig(address recovered, address expected);
    error UnderwriterNonceMismatch(uint256 got, uint256 expected);
    error SigExpired(uint256 deadline);
    error IlliquidTermsMismatch();
    error UnderwriterMinUnits(uint256 idx, uint256 got, uint256 min);
    error HaircutTooDeep();
    error HaircutNotSet();
    error AccretionViolation(uint256 cashPot, uint256 payout);

    constructor(
        address _owner,
        TellerWithMultiAssetSupport _teller
    )
        Auth(_owner, Authority(address(0)))
    {
        if (_owner == address(0) || address(_teller) == address(0)) revert ZeroAddress();
        teller = _teller;
        accountant = _teller.accountant();
        shareToken = _teller.vault();
        ONE_SHARE = 10 ** shareToken.decimals();
        underwriterAllowlistEnabled = true; // vetted counterparties only, by default
    }

    // ============================================ ADMIN ============================================

    function setBasket(BasketLeg[] calldata legs) external requiresAuth {
        if (legs.length == 0) revert EmptyBasket();
        delete basket;
        uint256 sum;
        for (uint256 i; i < legs.length; ++i) {
            ERC20 asset = legs[i].asset;
            _requirePricing(asset);
            for (uint256 j; j < i; ++j) {
                if (legs[j].asset == asset) revert DuplicateAsset(asset);
            }
            // Liquid legs must be the single payout stable (so the all-cash payout is one asset).
            if (!legs[i].illiquid && address(payoutStable) != address(0) && asset != payoutStable) {
                revert LiquidLegNotPayoutStable(asset);
            }
            sum += legs[i].weightBps;
            basket.push(legs[i]);
        }
        if (sum != BPS) revert BadWeights(sum);
        emit BasketUpdated();
    }

    function setFeeBand(uint16 _feeMinBps, uint16 _feeMaxBps) external requiresAuth {
        if (_feeMinBps == 0 || _feeMinBps > _feeMaxBps || _feeMaxBps > MAX_FEE_BPS) revert BadFeeBand();
        feeMinBps = _feeMinBps;
        feeMaxBps = _feeMaxBps;
        emit FeeBandUpdated(_feeMinBps, _feeMaxBps);
    }

    function setMaxNavAge(uint64 v) external requiresAuth {
        maxNavAge = v;
        emit MaxNavAgeUpdated(v);
    }

    function setPeriodCap(uint256 _maxSharesPerPeriod, uint64 _periodLength) external requiresAuth {
        if (_maxSharesPerPeriod != 0 && _periodLength == 0) revert BadPeriodCap();
        maxSharesPerPeriod = _maxSharesPerPeriod;
        periodLength = _periodLength;
        if (periodStart == 0) periodStart = uint64(block.timestamp);
        emit PeriodCapUpdated(_maxSharesPerPeriod, _periodLength);
    }

    function setMinRequestShares(uint256 v) external requiresAuth {
        minRequestShares = v;
        emit MinRequestSharesUpdated(v);
    }

    function setPolicy(IRedeemPolicy p) external requiresAuth {
        policy = p;
        emit PolicyUpdated(p);
    }

    function setPayoutStable(ERC20 s) external requiresAuth {
        _requirePricing(s);
        // Any already-configured liquid leg must equal the new payout stable.
        uint256 n = basket.length;
        for (uint256 i; i < n; ++i) {
            if (!basket[i].illiquid && basket[i].asset != s) revert LiquidLegNotPayoutStable(basket[i].asset);
        }
        payoutStable = s;
        emit PayoutStableUpdated(s);
    }

    function setMaxUnderwriterHaircut(uint16 bps) external requiresAuth {
        if (bps > BPS) revert BadHaircut();
        maxUnderwriterHaircutBps = bps;
        emit MaxUnderwriterHaircutUpdated(bps);
    }

    function setUnderwriter(address u, bool ok) external requiresAuth {
        if (u == address(0)) revert ZeroAddress();
        allowedUnderwriter[u] = ok;
        emit UnderwriterUpdated(u, ok);
    }

    function setUnderwriterAllowlistEnabled(bool on) external requiresAuth {
        underwriterAllowlistEnabled = on;
        emit UnderwriterAllowlistToggled(on);
    }

    // =========================================== REQUESTS =========================================

    function requestEarlyExit(uint256 shares, uint16 maxFeeBps) external nonReentrant returns (uint256) {
        return _request(shares, maxFeeBps, false, 0, "");
    }

    function requestEarlyExit(
        uint256 shares,
        uint16 maxFeeBps,
        bytes calldata authData
    )
        external
        nonReentrant
        returns (uint256)
    {
        return _request(shares, maxFeeBps, false, 0, authData);
    }

    /// @notice Opt into all-cash fills, self-signing the minimum stable payout you'll accept.
    function requestEarlyExitAllCash(
        uint256 shares,
        uint16 maxFeeBps,
        uint256 minStableOut
    )
        external
        nonReentrant
        returns (uint256)
    {
        return _request(shares, maxFeeBps, true, minStableOut, "");
    }

    function requestEarlyExitAllCash(
        uint256 shares,
        uint16 maxFeeBps,
        uint256 minStableOut,
        bytes calldata authData
    )
        external
        nonReentrant
        returns (uint256)
    {
        return _request(shares, maxFeeBps, true, minStableOut, authData);
    }

    function _request(
        uint256 shares,
        uint16 maxFeeBps,
        bool allowAllCash,
        uint256 minStableOut,
        bytes memory authData
    )
        internal
        returns (uint256 orderId)
    {
        if (shares == 0) revert ZeroShares();
        if (shares < minRequestShares) revert BelowMinRequest(shares, minRequestShares);
        if (basket.length == 0) revert EmptyBasket();

        if (address(policy) != address(0)) policy.authorizeRedeem(msg.sender, msg.sender, shares, authData);

        ERC20(address(shareToken)).safeTransferFrom(msg.sender, address(this), shares);
        orderId = ++orderCount;
        orders[orderId] = Order({
            user: msg.sender,
            shares: shares,
            maxFeeBps: maxFeeBps,
            closed: false,
            allowAllCash: allowAllCash,
            minStableOut: minStableOut
        });
        emit Requested(orderId, msg.sender, shares, maxFeeBps, allowAllCash);
    }

    function cancelEarlyExit(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.closed || o.shares == 0) revert OrderClosed(orderId);
        if (o.user != msg.sender) revert NotOrderOwner(orderId);
        o.closed = true;
        uint256 s = o.shares;
        ERC20(address(shareToken)).safeTransfer(msg.sender, s);
        emit Cancelled(orderId, msg.sender, s);
    }

    // ==================================== FILL: PROPORTIONAL SLICE =================================

    function fillEarlyExit(uint256 orderId, uint16 feeBps, uint256[] calldata minOut) external nonReentrant requiresAuth {
        _fill(orderId, feeBps, minOut, "");
    }

    function fillEarlyExit(
        uint256 orderId,
        uint16 feeBps,
        uint256[] calldata minOut,
        bytes calldata authData
    )
        external
        nonReentrant
        requiresAuth
    {
        _fill(orderId, feeBps, minOut, authData);
    }

    function _fill(uint256 orderId, uint16 feeBps, uint256[] calldata minOut, bytes memory authData) internal {
        Order storage o = orders[orderId];
        (uint256 S, address user) = _beginFill(o, orderId, feeBps, authData);
        uint256 n = basket.length;
        if (minOut.length != n) revert MinOutLengthMismatch();
        _consumePeriod(S);
        o.closed = true;

        uint256[] memory legShares = _split(S, n);
        for (uint256 i; i < n; ++i) {
            if (legShares[i] != 0) _deliverLeg(basket[i].asset, legShares[i], feeBps, user, minOut[i]);
        }
        emit Filled(orderId, user, S, feeBps);
    }

    /// @dev Redeem one leg to this contract, pay the exiter (1-fee) of it, return the fee to the vault.
    function _deliverLeg(ERC20 asset, uint256 ls, uint16 feeBps, address user, uint256 minOut) internal {
        uint256 before = asset.balanceOf(address(this));
        teller.bulkWithdraw(asset, ls, 0, address(this));
        uint256 got = asset.balanceOf(address(this)) - before; // measured (FoT-safe)
        if (got == 0) revert OrderTooSmallForSlice();

        uint256 userAmt = got.mulDivDown(BPS - feeBps, BPS);
        if (userAmt < minOut) revert SlippageOut(userAmt, minOut);
        if (userAmt > 0) asset.safeTransfer(user, userAmt);
        uint256 feeAmt = got - userAmt;
        if (feeAmt > 0) asset.safeTransfer(address(shareToken), feeAmt);
    }

    // ================================ FILL: ALL-CASH (VAULT UNDERWRITES) ===========================

    /**
     * @notice All-cash exit funded by the VAULT's stable sleeve: redeem the order against `payoutStable`
     *         (the vault keeps the illiquid), pay the exiter `S·NAV·(1−fee)`, accrete the WHOLE fee to
     *         the vault. The "front-of-line" mode — stayers capture the full spread, at the cost of
     *         funding cash from the sleeve and holding the illiquid.
     */
    function fillAllCashFromVault(
        uint256 orderId,
        uint16 feeBps,
        uint256 minStableOut,
        bytes calldata authData
    )
        external
        nonReentrant
        requiresAuth
    {
        Order storage o = orders[orderId];
        (uint256 S, address user) = _beginAllCash(o, orderId, feeBps, authData);
        _consumePeriod(S);
        o.closed = true;

        uint256 before = payoutStable.balanceOf(address(this));
        teller.bulkWithdraw(payoutStable, S, 0, address(this)); // redeems S shares against the stable sleeve
        uint256 got = payoutStable.balanceOf(address(this)) - before;
        if (got == 0) revert OrderTooSmallForSlice();

        uint256 payout = got.mulDivDown(BPS - feeBps, BPS);
        if (payout < o.minStableOut) revert SlippageOut(payout, o.minStableOut); // exiter's self-signed floor
        if (payout < minStableOut) revert SlippageOut(payout, minStableOut); // operator's execution floor
        if (payout > 0) payoutStable.safeTransfer(user, payout);
        uint256 remainder = got - payout;
        if (remainder > 0) payoutStable.safeTransfer(address(shareToken), remainder); // whole fee accretes to vault

        emit FilledAllCash(orderId, user, address(shareToken), S, feeBps, payout, remainder);
    }

    // ============================== FILL: ALL-CASH (EXTERNAL UNDERWRITER) ==========================

    /**
     * @notice All-cash exit funded by a third-party underwriter who buys the illiquid legs. Dual consent:
     *         operator executes (`requiresAuth`, gates WHEN → anti-arb), underwriter EIP-712-signs the exact
     *         terms (fixes cashIn + min illiquid units + nonce + deadline). Exiter gets `S·NAV·(1−fee)` in
     *         payout stable; the fee net of the underwriter haircut accretes to the vault.
     */
    function fillAllCash(
        uint256 orderId,
        uint16 feeBps,
        UnderwriterBid calldata bid,
        bytes calldata authData
    )
        external
        nonReentrant
        requiresAuth
    {
        Order storage o = orders[orderId];
        (uint256 S, address user) = _beginAllCash(o, orderId, feeBps, authData);
        _verifyUnderwriterBid(orderId, S, bid);
        _consumePeriod(S);
        o.closed = true;

        uint256 payout = _sharesToStable(S).mulDivDown(BPS - feeBps, BPS);
        if (payout < o.minStableOut) revert SlippageOut(payout, o.minStableOut);

        uint256 cashPot = _redeemRouteAndPull(S, bid);
        if (cashPot < payout) revert AccretionViolation(cashPot, payout); // realized f >= illiquidWeight*u

        if (payout > 0) payoutStable.safeTransfer(user, payout);
        uint256 remainder = cashPot - payout;
        if (remainder > 0) payoutStable.safeTransfer(address(shareToken), remainder);

        emit FilledAllCash(orderId, user, bid.underwriter, S, feeBps, payout, remainder);
    }

    /// @dev Redeem all legs to this contract, route illiquid legs to the underwriter, pull the underwriter's
    /// cash, and return the realized payout-stable pot held for this fill (measured, FoT-safe).
    function _redeemRouteAndPull(uint256 S, UnderwriterBid calldata bid) internal returns (uint256 cashPot) {
        uint256 n = basket.length;
        uint256[] memory legShares = _split(S, n);
        uint256 stableBefore = payoutStable.balanceOf(address(this));
        uint256 illiquidIdx;
        for (uint256 i; i < n; ++i) {
            uint256 ls = legShares[i];
            // Never skip a leg here: skipping an illiquid leg would desync illiquidIdx from the signed
            // minUnits[]. A zero-share leg means the order is too small for this basket => revert.
            if (ls == 0) revert OrderTooSmallForSlice();
            ERC20 asset = basket[i].asset;
            uint256 before = asset.balanceOf(address(this));
            teller.bulkWithdraw(asset, ls, 0, address(this));
            uint256 got = asset.balanceOf(address(this)) - before;
            if (got == 0) revert OrderTooSmallForSlice();
            if (basket[i].illiquid) {
                if (got < bid.minUnits[illiquidIdx]) revert UnderwriterMinUnits(illiquidIdx, got, bid.minUnits[illiquidIdx]);
                ++illiquidIdx;
                asset.safeTransfer(bid.underwriter, got); // illiquid goes to the underwriter
            }
            // liquid legs are payoutStable and simply accumulate in this contract
        }
        payoutStable.safeTransferFrom(bid.underwriter, address(this), bid.cashIn); // underwriter's cash for the illiquid
        cashPot = payoutStable.balanceOf(address(this)) - stableBefore;
    }

    // ========================================= FILL HELPERS =======================================

    /// @dev Shared entry checks for any fill: order open, fee band, NAV fresh, policy re-check. Returns (S, user).
    function _beginFill(
        Order storage o,
        uint256 orderId,
        uint16 feeBps,
        bytes memory authData
    )
        internal
        returns (uint256 S, address user)
    {
        if (o.closed || o.shares == 0) revert OrderClosed(orderId);
        uint16 ceiling = feeMaxBps < o.maxFeeBps ? feeMaxBps : o.maxFeeBps;
        if (feeBps < feeMinBps || feeBps > ceiling) revert FeeOutOfBand(feeBps);
        if (!_navFresh()) revert NavStale();
        S = o.shares;
        user = o.user;
        if (address(policy) != address(0)) policy.authorizeRedeem(user, user, S, authData);
    }

    /// @dev _beginFill + all-cash preconditions (opt-in + payout stable set).
    function _beginAllCash(
        Order storage o,
        uint256 orderId,
        uint16 feeBps,
        bytes memory authData
    )
        internal
        returns (uint256 S, address user)
    {
        if (!o.allowAllCash) revert NotOptedIntoAllCash(orderId);
        if (address(payoutStable) == address(0)) revert PayoutStableNotSet();
        (S, user) = _beginFill(o, orderId, feeBps, authData);
    }

    function _verifyUnderwriterBid(uint256 orderId, uint256 S, UnderwriterBid calldata bid) internal {
        if (underwriterAllowlistEnabled && !allowedUnderwriter[bid.underwriter]) {
            revert UnderwriterNotAllowed(bid.underwriter);
        }
        if (block.timestamp > bid.deadline) revert SigExpired(bid.deadline);
        uint256 expNonce = underwriterNonces[bid.underwriter];
        if (bid.nonce != expNonce) revert UnderwriterNonceMismatch(bid.nonce, expNonce);

        // illiquidAssets/minUnits must exactly match the basket's illiquid legs, in order.
        _requireIlliquidTermsMatchBasket(bid.illiquidAssets, bid.minUnits);
        bytes32 illiquidTermsHash = keccak256(abi.encode(bid.illiquidAssets, bid.minUnits));

        bytes32 digest = keccak256(
            abi.encode(
                FILL_ALL_CASH_TYPEHASH,
                orderId,
                address(payoutStable),
                bid.cashIn,
                illiquidTermsHash,
                bid.underwriter,
                bid.nonce,
                bid.deadline,
                address(this),
                block.chainid
            )
        );
        address signer = ECDSA.recover(digest, bid.signature);
        if (signer != bid.underwriter) revert BadUnderwriterSig(signer, bid.underwriter);

        // Mandatory hard ceiling on the haircut vs the illiquid legs' NAV value: without it, a thin illiquid
        // weight lets `cashPot >= payout` pass at up to a 100% haircut, diverting holder accretion to the underwriter.
        if (maxUnderwriterHaircutBps == 0) revert HaircutNotSet();
        uint256 illiquidValue = _illiquidNavValueForShares(S);
        uint256 minCash = illiquidValue.mulDivDown(BPS - maxUnderwriterHaircutBps, BPS);
        if (bid.cashIn < minCash) revert HaircutTooDeep();

        underwriterNonces[bid.underwriter] = bid.nonce + 1; // effect before external interactions
    }

    function _requireIlliquidTermsMatchBasket(ERC20[] calldata assets, uint256[] calldata minUnits) internal view {
        if (assets.length != minUnits.length) revert IlliquidTermsMismatch();
        uint256 n = basket.length;
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (!basket[i].illiquid) continue;
            if (k >= assets.length || assets[k] != basket[i].asset) revert IlliquidTermsMismatch();
            ++k;
        }
        if (k != assets.length) revert IlliquidTermsMismatch();
    }

    // ============================================ VIEWS ===========================================

    function basketLength() external view returns (uint256) {
        return basket.length;
    }

    function availablePeriodCap() public view returns (uint256) {
        if (maxSharesPerPeriod == 0) return type(uint256).max;
        uint256 used = block.timestamp >= periodStart + periodLength ? 0 : sharesFilledInPeriod;
        return maxSharesPerPeriod > used ? maxSharesPerPeriod - used : 0;
    }

    /// @notice Payout stable an all-cash exit of `orderId` at `feeBps` would deliver, and the illiquid NAV value.
    function previewAllCash(uint256 orderId, uint16 feeBps) external view returns (uint256 payout, uint256 illiquidValue) {
        Order storage o = orders[orderId];
        if (o.closed || o.shares == 0 || address(payoutStable) == address(0)) return (0, 0);
        payout = _sharesToStable(o.shares).mulDivDown(BPS - feeBps, BPS);
        illiquidValue = _illiquidNavValueForShares(o.shares);
    }

    // ========================================== INTERNAL =========================================

    function _sharesToStable(uint256 s) internal view returns (uint256) {
        return s.mulDivDown(accountant.getRateInQuoteSafe(payoutStable), ONE_SHARE);
    }

    /// @dev NAV value (in payout stable) of the illiquid legs for a redemption of `s` shares.
    function _illiquidNavValueForShares(uint256 s) internal view returns (uint256 v) {
        uint256 n = basket.length;
        uint256[] memory legShares = _split(s, n);
        for (uint256 i; i < n; ++i) {
            if (!basket[i].illiquid) continue;
            v += legShares[i].mulDivDown(accountant.getRateInQuoteSafe(basket[i].asset), ONE_SHARE);
        }
    }

    function _split(uint256 total, uint256 n) internal view returns (uint256[] memory legs) {
        legs = new uint256[](n);
        uint256 assigned;
        for (uint256 i; i < n; ++i) {
            if (i + 1 == n) {
                legs[i] = total - assigned;
            } else {
                uint256 s = total.mulDivDown(basket[i].weightBps, BPS);
                legs[i] = s;
                assigned += s;
            }
        }
    }

    function _consumePeriod(uint256 shares) internal {
        if (maxSharesPerPeriod == 0) return;
        if (block.timestamp >= periodStart + periodLength) {
            periodStart = uint64(block.timestamp);
            sharesFilledInPeriod = 0;
        }
        uint256 used = sharesFilledInPeriod + shares;
        if (used > maxSharesPerPeriod) revert PeriodCapExceeded();
        sharesFilledInPeriod = used;
    }

    function _navFresh() internal view returns (bool) {
        if (maxNavAge == 0) return true;
        (,,,,,,, uint64 lastUpdate,,,,) = accountant.accountantState();
        return block.timestamp <= uint256(lastUpdate) + maxNavAge;
    }

    function _requirePricing(ERC20 asset) internal view {
        if (address(asset) == address(0)) revert ZeroAddress();
        if (!teller.isWithdrawSupported(asset)) revert AssetNotWithdrawSupported(asset);
        try accountant.getRateInQuoteSafe(asset) returns (uint256 r) {
            if (r == 0) revert NoPricing(asset);
        } catch {
            revert NoPricing(asset);
        }
    }

}
