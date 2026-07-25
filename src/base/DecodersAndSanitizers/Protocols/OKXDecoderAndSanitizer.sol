// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {
    BaseDecoderAndSanitizer,
    DecoderCustomTypes
} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @title OKXDecoderAndSanitizer
 * @notice Decoder & sanitizer for the OKX DexRouter
 *         (mainnet 0x6088d94C5A40CecD3Ae2d4E0710Ca687b91C61d0).
 *
 * @dev  ██ SECURITY: DO NOT merkle-enable these entrypoints for direct calls to the OKX router. ██
 *      The deployed OKX DexRouter reads an OPTIONAL commission blob appended AFTER the ABI arguments
 *      (flagged by magic 0x3ca20afc and parsed via calldatasize()), paying up to the router's
 *      commission cap to an arbitrary `referrer`/`commissionReceiver`. Because that blob is trailing
 *      calldata, Solidity ABI-decoding here silently ignores it: it never appears in the returned
 *      packedArgumentAddresses, so the manager's leaf = keccak256(decoder, target, valueNonZero,
 *      selector, packedAddresses) is byte-identical with or without it. A strategist can therefore
 *      append a commission suffix pointing `referrer` at themselves to ANY authorized OKX leaf and
 *      skim value on every swap — `minReturn` does not neutralize it (the skim is outside the pinned
 *      receiver amount). This defeats the merkle sanitization model and is unique to OKX among the
 *      supported aggregators. OKX is consequently EXCLUDED from AggregatorDecoderAndSanitizer.
 *
 *      To route the vault through OKX safely, call it via a wrapper that forbids trailing calldata
 *      (so no commission blob can be injected) and sanitize the wrapper instead. This contract is
 *      retained for reference / off-chain decoding only.
 *
 * @dev Sanitization detail (were the commission vector not present, the model would mirror
 *      OneInchDecoderAndSanitizer): pin the swap `receiver` plus the src/dst tokens; the internal
 *      route is bounded by the router's `minReturnAmount` to the pinned receiver. OKX packs several
 *      address arguments into `uint256` (address in the low 160 bits, flags/orderId above), unpacked
 *      here with `uint160`.
 */
abstract contract OKXDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== OKX ===============================

    // @desc smart swap to a receiver via the OKX DexRouter
    // @tag receiver:address:receiver of the output token (pin to the vault)
    // @tag fromToken:address:source token (unpacked from the low 160 bits of baseRequest.fromToken)
    // @tag toToken:address:destination token
    function smartSwapTo(
        uint256,
        address receiver,
        DecoderCustomTypes.OKXBaseRequest calldata baseRequest,
        uint256[] calldata,
        DecoderCustomTypes.OKXRouterPath[][] calldata,
        DecoderCustomTypes.OKXPMMSwapRequest[] calldata
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound =
            abi.encodePacked(receiver, address(uint160(baseRequest.fromToken)), baseRequest.toToken);
    }

    // @desc unxswap to a receiver via the OKX DexRouter
    // @tag srcToken:address:source token (unpacked from the low 160 bits of srcToken)
    // @tag receiver:address:receiver of the output token (pin to the vault)
    function unxswapTo(
        uint256 srcToken,
        uint256,
        uint256,
        address receiver,
        bytes32[] calldata
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(address(uint160(srcToken)), receiver);
    }

    // @desc uniswapV3 swap to a receiver via the OKX DexRouter
    // @tag receiver:address:receiver of the output token (unpacked from the low 160 bits; pin to the vault)
    // @tag pools:address:each pool address in the route (unpacked from the low 160 bits)
    function uniswapV3SwapTo(
        uint256 receiver,
        uint256,
        uint256,
        uint256[] calldata pools
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(address(uint160(receiver)));
        for (uint256 i; i < pools.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, address(uint160(pools[i])));
        }
    }

}
