// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import {
    EulerDecoderAndSanitizer, BatchItem
} from "src/base/DecodersAndSanitizers/Protocols/EulerDecoderAndSanitizer.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract EulerHarness is EulerDecoderAndSanitizer {

    constructor(address bv) BaseDecoderAndSanitizer(bv) { }

}

contract EulerDecoderTest is Test {

    EulerHarness internal d;

    address internal constant BV = address(0xBEEF);
    address internal constant VAULT = address(0x11); // an eVault
    address internal constant EVC = address(0xE);
    address internal constant NOT_BV = address(0xDEAD);

    bytes4 internal ONLY = EulerDecoderAndSanitizer.EulerDecoderAndSanitizer__BoringVaultOnly.selector;
    bytes4 internal BADSEL = EulerDecoderAndSanitizer.EulerDecoderAndSanitizer__InvalidSelector.selector;

    function setUp() external {
        d = new EulerHarness(BV);
    }

    // --- direct EVC ---------------------------------------------------------

    function testEvcCollateralAndControllerPinVault() external view {
        assertEq(d.enableCollateral(BV, VAULT), abi.encodePacked(VAULT));
        assertEq(d.disableCollateral(BV, VAULT), abi.encodePacked(VAULT));
        assertEq(d.enableController(BV, VAULT), abi.encodePacked(VAULT));
    }

    function testEvcRejectsNonVaultAccount() external {
        vm.expectRevert(ONLY);
        d.enableCollateral(NOT_BV, VAULT);
    }

    function testDisableControllerEvcRequiresVault() external {
        assertEq(d.disableController(BV), "");
        vm.expectRevert(ONLY);
        d.disableController(NOT_BV);
    }

    // --- direct eVault ------------------------------------------------------

    function testBorrowRepayRequireVaultReceiver() external {
        assertEq(d.borrow(100, BV), "");
        assertEq(d.repay(100, BV), "");
        assertEq(d.repayWithShares(100, BV), "");
        vm.expectRevert(ONLY);
        d.borrow(100, NOT_BV);
    }

    function testPullDebtPinsFrom() external view {
        assertEq(d.pullDebt(100, address(0xF00D)), abi.encodePacked(address(0xF00D)));
    }

    function testDisableControllerVaultNoArgs() external view {
        assertEq(d.disableController(), "");
    }

    // --- batch --------------------------------------------------------------

    function testBatchMultiItemSanitizesEach() external view {
        BatchItem[] memory items = new BatchItem[](2);
        items[0] = BatchItem(EVC, BV, 0, abi.encodeWithSignature("enableController(address,address)", BV, VAULT));
        items[1] = BatchItem(VAULT, BV, 0, abi.encodeWithSignature("borrow(uint256,address)", uint256(100), BV));

        bytes memory packed = d.batch(items);
        // per item: targetContract ++ value ++ inner-addresses
        assertEq(packed, abi.encodePacked(EVC, uint256(0), VAULT, VAULT, uint256(0)));
    }

    function testBatchWithdrawRequiresVaultReceiverAndOwner() external {
        BatchItem[] memory items = new BatchItem[](1);
        items[0] =
            BatchItem(VAULT, BV, 0, abi.encodeWithSignature("withdraw(uint256,address,address)", uint256(100), BV, BV));
        assertEq(d.batch(items), abi.encodePacked(VAULT, uint256(0))); // withdraw packs nothing

        items[0].data = abi.encodeWithSignature("withdraw(uint256,address,address)", uint256(100), BV, NOT_BV);
        vm.expectRevert(ONLY);
        d.batch(items);
    }

    function testBatchRejectsNonVaultOnBehalf() external {
        BatchItem[] memory items = new BatchItem[](1);
        items[0] = BatchItem(VAULT, NOT_BV, 0, abi.encodeWithSignature("borrow(uint256,address)", uint256(1), BV));
        vm.expectRevert(ONLY);
        d.batch(items);
    }

    function testBatchRejectsUnknownSelector() external {
        BatchItem[] memory items = new BatchItem[](1);
        items[0] = BatchItem(VAULT, BV, 0, abi.encodeWithSignature("frobnicate(uint256)", uint256(1)));
        vm.expectRevert(BADSEL);
        d.batch(items);
    }

    function testBatchPullDebtPinsFrom() external view {
        BatchItem[] memory items = new BatchItem[](1);
        items[0] =
            BatchItem(VAULT, BV, 0, abi.encodeWithSignature("pullDebt(uint256,address)", uint256(5), address(0xF00D)));
        assertEq(d.batch(items), abi.encodePacked(VAULT, uint256(0), address(0xF00D)));
    }

}
