// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {
    MorphoMidnightDecoderAndSanitizer,
    MidnightMarket,
    MidnightCollateralParams,
    MidnightOffer
} from "src/base/DecodersAndSanitizers/Protocols/MorphoMidnightDecoderAndSanitizer.sol";

contract MidnightHarness is MorphoMidnightDecoderAndSanitizer {

    constructor(address bv) BaseDecoderAndSanitizer(bv) { }

}

contract MorphoMidnightDecoderTest is Test {

    MidnightHarness internal d;

    address internal constant BV = address(0xBEEF);
    address internal constant MIDNIGHT = address(0x1111);
    address internal constant LOAN = address(0x2222);
    address internal constant ENTER_GATE = address(0x3333);
    address internal constant LIQ_GATE = address(0x4444);
    address internal constant COL0_TOKEN = address(0x5555);
    address internal constant COL0_ORACLE = address(0x6666);
    address internal constant COL1_TOKEN = address(0x7777);
    address internal constant COL1_ORACLE = address(0x8888);

    function setUp() external {
        d = new MidnightHarness(BV);
    }

    function _market() internal pure returns (MidnightMarket memory m) {
        m.chainId = 1;
        m.midnight = MIDNIGHT;
        m.loanToken = LOAN;
        m.collateralParams = new MidnightCollateralParams[](2);
        m.collateralParams[0] = MidnightCollateralParams(COL0_TOKEN, 8e17, 1e18, COL0_ORACLE);
        m.collateralParams[1] = MidnightCollateralParams(COL1_TOKEN, 7e17, 1e18, COL1_ORACLE);
        m.maturity = 123;
        m.rcfThreshold = 456;
        m.enterGate = ENTER_GATE;
        m.liquidatorGate = LIQ_GATE;
    }

    /// @dev the exact expected market-address packing: instance, loan, gates, then each collateral token+oracle
    function _marketPacked() internal pure returns (bytes memory) {
        return abi.encodePacked(MIDNIGHT, LOAN, ENTER_GATE, LIQ_GATE, COL0_TOKEN, COL0_ORACLE, COL1_TOKEN, COL1_ORACLE);
    }

    function _offer() internal pure returns (MidnightOffer memory o) {
        o.market = _market();
        o.buy = true;
        o.maker = address(0xAA01);
        o.callback = address(0xAA02);
        o.callbackData = "";
        o.receiverIfMakerIsSeller = address(0xAA03);
        o.ratifier = address(0xAA04);
    }

    // --- market packing --------------------------------------------------

    function testTouchMarketPacksAllMarketAddresses() external view {
        assertEq(d.touchMarket(_market()), _marketPacked());
    }

    function testUpdatePositionPinsMarketAndUser() external view {
        assertEq(d.updatePosition(_market(), address(0xC1)), abi.encodePacked(_marketPacked(), address(0xC1)));
    }

    // --- actions ---------------------------------------------------------

    function testTakePinsOfferAndTakerAddresses() external view {
        bytes memory got = d.take(_offer(), "", 100, address(0xBB01), address(0xBB02), address(0xBB03), "");
        assertEq(
            got,
            abi.encodePacked(
                _marketPacked(),
                address(0xAA01), // maker
                address(0xAA02), // offer callback
                address(0xAA03), // receiverIfMakerIsSeller
                address(0xAA04), // ratifier
                address(0xBB01), // taker
                address(0xBB02), // receiverIfTakerIsSeller
                address(0xBB03) // takerCallback
            )
        );
    }

    function testWithdrawPinsMarketOnBehalfReceiver() external view {
        assertEq(
            d.withdraw(_market(), 1, address(0xD1), address(0xD2)),
            abi.encodePacked(_marketPacked(), address(0xD1), address(0xD2))
        );
    }

    function testRepayPinsMarketOnBehalfCallback() external view {
        assertEq(
            d.repay(_market(), 1, address(0xE1), address(0xE2), ""),
            abi.encodePacked(_marketPacked(), address(0xE1), address(0xE2))
        );
    }

    function testSupplyCollateralPinsMarketOnBehalf() external view {
        assertEq(d.supplyCollateral(_market(), 0, 1, address(0xF1)), abi.encodePacked(_marketPacked(), address(0xF1)));
    }

    function testWithdrawCollateralPinsMarketOnBehalfReceiver() external view {
        assertEq(
            d.withdrawCollateral(_market(), 0, 1, address(0xF1), address(0xF2)),
            abi.encodePacked(_marketPacked(), address(0xF1), address(0xF2))
        );
    }

    function testFlashLoanPinsCallbackThenTokens() external view {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0x0F1);
        tokens[1] = address(0x0F2);
        uint256[] memory amounts = new uint256[](2);
        assertEq(
            d.flashLoan(tokens, amounts, address(0x0CB), ""),
            abi.encodePacked(address(0x0CB), address(0x0F1), address(0x0F2))
        );
    }

    function testLiquidatePinsMarketBorrowerReceiverCallback() external view {
        bytes memory got = d.liquidate(_market(), 0, 1, 1, address(0xB0), false, address(0xB1), address(0xB2), "");
        assertEq(got, abi.encodePacked(_marketPacked(), address(0xB0), address(0xB1), address(0xB2)));
    }

    function testSetIsAuthorizedPinsAuthorizedAndOnBehalf() external view {
        assertEq(d.setIsAuthorized(address(0xA1), true, address(0xA2)), abi.encodePacked(address(0xA1), address(0xA2)));
    }

    function testSetConsumedPinsOnBehalf() external view {
        assertEq(d.setConsumed(bytes32(uint256(1)), 1, address(0xA9)), abi.encodePacked(address(0xA9)));
    }

    // --- selector self-consistency (guards against struct-layout drift) ---

    function testTakeSelectorMatchesCanonicalSignature() external view {
        // Market tuple = (uint256,address,address,(address,uint256,uint256,address)[],uint256,uint256,address,address)
        // Offer  tuple =
        // (Market,bool,address,uint256,uint256,uint256,bytes32,address,bytes,address,address,bool,uint128,uint128,uint256)
        bytes4 canonical = bytes4(
            keccak256(
                "take(((uint256,address,address,(address,uint256,uint256,address)[],uint256,uint256,address,address),bool,address,uint256,uint256,uint256,bytes32,address,bytes,address,address,bool,uint128,uint128,uint256),bytes,uint256,address,address,address,bytes)"
            )
        );
        assertEq(d.take.selector, canonical, "take selector drifted from source ABI");
    }

    function testWithdrawSelectorMatchesCanonicalSignature() external view {
        bytes4 canonical = bytes4(
            keccak256(
                "withdraw((uint256,address,address,(address,uint256,uint256,address)[],uint256,uint256,address,address),uint256,address,address)"
            )
        );
        assertEq(d.withdraw.selector, canonical, "withdraw selector drifted from source ABI");
    }

    function testFlashLoanSelectorMatchesCanonicalSignature() external view {
        assertEq(d.flashLoan.selector, bytes4(keccak256("flashLoan(address[],uint256[],address,bytes)")));
    }

}
