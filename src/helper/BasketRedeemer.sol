// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { ReentrancyGuard } from "@solmate/utils/ReentrancyGuard.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { IRedeemPolicy } from "src/interfaces/IRedeemPolicy.sol";

/**
 * @title BasketRedeemer  (DRAFT — NOT AUDITED, NOT WIRED INTO DEPLOY)
 * @notice Redeems vault shares for a uniform, fixed-weight "vertical slice" of assets (e.g. USDC +
 *         MMF + illiquid bond), all-or-nothing. Every redeemer receives the SAME composition,
 *         proportional to the shares they redeem — there is no privileged instant-cash tier, so
 *         splitting shares across addresses (Sybil) yields nothing.
 *
 * @dev Design (per-address rate limits were ruled out as Sybil-bypassable):
 *  - Uniform slice: `basket` weights sum to BPS. `redeem(S)` splits S by weight across every leg
 *    (last leg absorbs rounding dust so Σ legs == S) and delivers each leg via `teller.bulkWithdraw`.
 *    A redeem too small for every non-zero-weight leg to receive ≥1 share is rejected, so a "covered"
 *    redeem always delivers the true uniform composition.
 *  - All-or-nothing, atomic: coverage (pricing + vault balance + teller unpaused + withdraw-supported)
 *    is checked in a revert-free view; if fully coverable, `_payAll` runs with NO try/catch, so a
 *    misconfig (missing SOLVER_ROLE) or slippage breach reverts loudly and atomically — never partial.
 *  - Coupled deferral: if any leg can't be covered/priced, the WHOLE redemption escrows as ONE coupled
 *    claim (nothing paid). The basket composition is SNAPSHOT into the claim at open, so later admin
 *    `setBasket` changes cannot alter what a deferred redeemer settles into. Settles atomically when
 *    coverable, or the receiver cancels it back to 100% shares (so cash never leaves without the full
 *    slice — no cash-and-run).
 *  - Recourse: receiver can `settleClaim` (or an authorized keeper) or `cancelClaim` anytime; anyone
 *    may sweep an abandoned claim to its receiver after `claimExpiry`; an admin can `redirectClaim` a
 *    stuck (e.g. frozen) receiver. `redirectClaim` is an unconditional reassign power — the owner MUST
 *    be a multisig (ideally timelocked); it is the trusted-admin escape hatch for frozen receivers.
 *  - This contract burns the shares it holds, so it needs SOLVER_ROLE on the vault's RolesAuthority.
 *
 * SECURITY: design sketch; do not deploy without an independent audit and full test suite.
 */
contract BasketRedeemer is Auth, ReentrancyGuard {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /// @notice One leg of the fixed-weight redemption basket. All legs' weights sum to BPS.
    struct BasketLeg {
        ERC20 asset; // a registered withdraw asset on the teller, with accountant pricing
        uint16 weightBps; // fraction of every redemption, in bps
    }

    /// @notice A coupled deferred redemption. The composition is snapshot so it is immune to basket drift.
    struct Claim {
        address receiver; // recipient of the full slice on settle; of shares on cancel
        uint256 shares; // total shares escrowed (== Σ legShares)
        ERC20[] assets; // snapshot of the leg assets at open
        uint256[] legShares; // snapshot of the per-leg share amounts at open
        uint64 createdAt;
        bool closed; // settled or cancelled
    }

    uint16 internal constant BPS = 10_000;

    TellerWithMultiAssetSupport public immutable teller;
    AccountantWithRateProviders public immutable accountant;
    BoringVault public immutable shareToken; // the vault share ERC20 the user offers
    uint256 public immutable ONE_SHARE; // 10 ** shareToken.decimals()

    BasketLeg[] public basket; // fixed-weight slice; weights sum to BPS
    uint256 public minRedeemShares; // floor to keep every non-zero-weight leg >= 1 share

    mapping(uint256 => Claim) public claims;
    uint256 public claimCount;
    uint64 public claimExpiry; // seconds after which anyone may sweep a claim back to its receiver (0 => disabled)

    /// @notice Optional authorization hook. address(0) => permissionless (hook skipped). When set,
    /// redeem/settle call `policy.authorizeRedeem(...)`, which reverts to deny. See IRedeemPolicy.
    IRedeemPolicy public policy;

    event Redeemed(address indexed caller, address indexed receiver, uint256 shares, bool deferred);
    event LegPaid(address indexed receiver, ERC20 indexed asset, uint256 shares, uint256 assetsOut);
    event ClaimOpened(uint256 indexed claimId, address indexed receiver, uint256 shares);
    event ClaimSettled(uint256 indexed claimId, address indexed receiver);
    event ClaimCancelled(uint256 indexed claimId, address indexed to, uint256 shares, bool byExpirySweep);
    event ClaimRedirected(uint256 indexed claimId, address indexed oldReceiver, address indexed newReceiver);
    event BasketUpdated();
    event MinRedeemSharesUpdated(uint256 minRedeemShares);
    event ClaimExpiryUpdated(uint64 claimExpiry);
    event PolicyUpdated(IRedeemPolicy indexed policy);

    error ZeroAddress();
    error ZeroShares();
    error BelowMinRedeem(uint256 shares, uint256 min);
    error RedeemTooSmallForSlice(); // a non-zero-weight leg would receive 0 shares
    error EmptyBasket();
    error BadWeights(uint256 sum);
    error AssetNotWithdrawSupported(ERC20 asset);
    error NoPricing(ERC20 asset);
    error DuplicateAsset(ERC20 asset);
    error MinOutLengthMismatch();
    error NotCoverable();
    error ClaimClosed(uint256 claimId);
    error NotClaimReceiver(uint256 claimId);
    error NotYetExpired(uint256 claimId);

    constructor(address _owner, TellerWithMultiAssetSupport _teller) Auth(_owner, Authority(address(0))) {
        if (_owner == address(0) || address(_teller) == address(0)) revert ZeroAddress();
        teller = _teller;
        accountant = _teller.accountant();
        shareToken = _teller.vault();
        ONE_SHARE = 10 ** shareToken.decimals();
    }

    // ============================================ ADMIN ============================================

    /// @dev Weights must sum to BPS; every asset must be withdraw-supported, priced, and unique.
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
            sum += legs[i].weightBps;
            basket.push(legs[i]);
        }
        if (sum != BPS) revert BadWeights(sum);
        emit BasketUpdated();
    }

    function setMinRedeemShares(uint256 _minRedeemShares) external requiresAuth {
        minRedeemShares = _minRedeemShares;
        emit MinRedeemSharesUpdated(_minRedeemShares);
    }

    function setClaimExpiry(uint64 _claimExpiry) external requiresAuth {
        claimExpiry = _claimExpiry;
        emit ClaimExpiryUpdated(_claimExpiry);
    }

    /// @notice Set (or clear, with address(0)) the authorization policy hook.
    function setPolicy(IRedeemPolicy _policy) external requiresAuth {
        policy = _policy;
        emit PolicyUpdated(_policy);
    }

    /// @notice Repoint a stuck claim (e.g. a frozen/lost receiver) so it can be settled or cancelled.
    /// @dev Unconditional reassign power — the owner MUST be a multisig, ideally timelocked.
    function redirectClaim(uint256 claimId, address newReceiver) external requiresAuth {
        if (newReceiver == address(0)) revert ZeroAddress();
        Claim storage c = claims[claimId];
        if (c.closed || c.shares == 0) revert ClaimClosed(claimId);
        address old = c.receiver;
        c.receiver = newReceiver;
        emit ClaimRedirected(claimId, old, newReceiver);
    }

    // ============================================ VIEWS ============================================

    function basketLength() external view returns (uint256) {
        return basket.length;
    }

    /// @notice The per-leg share amounts a redemption of `shares` splits into (last leg absorbs dust).
    function previewSlice(uint256 shares) external view returns (uint256[] memory sLegs) {
        sLegs = _split(shares);
    }

    /// @notice The frozen composition snapshot of a deferred claim.
    function claimSnapshot(uint256 claimId) external view returns (ERC20[] memory assets, uint256[] memory legShares) {
        Claim storage c = claims[claimId];
        return (c.assets, c.legShares);
    }

    /// @notice Whether `shares` could be fully redeemed right now (all legs priceable + covered).
    function quoteCoverage(uint256 shares) external view returns (bool coverable, uint256[] memory sLegs) {
        sLegs = _split(shares);
        coverable = _coverable(_assets(), sLegs);
    }

    // ========================================== REDEEM ============================================

    /**
     * @notice Redeem `shares` for the full fixed-weight slice sent to `receiver`, all-or-nothing.
     *         If every leg is coverable now, pays atomically; otherwise escrows the whole redemption
     *         as one coupled claim (composition snapshot) to settle later or cancel back to shares.
     * @param shares vault shares to redeem (pulled from msg.sender)
     * @param receiver recipient of the slice / of a deferred claim
     * @param minOut per-leg minimum asset out (length == basket.length); enforced on the atomic pay
     */
    /// @dev Permissionless overload (no authData); reverts if a policy is set and requires auth.
    function redeem(uint256 shares, address receiver, uint256[] calldata minOut) external nonReentrant {
        _redeem(shares, receiver, minOut, "");
    }

    /// @dev Authorized overload: `authData` is forwarded to the policy hook when one is set.
    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minOut,
        bytes calldata authData
    )
        external
        nonReentrant
    {
        _redeem(shares, receiver, minOut, authData);
    }

    function _redeem(uint256 shares, address receiver, uint256[] memory minOut, bytes memory authData) internal {
        uint256 n = basket.length;
        if (n == 0) revert EmptyBasket();
        if (shares == 0) revert ZeroShares();
        if (shares < minRedeemShares) revert BelowMinRedeem(shares, minRedeemShares);
        if (receiver == address(0)) revert ZeroAddress();
        if (minOut.length != n) revert MinOutLengthMismatch();

        if (address(policy) != address(0)) policy.authorizeRedeem(msg.sender, receiver, shares, authData);

        // Pull all shares up front; this contract must own them to burn via bulkWithdraw.
        ERC20(address(shareToken)).safeTransferFrom(msg.sender, address(this), shares);

        uint256[] memory sLegs = _split(shares);
        _requireUniform(sLegs); // every non-zero-weight leg must receive >= 1 share
        ERC20[] memory assets = _assets();

        if (_coverable(assets, sLegs)) {
            _payAll(assets, sLegs, receiver, minOut); // atomic, no catch: misconfig/slippage revert loudly
            emit Redeemed(msg.sender, receiver, shares, false);
        } else {
            _openClaim(receiver, assets, sLegs, shares); // shares already escrowed here
            emit Redeemed(msg.sender, receiver, shares, true);
        }
    }

    // ======================================= CLAIM LIFECYCLE =======================================

    /// @dev Permissionless overload (no authData).
    function settleClaim(uint256 claimId, uint256[] calldata minOut) external nonReentrant {
        _settleClaim(claimId, minOut, "");
    }

    /// @notice Settle a coupled claim against its SNAPSHOT once coverable. Receiver or authorized keeper.
    /// @dev `authData` is forwarded to the policy hook (re-checks the receiver at settle time).
    function settleClaim(uint256 claimId, uint256[] calldata minOut, bytes calldata authData) external nonReentrant {
        _settleClaim(claimId, minOut, authData);
    }

    function _settleClaim(uint256 claimId, uint256[] memory minOut, bytes memory authData) internal {
        Claim storage c = claims[claimId];
        if (c.closed || c.shares == 0) revert ClaimClosed(claimId);
        if (msg.sender != c.receiver && !_isAuthorized(msg.sig)) revert NotClaimReceiver(claimId);

        if (address(policy) != address(0)) policy.authorizeRedeem(msg.sender, c.receiver, c.shares, authData);

        ERC20[] memory assets = c.assets;
        uint256[] memory legShares = c.legShares;
        if (minOut.length != assets.length) revert MinOutLengthMismatch();
        if (!_coverable(assets, legShares)) revert NotCoverable();

        c.closed = true;
        _payAll(assets, legShares, c.receiver, minOut);
        emit ClaimSettled(claimId, c.receiver);
    }

    /// @notice Cancel a coupled claim and return ALL escrowed shares. The receiver may call anytime;
    /// anyone may call after `claimExpiry` (an anti-abandonment sweep that always pays the receiver).
    /// @dev Intentionally NOT policy-gated: this returns the user's own vault SHARES (still bound by the
    /// share token's transfer rules / freeze hook), never the underlying asset slice — assets exit only
    /// via the policy-gated `_redeem`/`_settleClaim`. A frozen receiver is handled by admin `redirectClaim`.
    function cancelClaim(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        if (c.closed || c.shares == 0) revert ClaimClosed(claimId);

        bool bySweep;
        if (msg.sender != c.receiver) {
            if (claimExpiry == 0 || block.timestamp < c.createdAt + claimExpiry) revert NotYetExpired(claimId);
            bySweep = true;
        }

        c.closed = true;
        uint256 s = c.shares;
        address to = c.receiver;
        ERC20(address(shareToken)).safeTransfer(to, s);
        emit ClaimCancelled(claimId, to, s, bySweep);
    }

    // ========================================== INTERNAL =========================================

    function _assets() internal view returns (ERC20[] memory assets) {
        uint256 n = basket.length;
        assets = new ERC20[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = basket[i].asset;
        }
    }

    /// @dev Split `S` shares by fixed weights; last leg absorbs the dust so Σ sLegs == S exactly.
    function _split(uint256 S) internal view returns (uint256[] memory sLegs) {
        uint256 n = basket.length;
        sLegs = new uint256[](n);
        uint256 assigned;
        for (uint256 i; i < n; ++i) {
            if (i + 1 == n) {
                sLegs[i] = S - assigned; // remainder (incl. dust) to last leg
            } else {
                uint256 s = S.mulDivDown(basket[i].weightBps, BPS);
                sLegs[i] = s;
                assigned += s;
            }
        }
    }

    /// @dev Reject a redeem too small for the uniform slice: every leg with weight > 0 must get >= 1 share.
    function _requireUniform(uint256[] memory sLegs) internal view {
        uint256 n = basket.length;
        for (uint256 i; i < n; ++i) {
            if (basket[i].weightBps != 0 && sLegs[i] == 0) revert RedeemTooSmallForSlice();
        }
    }

    /// @dev Revert-free full-coverage check over an (assets, shares) pairing: every leg must be
    /// withdraw-supported, priceable to a non-zero asset amount, and held by the vault, teller unpaused.
    /// NOTE: does not model a restrictive `beforeWithdraw` hook — if one is configured to block this
    /// contract, a "covered" redeem reverts in `_payAll` (atomic, no value loss) rather than deferring.
    function _coverable(ERC20[] memory assets, uint256[] memory shares) internal view returns (bool) {
        if (teller.isPaused()) return false;
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            uint256 s = shares[i];
            if (s == 0) continue;
            ERC20 asset = assets[i];
            if (!teller.isWithdrawSupported(asset)) return false;
            uint256 wouldReceive;
            try accountant.getRateInQuoteSafe(asset) returns (uint256 rate) {
                wouldReceive = s.mulDivDown(rate, ONE_SHARE);
            } catch {
                return false; // unpriceable (accountant paused / no rate provider) => defer
            }
            if (wouldReceive == 0) return false; // would burn shares for 0 assets
            if (asset.balanceOf(address(shareToken)) < wouldReceive) return false; // vault short
        }
        return true;
    }

    /// @dev Atomic payout of every leg. NO try/catch: any failure (missing SOLVER_ROLE, slippage,
    /// a leg reverting) reverts the whole call, so this never pays a partial slice.
    function _payAll(
        ERC20[] memory assets,
        uint256[] memory shares,
        address receiver,
        uint256[] memory minOut
    )
        internal
    {
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            uint256 s = shares[i];
            if (s == 0) continue;
            ERC20 asset = assets[i];
            uint256 out = teller.bulkWithdraw(asset, s, minOut[i], receiver);
            emit LegPaid(receiver, asset, s, out);
        }
    }

    function _openClaim(address receiver, ERC20[] memory assets, uint256[] memory legShares, uint256 total) internal {
        uint256 id = ++claimCount;
        Claim storage c = claims[id];
        c.receiver = receiver;
        c.shares = total;
        c.createdAt = uint64(block.timestamp);
        for (uint256 i; i < assets.length; ++i) {
            c.assets.push(assets[i]);
            c.legShares.push(legShares[i]);
        }
        emit ClaimOpened(id, receiver, total);
    }

    /// @dev Mirrors solmate Auth.requiresAuth for a manual (non-modifier) authorization check.
    function _isAuthorized(bytes4 functionSig) internal view returns (bool) {
        Authority auth = authority;
        return
            (address(auth) != address(0) && auth.canCall(msg.sender, address(this), functionSig)) || msg.sender == owner;
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
