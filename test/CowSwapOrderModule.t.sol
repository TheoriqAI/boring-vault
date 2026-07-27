// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { CowSwapOrderModule } from "src/helper/CowSwapOrderModule.sol";
import { CowSwapDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/CowSwapDecoderAndSanitizer.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { GPv2Order, CowSwapLimitParams } from "src/interfaces/IGPv2.sol";

contract MockToken is ERC20 {

    constructor(string memory n) ERC20(n, n, 18) { }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

}

contract MockSettlement {

    bytes32 public domainSeparator = keccak256("MOCK_DOMAIN_SEPARATOR");
    mapping(bytes32 => bool) public presigned;

    function setPreSignature(bytes calldata uid, bool signed) external {
        presigned[keccak256(uid)] = signed;
    }

    function invalidateOrder(bytes calldata) external { }

}

contract CowSwapDecoderHarness is CowSwapDecoderAndSanitizer {

    constructor(address bv) BaseDecoderAndSanitizer(bv) { }

}

contract CowSwapOrderModuleTest is Test {

    CowSwapOrderModule internal module;
    MockSettlement internal settlement;
    MockToken internal tokenIn;
    MockToken internal tokenOut;
    CowSwapDecoderHarness internal decoder;

    address internal constant RELAYER = address(0xC92E);
    uint256 internal constant AMOUNT_IN = 1000e18;
    uint256 internal constant MIN_OUT = 990e18;
    uint32 internal DEADLINE;

    function setUp() external {
        settlement = new MockSettlement();
        tokenIn = new MockToken("IN");
        tokenOut = new MockToken("OUT");
        // this test contract is both the module owner AND the "vault" (the sole authorized caller)
        module = new CowSwapOrderModule(address(this), address(this), address(settlement), RELAYER);
        module.setAllowedToken(address(tokenIn), true);
        module.setAllowedToken(address(tokenOut), true);
        tokenIn.mint(address(module), AMOUNT_IN); // vault pushed the sell token in
        DEADLINE = uint32(block.timestamp + 1 hours);

        decoder = new CowSwapDecoderHarness(address(0xBEEF));
    }

    function _order() internal view returns (GPv2Order.Data memory o) {
        o.sellToken = address(tokenIn);
        o.buyToken = address(tokenOut);
        o.receiver = address(module);
        o.sellAmount = AMOUNT_IN;
        o.buyAmount = MIN_OUT;
        o.validTo = DEADLINE;
        o.appData = keccak256("app");
        o.kind = GPv2Order.KIND_SELL;
        o.sellTokenBalance = GPv2Order.BALANCE_ERC20;
        o.buyTokenBalance = GPv2Order.BALANCE_ERC20;
    }

    function _params() internal view returns (CowSwapLimitParams memory) {
        return CowSwapLimitParams(address(tokenIn), address(tokenOut), AMOUNT_IN, MIN_OUT, DEADLINE);
    }

    function _uid(GPv2Order.Data memory o) internal view returns (bytes memory) {
        return GPv2Order.packOrderUid(GPv2Order.hash(o, module.domainSeparator()), address(module), o.validTo);
    }

    function _mismatch(string memory field) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CowSwapOrderModule.CowSwapOrderModule__OrderMismatch.selector, field);
    }

    // --- happy path ---------------------------------------------------------

    function testCreateLimitOrderPresigns() external {
        GPv2Order.Data memory o = _order();
        bytes memory uid = _uid(o);
        module.createLimitOrder(_params(), o, uid);
        assertTrue(settlement.presigned(keccak256(uid)), "order not pre-signed");
        // relayer approved for EXACTLY the sell amount (not a standing max)
        assertEq(tokenIn.allowance(address(module), RELAYER), AMOUNT_IN, "relayer approval != sellAmount");
    }

    function testRejectsNonZeroFee() external {
        GPv2Order.Data memory o = _order();
        o.feeAmount = 1; // pre-signed limit orders must be fee-free
        bytes memory uid = _uid(o);
        vm.expectRevert(_mismatch("feeAmount"));
        module.createLimitOrder(_params(), o, uid);
    }

    // --- integrity checks ---------------------------------------------------

    function testRejectsTamperedUid() external {
        GPv2Order.Data memory o = _order();
        bytes memory uid = _uid(o);
        uid[0] = bytes1(uint8(uid[0]) ^ 0xff); // tamper one byte
        vm.expectRevert(_mismatch("orderUid"));
        module.createLimitOrder(_params(), o, uid);
    }

    function testRejectsWrongReceiver() external {
        GPv2Order.Data memory o = _order();
        o.receiver = address(0xBAD);
        bytes memory uid = _uid(o); // precompute (domainSeparator() external call) before expectRevert
        vm.expectRevert(_mismatch("receiver"));
        module.createLimitOrder(_params(), o, uid);
    }

    function testRejectsAmountMismatch() external {
        GPv2Order.Data memory o = _order();
        o.sellAmount = AMOUNT_IN + 1; // disagrees with params.amountIn
        bytes memory uid = _uid(o);
        vm.expectRevert(_mismatch("sellAmount"));
        module.createLimitOrder(_params(), o, uid);
    }

    function testRejectsBuyOrder() external {
        GPv2Order.Data memory o = _order();
        o.kind = keccak256("buy"); // not KIND_SELL
        bytes memory uid = _uid(o);
        vm.expectRevert(_mismatch("kind"));
        module.createLimitOrder(_params(), o, uid);
    }

    // --- access / config ----------------------------------------------------

    function testOnlyVaultCanCreate() external {
        GPv2Order.Data memory o = _order();
        bytes memory uid = _uid(o);
        vm.prank(address(0xBEEF));
        vm.expectRevert(CowSwapOrderModule.CowSwapOrderModule__OnlyVault.selector);
        module.createLimitOrder(_params(), o, uid);
    }

    function testRejectsNonAllowlistedToken() external {
        MockToken other = new MockToken("OTHER");
        tokenIn.mint(address(module), AMOUNT_IN);
        CowSwapLimitParams memory p = CowSwapLimitParams(address(tokenIn), address(other), AMOUNT_IN, MIN_OUT, DEADLINE);
        GPv2Order.Data memory o = _order();
        o.buyToken = address(other);
        bytes memory uid = _uid(o);
        vm.expectRevert(CowSwapOrderModule.CowSwapOrderModule__TokenNotAllowed.selector);
        module.createLimitOrder(p, o, uid);
    }

    function testPullAssetsReturnsToVault() external {
        tokenOut.mint(address(module), 500e18); // simulate filled proceeds
        module.pullAssets(address(tokenOut), 500e18);
        assertEq(tokenOut.balanceOf(address(this)), 500e18); // vault == this
    }

    // --- decoder ------------------------------------------------------------

    function testDecoderPinsTokens() external view {
        GPv2Order.Data memory o = _order();
        bytes memory packed = decoder.createLimitOrder(_params(), o, _uid(o));
        assertEq(packed, abi.encodePacked(address(tokenIn), address(tokenOut)));
    }

    function testDecoderApprovalAndPullPinToken() external view {
        assertEq(decoder.setCowswapApproval(address(tokenIn), 1), abi.encodePacked(address(tokenIn)));
        assertEq(decoder.pullAssets(address(tokenOut), 1), abi.encodePacked(address(tokenOut)));
        assertEq(decoder.invalidateOrder(hex"1234"), "");
    }

}
