// SPDX-License-Identifier: MIT

pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { OneInchDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/OneInchDecoderAndSanitizer.sol";
import { KyberSwapDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/KyberSwapDecoderAndSanitizer.sol";
import { OdosDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/OdosDecoderAndSanitizer.sol";

/**
 * @title AggregatorDecoderAndSanitizer
 * @notice Concrete decoder & sanitizer bundling the DEX aggregators that can be SAFELY sanitized by
 *         a selector-matched decoder: 1inch, KyberSwap, and Odos. Deploy one per BoringVault and
 *         reference it from the strategist's merkle leaves for aggregator swaps.
 * @dev Each aggregator's `swap` overload has a distinct selector, so they coexist without collision.
 *      Every mixin ultimately inherits BaseDecoderAndSanitizer, which supplies approve/transfer.
 * @dev OKX is intentionally EXCLUDED. The deployed OKX DexRouter parses an optional commission blob
 *      appended after the ABI arguments (magic 0x3ca20afc, read via calldatasize()), paying an
 *      arbitrary `referrer`. That trailing calldata is invisible to ABI-decoding, so it never enters
 *      packedArgumentAddresses and the merkle leaf is identical with or without it — a strategist
 *      could append it to skim funds. OKXDecoderAndSanitizer is retained for reference/off-chain use
 *      but must NOT be merkle-enabled for direct router calls. See its NatSpec.
 */
contract AggregatorDecoderAndSanitizer is
    OneInchDecoderAndSanitizer,
    KyberSwapDecoderAndSanitizer,
    OdosDecoderAndSanitizer
{

    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

}
