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
 * @title DutchExitRedeemer  (DRAFT — NOT AUDITED, NOT WIRED INTO DEPLOY)
 * @notice A declining-price (Dutch) early exit. An exiter escrows shares and posts a cash price that
 *         decays from `priceStart` to `priceFloor` over `duration`. A filler (public or role-gated) buys
 *         at the current price, atomically:
 *           1. filler pays the current cash price to the EXITER;
 *           2. the redeemer burns the exiter's shares and withdraws the fixed-weight slice from the vault;
 *           3. the filler receives the slice MINUS a fixed vault fee; the fee's assets stay in the vault,
 *              so the discount ACCRETES to remaining holders (NAV/share up);
 *           4. the filler now holds the (illiquid-inclusive) slice and redeems it themselves — they take
 *              the duration/illiquidity risk. Price discovery, no operator discretion on the discount.
 *
 * @dev The vault fee `f` (accretion cut) is fixed and independent of the auction price; the Dutch decay is
 *      the exiter<->filler price only. `fillDutch` is `requiresAuth` — wire via the RolesAuthority:
 *      RECOMMENDED public (`setPublicCapability`) so bidders compete for the decaying price, or gate to a
 *      role of vetted fillers; owner always passes. If the vault cannot cover the slice the fill REVERTS
 *      (`InsufficientVaultLiquidity`) — no partial fill; the filler retries or the exiter cancels.
 *      Needs SOLVER_ROLE on the vault RolesAuthority (calls teller.bulkWithdraw). `maxNavAge` guards the
 *      NAV-priced slice from being oversized at a stale mark.
 *
 * SECURITY: design sketch; unaudited.
 */
contract DutchExitRedeemer is Auth, ReentrancyGuard {

    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_FEE_BPS = 2_000; // hard 20% ceiling on the vault fee

    struct BasketLeg {
        ERC20 asset;
        uint16 weightBps;
    }

    struct Order {
        address user;
        uint256 shares;
        uint256 priceStart; // cash the exiter accepts at t0 (in cashAsset units)
        uint256 priceFloor; // cash floor as the auction decays; 0 < priceFloor <= priceStart
        uint64 startTime;
        uint64 duration; // seconds over which price decays priceStart -> priceFloor
        bool closed;
        ERC20 cashAsset; // SNAPSHOT of cashAsset at request — a later admin swap can't reinterpret the price
        uint16 vaultFeeBps; // SNAPSHOT of the fee at request — the exiter's terms are fixed
    }

    TellerWithMultiAssetSupport public immutable teller;
    AccountantWithRateProviders public immutable accountant;
    BoringVault public immutable shareToken;
    uint256 public immutable ONE_SHARE;

    BasketLeg[] public basket; // fixed-weight slice delivered to the filler; weights sum to BPS
    ERC20 public cashAsset; // the asset the filler pays the exiter
    uint16 public vaultFeeBps; // fixed accretion cut withheld from the slice, <= MAX_FEE_BPS
    uint64 public maxNavAge; // max accountant-NAV age to fill; 0 => off
    uint256 public minRequestShares; // per-order dust floor
    IRedeemPolicy public policy; // optional KYC hook, checked at request

    // per-period volume cap (rolling window)
    uint256 public maxSharesPerPeriod; // 0 => uncapped
    uint64 public periodLength;
    uint64 public periodStart;
    uint256 public sharesFilledInPeriod;

    mapping(uint256 => Order) public orders;
    uint256 public orderCount;

    event Requested(uint256 indexed orderId, address indexed user, uint256 shares, uint256 priceStart, uint256 priceFloor, uint64 duration);
    event Cancelled(uint256 indexed orderId, address indexed user, uint256 shares);
    event Filled(uint256 indexed orderId, address indexed user, address indexed filler, uint256 shares, uint256 cashPaid);
    event BasketUpdated();
    event CashAssetUpdated(ERC20 indexed cashAsset);
    event VaultFeeUpdated(uint16 vaultFeeBps);
    event MaxNavAgeUpdated(uint64 maxNavAge);
    event PeriodCapUpdated(uint256 maxSharesPerPeriod, uint64 periodLength);
    event MinRequestSharesUpdated(uint256 minRequestShares);
    event PolicyUpdated(IRedeemPolicy indexed policy);

    error ZeroAddress();
    error ZeroShares();
    error BelowMinRequest(uint256 shares, uint256 min);
    error EmptyBasket();
    error BadWeights(uint256 sum);
    error AssetNotWithdrawSupported(ERC20 asset);
    error NoPricing(ERC20 asset);
    error DuplicateAsset(ERC20 asset);
    error BadFee();
    error BadPeriodCap();
    error BadPrice();
    error ZeroDuration();
    error CashAssetNotSet();
    error OrderClosed(uint256 orderId);
    error NotOrderOwner(uint256 orderId);
    error NavStale();
    error PeriodCapExceeded();
    error PriceAboveMax(uint256 price, uint256 maxCashIn);
    error MinOutLengthMismatch();
    error SliceOutTooLow(uint256 got, uint256 minOut);
    error InsufficientVaultLiquidity(ERC20 asset, uint256 need, uint256 have);
    error OrderTooSmallForSlice();

    constructor(address _owner, TellerWithMultiAssetSupport _teller) Auth(_owner, Authority(address(0))) {
        if (_owner == address(0) || address(_teller) == address(0)) revert ZeroAddress();
        teller = _teller;
        accountant = _teller.accountant();
        shareToken = _teller.vault();
        ONE_SHARE = 10 ** shareToken.decimals();
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

    function setCashAsset(ERC20 c) external requiresAuth {
        if (address(c) == address(0)) revert ZeroAddress();
        cashAsset = c;
        emit CashAssetUpdated(c);
    }

    function setVaultFee(uint16 bps) external requiresAuth {
        if (bps == 0 || bps > MAX_FEE_BPS) revert BadFee(); // fee>0 so every exit accretes to stayers
        vaultFeeBps = bps;
        emit VaultFeeUpdated(bps);
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

    // =========================================== REQUESTS =========================================

    function requestDutch(
        uint256 shares,
        uint256 priceStart,
        uint256 priceFloor,
        uint64 duration
    )
        external
        nonReentrant
        returns (uint256)
    {
        return _request(shares, priceStart, priceFloor, duration, "");
    }

    function requestDutch(
        uint256 shares,
        uint256 priceStart,
        uint256 priceFloor,
        uint64 duration,
        bytes calldata authData
    )
        external
        nonReentrant
        returns (uint256)
    {
        return _request(shares, priceStart, priceFloor, duration, authData);
    }

    function _request(
        uint256 shares,
        uint256 priceStart,
        uint256 priceFloor,
        uint64 duration,
        bytes memory authData
    )
        internal
        returns (uint256 orderId)
    {
        if (shares == 0) revert ZeroShares();
        if (shares < minRequestShares) revert BelowMinRequest(shares, minRequestShares);
        if (basket.length == 0) revert EmptyBasket();
        if (priceFloor == 0 || priceFloor > priceStart) revert BadPrice(); // floor>0 => no free-slice footgun
        if (duration == 0) revert ZeroDuration();
        // Snapshot the pricing config so an admin swap can't reinterpret an open order.
        ERC20 _cash = cashAsset;
        uint16 _fee = vaultFeeBps;
        if (address(_cash) == address(0)) revert CashAssetNotSet();
        if (_fee == 0) revert BadFee(); // fee>0 so every exit accretes to stayers

        if (address(policy) != address(0)) policy.authorizeRedeem(msg.sender, msg.sender, shares, authData);

        ERC20(address(shareToken)).safeTransferFrom(msg.sender, address(this), shares);
        orderId = ++orderCount;
        orders[orderId] = Order({
            user: msg.sender,
            shares: shares,
            priceStart: priceStart,
            priceFloor: priceFloor,
            startTime: uint64(block.timestamp),
            duration: duration,
            closed: false,
            cashAsset: _cash,
            vaultFeeBps: _fee
        });
        emit Requested(orderId, msg.sender, shares, priceStart, priceFloor, duration);
    }

    function cancelDutch(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (o.closed || o.shares == 0) revert OrderClosed(orderId);
        if (o.user != msg.sender) revert NotOrderOwner(orderId);
        o.closed = true;
        uint256 s = o.shares;
        ERC20(address(shareToken)).safeTransfer(msg.sender, s);
        emit Cancelled(orderId, msg.sender, s);
    }

    // ============================================= FILL ===========================================

    /**
     * @notice Buy an order at the current (decayed) price. Pays the exiter cash and receives the slice
     *         minus the vault fee. Reverts if the vault cannot cover the slice.
     * @param orderId order to fill
     * @param maxCashIn slippage cap: revert if the current price exceeds this
     * @param minSliceOut per-leg minimum asset the filler will accept (length == basket.length)
     */
    function fillDutch(
        uint256 orderId,
        uint256 maxCashIn,
        uint256[] calldata minSliceOut
    )
        external
        nonReentrant
        requiresAuth
    {
        Order storage o = orders[orderId];
        if (o.closed || o.shares == 0) revert OrderClosed(orderId);
        if (!_navFresh()) revert NavStale();

        uint256 n = basket.length;
        if (minSliceOut.length != n) revert MinOutLengthMismatch();

        uint256 price = _currentPrice(o);
        if (price > maxCashIn) revert PriceAboveMax(price, maxCashIn);

        uint256 S = o.shares;
        address exiter = o.user;
        uint16 feeBps = o.vaultFeeBps; // snapshot fee
        _consumePeriod(S);
        o.closed = true; // effect before interactions (CEI)

        // 1) filler pays the exiter cash in the SNAPSHOT cash asset
        if (price > 0) o.cashAsset.safeTransferFrom(msg.sender, exiter, price);

        // 2) burn shares, deliver slice-minus-fee to the filler, accrete the fee to the vault
        uint256[] memory legShares = _split(S, n);
        _requireCoverage(legShares); // revert if the vault can't cover any leg (no free slice available)
        for (uint256 i; i < n; ++i) {
            if (legShares[i] != 0) _deliverLeg(basket[i].asset, legShares[i], feeBps, msg.sender, minSliceOut[i]);
        }

        emit Filled(orderId, exiter, msg.sender, S, price);
    }

    /// @dev Redeem one leg to this contract, send the filler (1-fee) of it, return the fee to the vault.
    function _deliverLeg(ERC20 asset, uint256 ls, uint16 feeBps, address filler, uint256 minOut) internal {
        uint256 before = asset.balanceOf(address(this));
        teller.bulkWithdraw(asset, ls, 0, address(this)); // burns `ls` shares from this contract
        uint256 got = asset.balanceOf(address(this)) - before; // measured (FoT-safe)
        if (got == 0) revert OrderTooSmallForSlice();

        uint256 fillerAmt = got.mulDivDown(BPS - feeBps, BPS);
        if (fillerAmt < minOut) revert SliceOutTooLow(fillerAmt, minOut);
        if (fillerAmt > 0) asset.safeTransfer(filler, fillerAmt);
        uint256 feeAmt = got - fillerAmt;
        if (feeAmt > 0) asset.safeTransfer(address(shareToken), feeAmt); // accretes to remaining holders
    }

    // ============================================ VIEWS ===========================================

    function basketLength() external view returns (uint256) {
        return basket.length;
    }

    /// @notice Current cash price for an order (decays priceStart -> priceFloor over duration).
    function currentPrice(uint256 orderId) external view returns (uint256) {
        return _currentPrice(orders[orderId]);
    }

    function availablePeriodCap() public view returns (uint256) {
        if (maxSharesPerPeriod == 0) return type(uint256).max;
        uint256 used = block.timestamp >= periodStart + periodLength ? 0 : sharesFilledInPeriod;
        return maxSharesPerPeriod > used ? maxSharesPerPeriod - used : 0;
    }

    /// @notice Whether the vault currently holds enough to cover the slice of `orderId`.
    function isCoverable(uint256 orderId) external view returns (bool) {
        uint256[] memory legShares = _split(orders[orderId].shares, basket.length);
        for (uint256 i; i < legShares.length; ++i) {
            if (legShares[i] == 0) continue;
            uint256 need = legShares[i].mulDivDown(accountant.getRateInQuoteSafe(basket[i].asset), ONE_SHARE);
            if (basket[i].asset.balanceOf(address(shareToken)) < need) return false;
        }
        return true;
    }

    // ========================================== INTERNAL =========================================

    function _currentPrice(Order storage o) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - o.startTime;
        if (elapsed >= o.duration) return o.priceFloor;
        uint256 drop = (o.priceStart - o.priceFloor).mulDivDown(elapsed, o.duration);
        return o.priceStart - drop;
    }

    function _requireCoverage(uint256[] memory legShares) internal view {
        uint256 n = basket.length;
        for (uint256 i; i < n; ++i) {
            uint256 ls = legShares[i];
            if (ls == 0) continue;
            ERC20 asset = basket[i].asset;
            uint256 need = ls.mulDivDown(accountant.getRateInQuoteSafe(asset), ONE_SHARE);
            uint256 have = asset.balanceOf(address(shareToken));
            if (have < need) revert InsufficientVaultLiquidity(asset, need, have);
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
