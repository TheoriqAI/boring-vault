// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @title AaveV4DecoderAndSanitizer
 * @notice Decoder / sanitizer for Aave V4, which uses a Hub-and-Spoke liquidity model. End users and
 *         integrators interact with SPOKE contracts (the merkle leaf's `target` is a Spoke). A Spoke draws
 *         liquidity from a central Liquidity Hub internally, so the Hub is never called directly by the
 *         vault and needs no leaves of its own. Signatures are verbatim from aave-v4 `src/spoke/interfaces/
 *         ISpoke.sol`.
 * @dev IMPORTANT — the market/asset CANNOT be pinned by this decoder. In Aave V4 a reserve is identified by
 *      a `uint256 reserveId` (a Spoke-local index), NOT by the asset token address. A decoder can only pin
 *      ADDRESS arguments, and `reserveId` is not an address, so the merkle root cannot restrict WHICH
 *      reserve an action touches — only the address arguments (`onBehalfOf` / `user` / `positionManager`)
 *      are pinned. Constrain the market instead by choosing which Spoke `target` (and, off-chain, which
 *      `reserveId`) the leaf authorizes. This mirrors the AaveV3 decoder's philosophy: the decoder exposes
 *      the sensitive addresses and the root author pins them (e.g. `onBehalfOf == vault`).
 * @custom:security-contact security@theoriq.ai
 */
abstract contract AaveV4DecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== AAVE V4 (SPOKE) ===============================

    // @desc Supply to an Aave V4 Spoke reserve
    // @tag onBehalfOf:address:the account credited with the supplied liquidity
    function supply(uint256, uint256, address onBehalfOf) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(onBehalfOf);
    }

    // @desc Withdraw from an Aave V4 Spoke reserve
    // @tag onBehalfOf:address:the account debited for the withdrawal
    function withdraw(
        uint256,
        uint256,
        address onBehalfOf
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(onBehalfOf);
    }

    // @desc Borrow from an Aave V4 Spoke reserve
    // @tag onBehalfOf:address:the account that incurs the debt
    function borrow(uint256, uint256, address onBehalfOf) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(onBehalfOf);
    }

    // @desc Repay an Aave V4 Spoke debt
    // @tag onBehalfOf:address:the account whose debt is repaid
    function repay(uint256, uint256, address onBehalfOf) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(onBehalfOf);
    }

    // @desc Toggle whether a reserve is used as collateral for the account
    // @tag onBehalfOf:address:the account whose collateral setting changes
    function setUsingAsCollateral(
        uint256,
        bool,
        address onBehalfOf
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(onBehalfOf);
    }

    // @desc Liquidate an unhealthy Aave V4 position
    // @tag user:address:the borrower being liquidated
    function liquidationCall(
        uint256,
        uint256,
        address user,
        uint256,
        bool
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(user);
    }

    // @desc Approve or revoke a position manager for the caller's positions
    // @tag positionManager:address:the position manager being (dis)approved
    function setUserPositionManager(
        address positionManager,
        bool
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(positionManager);
    }

    // @desc Permit-based reserve approval on an Aave V4 Spoke
    // @tag onBehalfOf:address:the account granting the permit
    function permitReserve(
        uint256,
        address onBehalfOf,
        uint256,
        uint256,
        uint8,
        bytes32,
        bytes32
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(onBehalfOf);
    }

}
