// SPDX-License-Identifier: MIT

pragma solidity 0.8.21;

// ██████████████████████████████████ AUDIT NOTE ██████████████████████████████████
// This "next-gen / full" decoder is intended to SUPERSEDE the currently deployed & audited
// GenericDecoderAndSanitizer (mainnet/Celo 0x7c70ddb9306f9e2f7a56b6fe7497b7c9ccd5502c). That contract and
// its exact source are left UNTOUCHED as the live/audited reference. For the NEXT audit, please switch the
// audited target to THIS FullDecoderAndSanitizer: it is the Generic set PLUS KyberSwap, Odos, Euler (full
// EVC/EVault + batch), CowSwap, Aave V4 (Hub-and-Spoke) and Morpho Midnight, and it also carries the Pendle
// on-chain-limit-order sanitization.
// OKX is INTENTIONALLY EXCLUDED (its router's trailing commission blob defeats a selector-matched decoder).
// NOT DEPLOYED / NOT WIRED — deploying it requires a decoder redeploy under a new name + merkle-root rebuild.
// █████████████████████████████████████████████████████████████████████████████████

import {
    PendleRouterDecoderAndSanitizer,
    BaseDecoderAndSanitizer
} from "src/base/DecodersAndSanitizers/Protocols/PendleRouterDecoderAndSanitizer.sol";
import { UniswapV3DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/UniswapV3DecoderAndSanitizer.sol";
import { OneInchDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/OneInchDecoderAndSanitizer.sol";
import { CurveDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/CurveDecoderAndSanitizer.sol";
import { NativeWrapperDecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/Protocols/NativeWrapperDecoderAndSanitizer.sol";
import { ERC4626DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/ERC4626DecoderAndSanitizer.sol";
import { EigenpieDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/EigenpieDecoderAndSanitizer.sol";
import { PirexEthDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/PirexEthDecoderAndSanitizer.sol";
import { AaveV3DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/AaveV3DecoderAndSanitizer.sol";
import { VelodromeV1DecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/Protocols/VelodromeV1DecoderAndSanitizer.sol";
import { FlashHypeDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/FlashHypeDecoderAndSanitizer.sol";
import { CircleDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/CircleDecoderAndSanitizer.sol";
import { BalancerV2DecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/Protocols/BalancerV2DecoderAndSanitizer.sol";
import { MorphoBlueDecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/Protocols/MorphoBlueDecoderAndSanitizer.sol";
import { EtherFiDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/EtherFiDecoderAndSanitizer.sol";
import { LayerZeroOFTDecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/Protocols/LayerZeroOFTDecoderAndSanitizer.sol";
import { NucleusDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/NucleusDecoderAndSanitizer.sol";
import { CoreWriterDecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/Protocols/CoreWriterDecoderAndSanitizer.sol";
// ---- next-gen additions ----
import { KyberSwapDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/KyberSwapDecoderAndSanitizer.sol";
import { OdosDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/OdosDecoderAndSanitizer.sol";
import { EulerDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/EulerDecoderAndSanitizer.sol";
import { CowSwapDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/CowSwapDecoderAndSanitizer.sol";
import { AaveV4DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/AaveV4DecoderAndSanitizer.sol";
import { MorphoMidnightDecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/Protocols/MorphoMidnightDecoderAndSanitizer.sol";

/**
 * @custom:security-contact security@theoriq.ai
 */
contract FullDecoderAndSanitizer is
    PendleRouterDecoderAndSanitizer,
    UniswapV3DecoderAndSanitizer,
    OneInchDecoderAndSanitizer,
    CurveDecoderAndSanitizer,
    NativeWrapperDecoderAndSanitizer,
    ERC4626DecoderAndSanitizer,
    EigenpieDecoderAndSanitizer,
    PirexEthDecoderAndSanitizer,
    AaveV3DecoderAndSanitizer,
    VelodromeV1DecoderAndSanitizer,
    FlashHypeDecoderAndSanitizer,
    CircleDecoderAndSanitizer,
    BalancerV2DecoderAndSanitizer,
    MorphoBlueDecoderAndSanitizer,
    EtherFiDecoderAndSanitizer,
    LayerZeroOFTDecoderAndSanitizer,
    NucleusDecoderAndSanitizer,
    CoreWriterDecoderAndSanitizer,
    KyberSwapDecoderAndSanitizer,
    OdosDecoderAndSanitizer,
    EulerDecoderAndSanitizer,
    CowSwapDecoderAndSanitizer,
    AaveV4DecoderAndSanitizer,
    MorphoMidnightDecoderAndSanitizer
{

    constructor(
        address _boringVault,
        address _uniswapV3NonFungiblePositionManager
    )
        BaseDecoderAndSanitizer(_boringVault)
        UniswapV3DecoderAndSanitizer(_uniswapV3NonFungiblePositionManager)
    { }

    function deposit(
        uint256,
        address receiver
    )
        external
        pure
        override(CurveDecoderAndSanitizer, ERC4626DecoderAndSanitizer, BalancerV2DecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(receiver);
    }

    function withdraw(uint256)
        external
        pure
        override(CurveDecoderAndSanitizer, NativeWrapperDecoderAndSanitizer, BalancerV2DecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        // Nothing to sanitize or return
        return addressesFound;
    }

    function deposit()
        external
        pure
        virtual
        override(NativeWrapperDecoderAndSanitizer, EtherFiDecoderAndSanitizer)
        returns (bytes memory addressesFound)
    {
        // Nothing to sanitize or return
        return addressesFound;
    }

}
