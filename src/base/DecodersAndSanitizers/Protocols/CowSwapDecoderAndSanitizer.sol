// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { GPv2Order, CowSwapLimitParams } from "src/interfaces/IGPv2.sol";

/**
 * @title CowSwapDecoderAndSanitizer
 * @notice Decoder & sanitizer for calls to a CowSwapOrderModule. It sanitizes the MODULE's calls (pinning
 *         the sell/buy tokens); the module itself enforces order integrity, receiver, and the uid binding —
 *         checks a pure decoder cannot perform. The module contract is pinned by the merkle leaf `target`.
 * @dev The vault first transfers the sell token to the module via a plain `ERC20.transfer` (sanitized by
 *      BaseDecoderAndSanitizer, which pins the module as recipient), so no extra entry is needed for that.
 */
abstract contract CowSwapDecoderAndSanitizer is BaseDecoderAndSanitizer {

    // @desc create an on-chain CoW limit order via the module
    // @tag tokenIn:address:the sell token
    // @tag tokenOut:address:the buy token
    function createLimitOrder(
        CowSwapLimitParams calldata params,
        GPv2Order.Data calldata,
        bytes calldata
    )
        external
        pure
        virtual
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(params.tokenIn, params.tokenOut);
    }

    // @desc approve the CoW VaultRelayer for a sell token via the module
    // @tag token:address:the sell token to approve
    function setCowswapApproval(address token, uint256) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(token);
    }

    // @desc invalidate a CoW order via the module (uid is opaque — nothing to pin)
    function invalidateOrder(bytes calldata) external pure virtual returns (bytes memory) {
        return "";
    }

    // @desc pull proceeds (or an un-filled sell token) from the module back to the vault
    // @tag token:address:the token to pull
    function pullAssets(address token, uint256) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(token);
    }

    // @desc allow-list a token on the module (admin action)
    // @tag token:address:the token to allow-list
    function setAllowedToken(address token, bool) external pure virtual returns (bytes memory addressesFound) {
        addressesFound = abi.encodePacked(token);
    }

}
