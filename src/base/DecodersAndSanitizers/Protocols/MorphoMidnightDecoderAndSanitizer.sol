// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

// Struct layouts are VERBATIM (field types + order) from morpho-org/midnight `src/interfaces/IMidnight.sol`.
// Only the Solidity names differ (prefixed Midnight*) — the ABI tuple encoding, and therefore every function
// selector, is identical to the deployed contract. Do not reorder or retype fields.

// @desc one collateral slot of a Midnight market
struct MidnightCollateralParams {
    address token;
    uint256 lltv;
    uint256 liquidationCursor;
    address oracle;
}

// @desc a Midnight market (isolated, immutable, fixed-maturity)
struct MidnightMarket {
    uint256 chainId;
    address midnight;
    address loanToken;
    MidnightCollateralParams[] collateralParams;
    uint256 maturity;
    uint256 rcfThreshold;
    address enterGate;
    address liquidatorGate;
}

// @desc a signed Midnight offer consumed by `take` (direction set by `buy`)
struct MidnightOffer {
    MidnightMarket market;
    bool buy;
    address maker;
    uint256 start;
    uint256 expiry;
    uint256 tick;
    bytes32 group;
    address callback;
    bytes callbackData;
    address receiverIfMakerIsSeller;
    address ratifier;
    bool reduceOnly;
    uint128 maxUnits;
    uint128 maxAssets;
    uint256 continuousFeeCap;
}

/**
 * @title MorphoMidnightDecoderAndSanitizer
 * @notice Decoder / sanitizer for Morpho Midnight — a fixed-rate / fixed-term, offer/order-book-based
 *         lending protocol (distinct from Morpho Blue and MetaMorpho). Lending and borrowing are done by
 *         trading "credit units" and "debt units" via a single `take` entry point (direction = `offer.buy`);
 *         collateral, repay, withdraw, flash loans and liquidations are separate actions. Signatures and
 *         struct layouts are verbatim from morpho-org/midnight `src/interfaces/IMidnight.sol`.
 * @dev The `MidnightMarket` struct fully identifies a market by address (loanToken, per-collateral token &
 *      oracle, and the gate addresses); `_marketAddresses` pins all of them so the merkle root constrains
 *      exactly which market an action touches.
 * @dev CALLBACKS: several actions carry a `callback` address (and opaque callback `data`) that Midnight
 *      invokes mid-action — an arbitrary-code / reentrancy surface. This decoder PINS every callback address
 *      so the root controls the target, but it does NOT (and cannot) sanitize the callback `data`. Only
 *      whitelist callback targets you fully trust; pin a callback to `address(0)` in the leaf to forbid one.
 * @dev `multicall(bytes[])` is intentionally NOT decoded here: its nested calls cannot be statically
 *      sanitized by a pure decoder, so allowing it would bypass per-action pinning. Batch via individual
 *      merkle-verified manage calls instead. `Offer.callbackData` / `ratifierData` / action `data` are
 *      opaque and unconstrained beyond the pinned callback target.
 * @custom:security-contact security@theoriq.ai
 */
abstract contract MorphoMidnightDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== MORPHO MIDNIGHT ===============================

    // @desc Take (consume) a Midnight offer — the buy/sell-units (i.e. lend/borrow) entry point
    // @tag market:bytes:packed market addresses (midnight, loanToken, gates, each collateral token+oracle)
    // @tag maker:address:the offer maker
    // @tag offerCallback:address:the maker offer's callback target
    // @tag receiverIfMakerIsSeller:address:where the maker receives assets if selling
    // @tag ratifier:address:the offer ratifier
    // @tag taker:address:the account taking the offer
    // @tag receiverIfTakerIsSeller:address:where the taker receives assets if selling
    // @tag takerCallback:address:the taker's callback target
    function take(
        MidnightOffer calldata offer,
        bytes calldata,
        uint256,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes calldata
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(
            _marketAddresses(offer.market),
            offer.maker,
            offer.callback,
            offer.receiverIfMakerIsSeller,
            offer.ratifier,
            taker,
            receiverIfTakerIsSeller,
            takerCallback
        );
    }

    // @desc Withdraw units / proceeds from a Midnight market
    // @tag market:bytes:packed market addresses
    // @tag onBehalf:address:the account whose units are withdrawn
    // @tag receiver:address:the recipient of the withdrawn assets
    function withdraw(
        MidnightMarket calldata market,
        uint256,
        address onBehalf,
        address receiver
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_marketAddresses(market), onBehalf, receiver);
    }

    // @desc Repay debt units on a Midnight market
    // @tag market:bytes:packed market addresses
    // @tag onBehalf:address:the account whose debt is repaid
    // @tag callback:address:the repay callback target (pinned; data unsanitized)
    function repay(
        MidnightMarket calldata market,
        uint256,
        address onBehalf,
        address callback,
        bytes calldata
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_marketAddresses(market), onBehalf, callback);
    }

    // @desc Supply collateral to a Midnight market position
    // @tag market:bytes:packed market addresses
    // @tag onBehalf:address:the account credited with the collateral
    function supplyCollateral(
        MidnightMarket calldata market,
        uint256,
        uint256,
        address onBehalf
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_marketAddresses(market), onBehalf);
    }

    // @desc Withdraw collateral from a Midnight market position
    // @tag market:bytes:packed market addresses
    // @tag onBehalf:address:the account debited the collateral
    // @tag receiver:address:the recipient of the collateral
    function withdrawCollateral(
        MidnightMarket calldata market,
        uint256,
        uint256,
        address onBehalf,
        address receiver
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_marketAddresses(market), onBehalf, receiver);
    }

    // @desc Multi-token, fee-free Midnight flash loan
    // @tag callback:address:the flash-loan callback target (pinned; data unsanitized)
    // @tag tokens:address[]:each flash-loaned token, in order
    function flashLoan(
        address[] calldata tokens,
        uint256[] calldata,
        address callback,
        bytes calldata
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(callback);
        for (uint256 i; i < tokens.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, tokens[i]);
        }
    }

    // @desc Liquidate an unhealthy Midnight borrower
    // @tag market:bytes:packed market addresses
    // @tag borrower:address:the borrower being liquidated
    // @tag receiver:address:the recipient of the seized collateral
    // @tag callback:address:the liquidate callback target (pinned; data unsanitized)
    function liquidate(
        MidnightMarket calldata market,
        uint256,
        uint256,
        uint256,
        address borrower,
        bool,
        address receiver,
        address callback,
        bytes calldata
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_marketAddresses(market), borrower, receiver, callback);
    }

    // @desc Authorize / deauthorize an account to act on the caller's Midnight positions
    // @tag authorized:address:the account being (de)authorized
    // @tag onBehalf:address:the account granting authorization
    function setIsAuthorized(
        address authorized,
        bool,
        address onBehalf
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(authorized, onBehalf);
    }

    // @desc Set the consumed amount for an offer group (offer consumption limit)
    // @tag onBehalf:address:the account whose consumption limit is set
    function setConsumed(
        bytes32,
        uint128,
        address onBehalf
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(onBehalf);
    }

    // @desc Touch (create / refresh) a Midnight market
    // @tag market:bytes:packed market addresses
    function touchMarket(MidnightMarket calldata market) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = _marketAddresses(market);
    }

    // @desc Accrue the continuous fee on a user's Midnight position
    // @tag market:bytes:packed market addresses
    // @tag user:address:the position owner
    function updatePosition(
        MidnightMarket calldata market,
        address user
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(_marketAddresses(market), user);
    }

    //============================== INTERNAL ===============================

    /// @dev Packs every address that identifies a Midnight market: the protocol instance, the loan token,
    ///      the enter/liquidator gates, and each collateral slot's token + oracle (in order). This is what
    ///      lets the merkle root pin exactly which market (and which collaterals/oracles) an action targets.
    function _marketAddresses(MidnightMarket calldata market) internal pure returns (bytes memory packed) {
        packed = abi.encodePacked(market.midnight, market.loanToken, market.enterGate, market.liquidatorGate);
        uint256 len = market.collateralParams.length;
        for (uint256 i; i < len; ++i) {
            packed = abi.encodePacked(packed, market.collateralParams[i].token, market.collateralParams[i].oracle);
        }
    }

}
