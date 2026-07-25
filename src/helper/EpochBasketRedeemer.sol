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
 * @title EpochBasketRedeemer  (DRAFT — NOT AUDITED, NOT WIRED INTO DEPLOY)
 * @notice Epoch-batched, cap-gated redemption of vault shares into a uniform fixed-weight asset slice.
 *         Users `request` shares during an epoch (escrowed); a permissionless `closeEpoch` settles the
 *         whole epoch at ONE NAV against a per-epoch share cap; users then `claim` their pro-rata slice.
 *
 * @dev The gate (fund-style): if an epoch is undersubscribed (<= cap) every request fills 100%; if
 *      oversubscribed (> cap) every request fills pro-rata at the same ratio (Sybil-neutral — splitting
 *      shares across addresses gains nothing). Settlement is O(legs), never O(requests):
 *        - it does ONE aggregate `teller.bulkWithdraw` per basket leg into this contract (a pool) and
 *          snapshots the pooled amounts + total filled shares;
 *        - each user later PULLS `pooled[i] * theirShares / totalRequested` per leg, plus their unfilled
 *          shares back. `filledShares` cancels out of the claim math, so there is no compound rounding.
 *      Coverage-limited fill: if the vault can't cover the capped fill, everyone is scaled down by the
 *      same `covBps` (the shortfall is shared pro-rata) rather than the epoch stalling.
 *      Composition + cap are snapshot per epoch, so admin changes only affect future epochs.
 *      Needs SOLVER_ROLE on the vault RolesAuthority (calls bulkWithdraw). Owner via solmate Auth.
 *
 * KNOWN LIMITATIONS (draft): rounding dust (< #claimants wei per leg, and a few share-wei) is stranded
 *      in the contract — pooled balances are commingled across epochs, so a safe per-epoch sweep can't
 *      be computed; left as a to-do. `pooled[i]` is recorded from the MEASURED balance delta so
 *      fee-on-transfer legs don't overdraw, but ERC-777 (reentrant) basket assets remain out of scope.
 */
contract EpochBasketRedeemer is Auth, ReentrancyGuard {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint16 internal constant BPS = 10_000;

    struct BasketLeg {
        ERC20 asset;
        uint16 weightBps;
    }

    /// @dev Params (cap, assets, weights) are frozen when an epoch receives its first request; the NAV
    /// pool (pooled, filledShares) is frozen at settlement. `claim` reads only these frozen values.
    struct Epoch {
        uint256 cap; // maxSharesPerEpoch snapshot (0 => uncapped)
        ERC20[] assets; // basket asset snapshot
        uint16[] weightsBps; // basket weight snapshot (Σ = BPS)
        uint256 totalRequested; // Σ escrowed request shares
        bool settled;
        uint64 closeTime;
        uint256 filledShares; // shares redeemed into the pool (<= min(totalRequested, cap))
        uint256[] pooled; // pooled[i] = leg-i assets held for this epoch
    }

    TellerWithMultiAssetSupport public immutable teller;
    AccountantWithRateProviders public immutable accountant;
    BoringVault public immutable shareToken;
    uint256 public immutable ONE_SHARE; // 10 ** shareToken.decimals()

    BasketLeg[] public basket; // fixed-weight slice; weights sum to BPS
    uint256 public maxSharesPerEpoch; // per-epoch fill cap (0 => uncapped)
    uint64 public epochDuration; // seconds an epoch accepts requests before it may close
    uint256 public minRequestShares; // per-request floor
    IRedeemPolicy public policy; // optional auth hook (address(0) => permissionless)
    uint64 public requestCutoffBuffer; // seconds before close when the request book LOCKS (requests become
        // irrevocable; no new requests). Lets NAV be marked fresh after the book closes but before pricing,
        // and kills the free look-back option (cancel-right-before-a-markdown). 0 => no cutoff.
    uint64 public maxNavAge; // max age of the accountant NAV to price an epoch; if the mark is staler than
        // this at close, the epoch settles as a 0-fill full refund instead of pricing on a stale NAV. 0 => off.

    uint256 public currentEpoch; // id of the OPEN epoch accepting requests
    uint64 public currentEpochStart; // timestamp the open epoch began

    mapping(uint256 => Epoch) internal epochs;
    mapping(uint256 => mapping(address => uint256)) public requestShares; // epoch => user => escrowed
    mapping(uint256 => mapping(address => bool)) public claimed; // epoch => user => claimed?

    event Requested(uint256 indexed epochId, address indexed user, uint256 shares);
    event RequestCancelled(uint256 indexed epochId, address indexed user, uint256 shares);
    event EpochSettled(uint256 indexed epochId, uint256 totalRequested, uint256 filledShares, uint256[] pooled);
    event Claimed(uint256 indexed epochId, address indexed user, uint256 shares, uint256 sharesReturned);
    event BasketUpdated();
    event MaxSharesPerEpochUpdated(uint256 maxShares);
    event EpochDurationUpdated(uint64 epochDuration);
    event MinRequestSharesUpdated(uint256 minRequestShares);
    event PolicyUpdated(IRedeemPolicy indexed policy);
    event RequestCutoffBufferUpdated(uint64 requestCutoffBuffer);
    event MaxNavAgeUpdated(uint64 maxNavAge);

    error ZeroAddress();
    error ZeroShares();
    error ZeroDuration();
    error BelowMinRequest(uint256 shares, uint256 min);
    error EmptyBasket();
    error BadWeights(uint256 sum);
    error AssetNotWithdrawSupported(ERC20 asset);
    error NoPricing(ERC20 asset);
    error DuplicateAsset(ERC20 asset);
    error EpochNeedsClose();
    error RequestsClosed(); // book locked ahead of pricing (within requestCutoffBuffer of close)
    error RequestsLocked(); // requests irrevocable after the cutoff
    error EpochNotElapsed();
    error EpochNotSettled(uint256 epochId);
    error AlreadyClaimed(uint256 epochId);
    error NothingToClaim(uint256 epochId);
    error BadCancelAmount();

    constructor(address _owner, TellerWithMultiAssetSupport _teller) Auth(_owner, Authority(address(0))) {
        if (_owner == address(0) || address(_teller) == address(0)) revert ZeroAddress();
        teller = _teller;
        accountant = _teller.accountant();
        shareToken = _teller.vault();
        ONE_SHARE = 10 ** shareToken.decimals();
        currentEpoch = 1;
        currentEpochStart = uint64(block.timestamp);
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
            sum += legs[i].weightBps;
            basket.push(legs[i]);
        }
        if (sum != BPS) revert BadWeights(sum);
        emit BasketUpdated();
    }

    function setMaxSharesPerEpoch(uint256 v) external requiresAuth {
        maxSharesPerEpoch = v;
        emit MaxSharesPerEpochUpdated(v);
    }

    function setEpochDuration(uint64 v) external requiresAuth {
        if (v == 0) revert ZeroDuration();
        epochDuration = v;
        emit EpochDurationUpdated(v);
    }

    function setMinRequestShares(uint256 v) external requiresAuth {
        minRequestShares = v;
        emit MinRequestSharesUpdated(v);
    }

    function setPolicy(IRedeemPolicy p) external requiresAuth {
        policy = p;
        emit PolicyUpdated(p);
    }

    /// @notice Seconds before close during which the request book is locked (requests irrevocable). 0 => off.
    function setRequestCutoffBuffer(uint64 v) external requiresAuth {
        requestCutoffBuffer = v;
        emit RequestCutoffBufferUpdated(v);
    }

    /// @notice Max accountant-NAV age to price an epoch; staler => 0-fill full refund at close. 0 => off.
    function setMaxNavAge(uint64 v) external requiresAuth {
        maxNavAge = v;
        emit MaxNavAgeUpdated(v);
    }

    // =========================================== REQUESTS =========================================

    function request(uint256 shares) external nonReentrant {
        _request(shares, "");
    }

    function request(uint256 shares, bytes calldata authData) external nonReentrant {
        _request(shares, authData);
    }

    function _request(uint256 shares, bytes memory authData) internal {
        if (shares == 0) revert ZeroShares();
        if (shares < minRequestShares) revert BelowMinRequest(shares, minRequestShares);
        if (epochDuration == 0) revert ZeroDuration();
        if (block.timestamp >= currentEpochStart + epochDuration) revert EpochNeedsClose();
        if (block.timestamp >= _cutoffTime()) revert RequestsClosed(); // book locked ahead of pricing

        if (address(policy) != address(0)) policy.authorizeRedeem(msg.sender, msg.sender, shares, authData);

        uint256 id = currentEpoch;
        Epoch storage E = epochs[id];
        _ensureOpened(E); // freeze basket + cap into this epoch on its first request

        ERC20(address(shareToken)).safeTransferFrom(msg.sender, address(this), shares);
        requestShares[id][msg.sender] += shares;
        E.totalRequested += shares;
        emit Requested(id, msg.sender, shares);
    }

    /// @notice Cancel part/all of your request in the OPEN epoch and get the shares back. Available until
    /// the epoch actually settles, so a stalled settlement can never trap funds.
    function cancelRequest(uint256 shares) external nonReentrant {
        // Irrevocable once the book locks: after the cutoff a holder can no longer straddle a pending
        // markdown. If they still want out, they (or anyone) call closeEpoch and then claim.
        if (block.timestamp >= _cutoffTime()) revert RequestsLocked();
        uint256 id = currentEpoch;
        uint256 have = requestShares[id][msg.sender];
        if (shares == 0 || shares > have) revert BadCancelAmount();

        requestShares[id][msg.sender] = have - shares;
        epochs[id].totalRequested -= shares;
        ERC20(address(shareToken)).safeTransfer(msg.sender, shares);
        emit RequestCancelled(id, msg.sender, shares);
    }

    // ======================================= EPOCH LIFECYCLE ======================================

    /// @notice Settle the current epoch (once its duration has elapsed) and open the next. Permissionless.
    /// @dev Never reverts on liquidity/pricing: if any leg is de-listed, unpriceable (accountant paused,
    /// no rate) or essentially uncoverable, the whole epoch settles as a 0-fill FULL REFUND (everyone
    /// gets their shares back and can re-request) rather than wedging settlement.
    function closeEpoch() external nonReentrant {
        uint256 id = currentEpoch;
        if (epochDuration == 0 || block.timestamp < currentEpochStart + epochDuration) revert EpochNotElapsed();

        Epoch storage E = epochs[id];
        uint256 T = E.totalRequested;

        if (T == 0) {
            E.settled = true;
            E.closeTime = uint64(block.timestamp);
            emit EpochSettled(id, 0, 0, E.pooled);
            _openNextEpoch();
            return;
        }

        uint256 n = E.assets.length;
        uint256 cap = E.cap;
        uint256 intendedFill = (cap == 0 || T < cap) ? T : cap; // min(T, cap), cap==0 => uncapped

        uint256[] memory legShares = _split(intendedFill, E.weightsBps);
        uint256[] memory rates = new uint256[](n);

        // NAV-freshness gate: never price an epoch on a stale mark. A stale NAV => 0-fill full refund
        // (everyone gets shares back and re-requests once the mark is fresh), same graceful path as an
        // uncoverable leg. Skips the coverage loop entirely when stale.
        uint256 covBps = _navFresh() ? BPS : 0;

        // Coverage-limited fill: scale everyone down uniformly by the least-covered leg. A leg that is
        // de-listed or unpriceable forces covBps=0 => 0-fill refund (no revert => un-brickable).
        for (uint256 i; covBps != 0 && i < n; ++i) {
            uint256 ls = legShares[i];
            if (ls == 0) continue;
            ERC20 asset = E.assets[i];
            if (!teller.isWithdrawSupported(asset)) {
                covBps = 0;
                break;
            }
            try accountant.getRateInQuoteSafe(asset) returns (uint256 r) {
                if (r == 0) {
                    covBps = 0;
                    break;
                }
                rates[i] = r;
            } catch {
                covBps = 0;
                break;
            }
            uint256 wouldRecv = ls.mulDivDown(rates[i], ONE_SHARE);
            uint256 bal = asset.balanceOf(address(shareToken));
            if (bal < wouldRecv) {
                uint256 legCov = wouldRecv == 0 ? 0 : bal.mulDivDown(BPS, wouldRecv);
                if (legCov < covBps) covBps = legCov;
            }
        }

        uint256 scaledFill = intendedFill.mulDivDown(covBps, BPS);
        uint256[] memory pooled = new uint256[](n);
        uint256 actualFilled;
        if (scaledFill != 0) {
            if (scaledFill != intendedFill) legShares = _split(scaledFill, E.weightsBps);
            for (uint256 i; i < n; ++i) {
                uint256 ls = legShares[i];
                if (ls == 0) continue;
                ERC20 asset = E.assets[i];
                // Clamp to exactly what the vault can cover, so rounding can never make bulkWithdraw revert.
                uint256 maxLs = asset.balanceOf(address(shareToken)).mulDivDown(ONE_SHARE, rates[i]);
                if (ls > maxLs) ls = maxLs;
                if (ls == 0) continue;
                uint256 before = asset.balanceOf(address(this));
                teller.bulkWithdraw(asset, ls, 0, address(this)); // burns `ls` shares from this contract
                pooled[i] = asset.balanceOf(address(this)) - before; // MEASURED receipt (FoT-safe)
                actualFilled += ls;
            }
        }

        E.pooled = pooled;
        E.filledShares = actualFilled; // exact shares burned; T - actualFilled returned to claimants
        E.settled = true;
        E.closeTime = uint64(block.timestamp);
        emit EpochSettled(id, T, actualFilled, pooled);
        _openNextEpoch();
    }

    // =========================================== CLAIMS ===========================================

    /// @dev Permissionless overload (empty authData). If a policy is set it still runs (fails closed).
    function claim(uint256 epochId) external nonReentrant {
        _claim(epochId, "");
    }

    /// @notice Claim a settled epoch; `authData` is forwarded to the policy hook (re-checks the claimer
    /// at asset-exit time, so a post-request denylist blocks the asset slice).
    function claim(uint256 epochId, bytes calldata authData) external nonReentrant {
        _claim(epochId, authData);
    }

    /// @notice Claim several settled epochs (no authData). Bounded by the caller array (caller pays gas).
    function claimMany(uint256[] calldata epochIds) external nonReentrant {
        for (uint256 i; i < epochIds.length; ++i) {
            _claim(epochIds[i], "");
        }
    }

    function _claim(uint256 epochId, bytes memory authData) internal {
        Epoch storage E = epochs[epochId];
        if (!E.settled) revert EpochNotSettled(epochId);
        if (claimed[epochId][msg.sender]) revert AlreadyClaimed(epochId);
        uint256 s = requestShares[epochId][msg.sender];
        if (s == 0) revert NothingToClaim(epochId);

        // Re-authorize at asset-exit time (matches BasketRedeemer.settleClaim). Reverts before any
        // effect, so a denied claimer can retry with fresh authorization.
        if (address(policy) != address(0)) policy.authorizeRedeem(msg.sender, msg.sender, s, authData);

        claimed[epochId][msg.sender] = true; // effect before interactions (CEI)

        uint256 T = E.totalRequested;
        uint256 n = E.assets.length;
        for (uint256 i; i < n; ++i) {
            // pooled[i] * s / T  — filledShares cancels, single truncation, provably solvent (Σ ≤ pooled[i])
            uint256 out = E.pooled[i].mulDivDown(s, T);
            if (out > 0) E.assets[i].safeTransfer(msg.sender, out);
        }

        // Unfilled shares returned, rounded DOWN against (T - filledShares) so escrow can never be overdrawn.
        uint256 sharesReturned = s.mulDivDown(T - E.filledShares, T);
        if (sharesReturned > 0) ERC20(address(shareToken)).safeTransfer(msg.sender, sharesReturned);

        emit Claimed(epochId, msg.sender, s, sharesReturned);
    }

    // ============================================ VIEWS ===========================================

    function basketLength() external view returns (uint256) {
        return basket.length;
    }

    function timeUntilClose() external view returns (uint256) {
        if (epochDuration == 0) return type(uint256).max;
        uint256 closeAt = currentEpochStart + epochDuration;
        return block.timestamp >= closeAt ? 0 : closeAt - block.timestamp;
    }

    function epochInfo(uint256 id)
        external
        view
        returns (uint256 cap, uint256 totalRequested, bool settled, uint64 closeTime, uint256 filledShares)
    {
        Epoch storage E = epochs[id];
        return (E.cap, E.totalRequested, E.settled, E.closeTime, E.filledShares);
    }

    function epochBasket(uint256 id)
        external
        view
        returns (ERC20[] memory assets, uint16[] memory weightsBps, uint256[] memory pooled)
    {
        Epoch storage E = epochs[id];
        return (E.assets, E.weightsBps, E.pooled);
    }

    function previewClaim(
        uint256 epochId,
        address user
    )
        external
        view
        returns (uint256[] memory assetsOut, uint256 sharesReturned)
    {
        Epoch storage E = epochs[epochId];
        uint256 n = E.assets.length;
        assetsOut = new uint256[](n);
        uint256 s = requestShares[epochId][user];
        if (!E.settled || s == 0 || claimed[epochId][user]) return (assetsOut, 0);
        uint256 T = E.totalRequested;
        for (uint256 i; i < n; ++i) {
            assetsOut[i] = E.pooled[i].mulDivDown(s, T);
        }
        sharesReturned = s.mulDivDown(T - E.filledShares, T);
    }

    // ========================================== INTERNAL =========================================

    /// @dev Freeze the current basket + cap into an epoch the first time it is touched by a request.
    function _ensureOpened(Epoch storage E) internal {
        if (E.assets.length != 0) return;
        uint256 n = basket.length;
        if (n == 0) revert EmptyBasket();
        for (uint256 i; i < n; ++i) {
            E.assets.push(basket[i].asset);
            E.weightsBps.push(basket[i].weightBps);
        }
        E.cap = maxSharesPerEpoch;
    }

    function _openNextEpoch() internal {
        unchecked {
            ++currentEpoch;
        }
        currentEpochStart = uint64(block.timestamp);
    }

    /// @dev Timestamp at which the current epoch's request book locks (requests become irrevocable).
    function _cutoffTime() internal view returns (uint256) {
        uint256 dur = epochDuration;
        uint64 buf = requestCutoffBuffer;
        return currentEpochStart + (dur > buf ? dur - buf : 0);
    }

    /// @dev Whether the accountant NAV is fresh enough to price against. Reads the `lastUpdateTimestamp`
    /// the accountant already stores (field 8 of accountantState) — which nothing else in the stack checks.
    function _navFresh() internal view returns (bool) {
        if (maxNavAge == 0) return true;
        (,,,,,,, uint64 lastUpdate,,,,) = accountant.accountantState();
        return block.timestamp <= uint256(lastUpdate) + maxNavAge;
    }

    /// @dev Split `total` by fixed weights; last leg absorbs dust so Σ == total exactly.
    function _split(uint256 total, uint16[] memory weights) internal pure returns (uint256[] memory legs) {
        uint256 n = weights.length;
        legs = new uint256[](n);
        uint256 assigned;
        for (uint256 i; i < n; ++i) {
            if (i + 1 == n) {
                legs[i] = total - assigned;
            } else {
                uint256 s = total.mulDivDown(weights[i], BPS);
                legs[i] = s;
                assigned += s;
            }
        }
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
