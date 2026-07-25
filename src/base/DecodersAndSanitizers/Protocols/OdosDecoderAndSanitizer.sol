// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer, DecoderCustomTypes } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @title OdosDecoderAndSanitizer
 * @notice Decoder & sanitizer for Odos' OdosRouterV2
 *         (mainnet 0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559).
 * @dev Security model mirrors OneInchDecoderAndSanitizer: the merkle leaf pins the input/output
 *      tokens, the input/output receivers, and the `executor`. The strategist's root should
 *      constrain `outputReceiver` (and every `receiver` in swapMulti) to the BoringVault. The
 *      `pathDefinition` blob (Odos' compact route encoding) is NOT decoded; it is bounded by the
 *      router enforcing `outputMin`/`valueOutMin` is delivered to the pinned receivers.
 * @dev The calldata-optimized `swapCompact()`/`swapMultiCompact()` entrypoints use a custom,
 *      non-ABI calldata layout and therefore cannot be sanitized by a selector-matched decoder;
 *      route strategist swaps through `swap`/`swapMulti` instead.
 */
abstract contract OdosDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ODOS ===============================

    // @desc single-input single-output swap via Odos RouterV2
    // @tag inputToken:address:token supplied to the swap
    // @tag inputReceiver:address:contract the input token is routed to
    // @tag outputToken:address:token received from the swap
    // @tag outputReceiver:address:receiver of the output token (pin to the vault)
    // @tag executor:address:the Odos executor that runs the route
    function swap(
        DecoderCustomTypes.OdosSwapTokenInfo calldata tokenInfo,
        bytes calldata,
        address executor,
        uint32
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(
            tokenInfo.inputToken, tokenInfo.inputReceiver, tokenInfo.outputToken, tokenInfo.outputReceiver, executor
        );
    }

    // @desc multi-input multi-output swap via Odos RouterV2
    // @tag inputs:address:each input token and the contract it is routed to
    // @tag outputs:address:each output token and its receiver (pin receivers to the vault)
    // @tag executor:address:the Odos executor that runs the route
    function swapMulti(
        DecoderCustomTypes.OdosInputTokenInfo[] calldata inputs,
        DecoderCustomTypes.OdosOutputTokenInfo[] calldata outputs,
        uint256,
        bytes calldata,
        address executor,
        uint32
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        // @dev inputs and outputs are concatenated without a length delimiter (C12). Safe: every address
        // appended is drawn from the caller-supplied inputs/outputs arrays, so the strategist cannot smuggle
        // in an unauthorized address — the merkle root author pins each token/receiver that may appear.
        for (uint256 i; i < inputs.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, inputs[i].tokenAddress, inputs[i].receiver);
        }
        for (uint256 i; i < outputs.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, outputs[i].tokenAddress, outputs[i].receiver);
        }
        addressesFound = abi.encodePacked(addressesFound, executor);
    }

}
