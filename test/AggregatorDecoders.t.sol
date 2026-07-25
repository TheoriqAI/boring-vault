// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { AggregatorDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/AggregatorDecoderAndSanitizer.sol";
import { KyberSwapDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/KyberSwapDecoderAndSanitizer.sol";
import { OKXDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/OKXDecoderAndSanitizer.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { DecoderCustomTypes } from "src/interfaces/DecoderCustomTypes.sol";

/**
 * @notice Standalone harness for OKXDecoderAndSanitizer. OKX is deliberately NOT part of the
 *         deployable AggregatorDecoderAndSanitizer (its router's trailing commission blob defeats the
 *         merkle sanitization model — see OKXDecoderAndSanitizer NatSpec). These tests validate that
 *         the decoder DECODES correctly, not that OKX is safe to merkle-enable.
 */
contract OKXDecoderHarness is OKXDecoderAndSanitizer {

    constructor(address _boringVault) BaseDecoderAndSanitizer(_boringVault) { }

}

/**
 * @notice Unit tests for the KyberSwap / OKX / Odos decoder & sanitizers. Each test builds calldata
 *         under the selector computed from the VERIFIED on-chain router signature string, so a
 *         call that decodes (rather than hitting the fallback) proves the decoder's selector matches
 *         the deployed router byte-for-byte. It then asserts the exact packed address set the merkle
 *         leaf will pin.
 */
contract AggregatorDecodersTest is Test {

    AggregatorDecoderAndSanitizer internal decoder;
    OKXDecoderHarness internal okx;

    address internal constant VAULT = address(0xBEEF);
    address internal constant SRC = address(0x1111);
    address internal constant DST = address(0x2222);
    address internal constant CT = address(0x3333);
    address internal constant AT = address(0x4444);
    address internal constant SR = address(0x5555);
    address internal constant FR = address(0x6666);
    address internal constant EXEC = address(0x7777);
    address internal constant POOL = address(0x8888);

    // Arbitrary high-bit flags OKX packs above the address; the sanitizer must strip them.
    uint256 internal constant FLAGS = uint256(0xdeadbeef) << 160;

    function setUp() external {
        decoder = new AggregatorDecoderAndSanitizer(VAULT);
        okx = new OKXDecoderHarness(VAULT);
    }

    function _decodeAt(address target, bytes memory callData) internal view returns (bytes memory packed) {
        (bool ok, bytes memory ret) = target.staticcall(callData);
        require(ok, "decoder reverted / selector mismatch");
        packed = abi.decode(ret, (bytes));
    }

    function _decode(bytes memory callData) internal view returns (bytes memory packed) {
        packed = _decodeAt(address(decoder), callData);
    }

    //============================== KYBERSWAP ===============================

    function testKyberSwap() external {
        bytes4 sel = bytes4(
            keccak256(
                "swap((address,address,bytes,(address,address,address[],uint256[],address[],uint256[],address,uint256,uint256,uint256,bytes),bytes))"
            )
        );
        address[] memory srcReceivers = new address[](1);
        srcReceivers[0] = SR;
        address[] memory feeReceivers = new address[](1);
        feeReceivers[0] = FR;
        DecoderCustomTypes.KyberSwapExecutionParams memory ex = DecoderCustomTypes.KyberSwapExecutionParams({
            callTarget: CT,
            approveTarget: AT,
            targetData: hex"",
            desc: DecoderCustomTypes.KyberSwapDescriptionV2({
                srcToken: SRC,
                dstToken: DST,
                srcReceivers: srcReceivers,
                srcAmounts: new uint256[](0),
                feeReceivers: feeReceivers,
                feeAmounts: new uint256[](0),
                dstReceiver: VAULT,
                amount: 1e18,
                minReturnAmount: 1,
                flags: 0,
                permit: hex""
            }),
            clientData: hex""
        });
        bytes memory packed = _decode(abi.encodeWithSelector(sel, ex));
        assertEq(packed, abi.encodePacked(CT, AT, SRC, DST, VAULT, SR, FR), "kyber swap packed mismatch");
    }

    function testKyberSwapRejectsPermit() external {
        bytes4 sel = bytes4(
            keccak256(
                "swap((address,address,bytes,(address,address,address[],uint256[],address[],uint256[],address,uint256,uint256,uint256,bytes),bytes))"
            )
        );
        DecoderCustomTypes.KyberSwapExecutionParams memory ex = DecoderCustomTypes.KyberSwapExecutionParams({
            callTarget: CT,
            approveTarget: AT,
            targetData: hex"",
            desc: DecoderCustomTypes.KyberSwapDescriptionV2({
                srcToken: SRC,
                dstToken: DST,
                srcReceivers: new address[](0),
                srcAmounts: new uint256[](0),
                feeReceivers: new address[](0),
                feeAmounts: new uint256[](0),
                dstReceiver: VAULT,
                amount: 1e18,
                minReturnAmount: 1,
                flags: 0,
                permit: hex"01"
            }),
            clientData: hex""
        });
        (bool ok, bytes memory ret) = address(decoder).staticcall(abi.encodeWithSelector(sel, ex));
        assertFalse(ok, "permit swap should revert");
        assertEq(bytes4(ret), KyberSwapDecoderAndSanitizer.KyberSwapDecoderAndSanitizer__PermitNotSupported.selector);
    }

    function testKyberSwapSimpleMode() external {
        bytes4 sel = bytes4(
            keccak256(
                "swapSimpleMode(address,(address,address,address[],uint256[],address[],uint256[],address,uint256,uint256,uint256,bytes),bytes,bytes)"
            )
        );
        address[] memory srcReceivers = new address[](1);
        srcReceivers[0] = SR;
        DecoderCustomTypes.KyberSwapDescriptionV2 memory desc = DecoderCustomTypes.KyberSwapDescriptionV2({
            srcToken: SRC,
            dstToken: DST,
            srcReceivers: srcReceivers,
            srcAmounts: new uint256[](0),
            feeReceivers: new address[](0),
            feeAmounts: new uint256[](0),
            dstReceiver: VAULT,
            amount: 1e18,
            minReturnAmount: 1,
            flags: 0,
            permit: hex""
        });
        bytes memory packed = _decode(abi.encodeWithSelector(sel, CT, desc, hex"", hex""));
        assertEq(packed, abi.encodePacked(CT, SRC, DST, VAULT, SR), "kyber simple packed mismatch");
    }

    //============================== ODOS ===============================

    function testOdosSwap() external {
        bytes4 sel =
            bytes4(keccak256("swap((address,uint256,address,address,uint256,uint256,address),bytes,address,uint32)"));
        DecoderCustomTypes.OdosSwapTokenInfo memory info = DecoderCustomTypes.OdosSwapTokenInfo({
            inputToken: SRC,
            inputAmount: 1e18,
            inputReceiver: AT,
            outputToken: DST,
            outputQuote: 1e18,
            outputMin: 1,
            outputReceiver: VAULT
        });
        bytes memory packed = _decode(abi.encodeWithSelector(sel, info, hex"aabb", EXEC, uint32(0)));
        assertEq(packed, abi.encodePacked(SRC, AT, DST, VAULT, EXEC), "odos swap packed mismatch");
    }

    function testOdosSwapMulti() external {
        bytes4 sel = bytes4(
            keccak256("swapMulti((address,uint256,address)[],(address,uint256,address)[],uint256,bytes,address,uint32)")
        );
        DecoderCustomTypes.OdosInputTokenInfo[] memory inputs = new DecoderCustomTypes.OdosInputTokenInfo[](1);
        inputs[0] = DecoderCustomTypes.OdosInputTokenInfo({ tokenAddress: SRC, amountIn: 1e18, receiver: AT });
        DecoderCustomTypes.OdosOutputTokenInfo[] memory outputs = new DecoderCustomTypes.OdosOutputTokenInfo[](1);
        outputs[0] = DecoderCustomTypes.OdosOutputTokenInfo({ tokenAddress: DST, relativeValue: 1, receiver: VAULT });
        bytes memory packed = _decode(abi.encodeWithSelector(sel, inputs, outputs, uint256(1), hex"aabb", EXEC, uint32(0)));
        assertEq(packed, abi.encodePacked(SRC, AT, DST, VAULT, EXEC), "odos swapMulti packed mismatch");
    }

    //============================== OKX ===============================

    function testOkxSmartSwapTo() external {
        bytes4 sel = bytes4(
            keccak256(
                "smartSwapTo(uint256,address,(uint256,address,uint256,uint256,uint256),uint256[],(address[],address[],uint256[],bytes[],uint256)[][],(uint256,address,address,address,uint256,uint256,uint256,uint256,bool,bytes)[])"
            )
        );
        assertEq(sel, okx.smartSwapTo.selector, "smartSwapTo selector mismatch");
        DecoderCustomTypes.OKXBaseRequest memory baseRequest = DecoderCustomTypes.OKXBaseRequest({
            fromToken: uint256(uint160(SRC)) | FLAGS, // address in low 160 bits, flags above
            toToken: DST,
            fromTokenAmount: 1e18,
            minReturnAmount: 1,
            deadLine: type(uint256).max
        });
        bytes memory callData = abi.encodeWithSelector(
            sel,
            uint256(0),
            VAULT,
            baseRequest,
            new uint256[](0),
            new DecoderCustomTypes.OKXRouterPath[][](0),
            new DecoderCustomTypes.OKXPMMSwapRequest[](0)
        );
        bytes memory packed = _decodeAt(address(okx), callData);
        assertEq(packed, abi.encodePacked(VAULT, SRC, DST), "okx smartSwapTo packed mismatch (flags not stripped?)");
    }

    function testOkxUnxswapTo() external {
        bytes4 sel = bytes4(keccak256("unxswapTo(uint256,uint256,uint256,address,bytes32[])"));
        assertEq(sel, okx.unxswapTo.selector, "unxswapTo selector mismatch");
        bytes memory callData =
            abi.encodeWithSelector(sel, uint256(uint160(SRC)) | FLAGS, uint256(1e18), uint256(1), VAULT, new bytes32[](0));
        bytes memory packed = _decodeAt(address(okx), callData);
        assertEq(packed, abi.encodePacked(SRC, VAULT), "okx unxswapTo packed mismatch");
    }

    function testOkxUniswapV3SwapTo() external {
        bytes4 sel = bytes4(keccak256("uniswapV3SwapTo(uint256,uint256,uint256,uint256[])"));
        assertEq(sel, okx.uniswapV3SwapTo.selector, "uniswapV3SwapTo selector mismatch");
        uint256[] memory pools = new uint256[](1);
        pools[0] = uint256(uint160(POOL)) | FLAGS;
        bytes memory callData =
            abi.encodeWithSelector(sel, uint256(uint160(VAULT)) | FLAGS, uint256(1e18), uint256(1), pools);
        bytes memory packed = _decodeAt(address(okx), callData);
        assertEq(packed, abi.encodePacked(VAULT, POOL), "okx uniswapV3SwapTo packed mismatch");
    }

}
