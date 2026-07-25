// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer, DecoderCustomTypes } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @title KyberSwapDecoderAndSanitizer
 * @notice Decoder & sanitizer for KyberSwap's MetaAggregationRouterV2
 *         (mainnet 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5).
 * @dev Security model mirrors OneInchDecoderAndSanitizer: the merkle leaf pins the swap target
 *      (call/approve targets), the src/dst tokens, and every receiver — most importantly
 *      `dstReceiver`, which the strategist's merkle root should constrain to the BoringVault. The
 *      inner `targetData`/`executorData` (the aggregator's arbitrary execution calldata) is NOT
 *      decoded; it is bounded by the router enforcing `desc.minReturnAmount` is delivered to the
 *      pinned `dstReceiver`. Permit-based swaps are rejected so the vault never signs an approval
 *      inside the router call.
 */
abstract contract KyberSwapDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== ERRORS ===============================

    error KyberSwapDecoderAndSanitizer__PermitNotSupported();

    //============================== KYBERSWAP ===============================

    // @desc swap tokens with KyberSwap MetaAggregationRouterV2; reverts if a permit is attached
    // @tag callTarget:address:the contract KyberSwap calls to execute the swap
    // @tag approveTarget:address:the contract granted the token approval to pull srcToken
    // @tag srcToken:address:source token
    // @tag dstToken:address:destination token
    // @tag dstReceiver:address:receiver of the output token (pin to the vault)
    // @tag srcReceivers:address:receivers of the input token / fees along the route
    function swap(DecoderCustomTypes.KyberSwapExecutionParams calldata execution)
        external
        pure
        returns (bytes memory addressesFound)
    {
        if (execution.desc.permit.length > 0) revert KyberSwapDecoderAndSanitizer__PermitNotSupported();
        addressesFound = abi.encodePacked(
            execution.callTarget,
            execution.approveTarget,
            execution.desc.srcToken,
            execution.desc.dstToken,
            execution.desc.dstReceiver
        );
        // @dev srcReceivers and feeReceivers are concatenated without a length delimiter (C12). This is
        // safe here: the security-critical dstReceiver sits at a fixed offset above, and every address
        // appended below is drawn from the router's own receiver arrays — the strategist cannot introduce
        // an address that isn't already one the merkle root author chose to authorize.
        for (uint256 i; i < execution.desc.srcReceivers.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, execution.desc.srcReceivers[i]);
        }
        for (uint256 i; i < execution.desc.feeReceivers.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, execution.desc.feeReceivers[i]);
        }
    }

    // @desc swap tokens with KyberSwap in simple mode; reverts if a permit is attached
    // @tag caller:address:the aggregation executor KyberSwap delegates the swap to
    // @tag srcToken:address:source token
    // @tag dstToken:address:destination token
    // @tag dstReceiver:address:receiver of the output token (pin to the vault)
    // @tag srcReceivers:address:receivers of the input token / fees along the route
    function swapSimpleMode(
        address caller,
        DecoderCustomTypes.KyberSwapDescriptionV2 calldata desc,
        bytes calldata,
        bytes calldata
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        if (desc.permit.length > 0) revert KyberSwapDecoderAndSanitizer__PermitNotSupported();
        addressesFound = abi.encodePacked(caller, desc.srcToken, desc.dstToken, desc.dstReceiver);
        for (uint256 i; i < desc.srcReceivers.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, desc.srcReceivers[i]);
        }
        for (uint256 i; i < desc.feeReceivers.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, desc.feeReceivers[i]);
        }
    }

}
