// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { PendleRouterDecoderAndSanitizer } from
    "src/base/DecodersAndSanitizers/Protocols/PendleRouterDecoderAndSanitizer.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { DecoderCustomTypes } from "src/interfaces/DecoderCustomTypes.sol";

contract PendleHarness is PendleRouterDecoderAndSanitizer {

    constructor(address bv) BaseDecoderAndSanitizer(bv) { }

}

/// @notice Verifies the Pendle decoder now SANITIZES on-chain limit orders (previously it reverted).
contract PendleLimitOrderTest is Test {

    PendleHarness internal d;

    address internal constant RECEIVER = address(0xBEEF);
    address internal constant MARKET = address(0x11);
    address internal constant TOKEN = address(0x22);
    address internal constant LIMIT_ROUTER = address(0x999);
    // fill 1
    address internal constant T1 = address(0xA1);
    address internal constant Y1 = address(0xA2);
    address internal constant M1 = address(0xA3);
    address internal constant R1 = address(0xA4);
    // fill 2
    address internal constant T2 = address(0xB1);
    address internal constant Y2 = address(0xB2);
    address internal constant M2 = address(0xB3);
    address internal constant R2 = address(0xB4);

    function setUp() external {
        d = new PendleHarness(address(0xCAFE));
    }

    function _output() internal pure returns (DecoderCustomTypes.TokenOutput memory o) {
        o.tokenOut = TOKEN;
        o.tokenRedeemSy = TOKEN; // == tokenOut so the aggregator-swap guard passes
    }

    function _order(
        address t,
        address y,
        address m,
        address r
    )
        internal
        pure
        returns (DecoderCustomTypes.Order memory o)
    {
        o.token = t;
        o.YT = y;
        o.maker = m;
        o.receiver = r;
    }

    function testLimitOrderAddressesSanitized() external view {
        DecoderCustomTypes.LimitOrderData memory limit;
        limit.limitRouter = LIMIT_ROUTER;
        limit.normalFills = new DecoderCustomTypes.FillOrderParams[](1);
        limit.normalFills[0].order = _order(T1, Y1, M1, R1);
        limit.flashFills = new DecoderCustomTypes.FillOrderParams[](1);
        limit.flashFills[0].order = _order(T2, Y2, M2, R2);

        bytes memory packed = d.swapExactPtForToken(RECEIVER, MARKET, 0, _output(), limit);

        // receiver, market, tokenOut, then limitRouter + each fill's token/YT/maker/receiver (normal, then flash)
        assertEq(
            packed,
            abi.encodePacked(RECEIVER, MARKET, TOKEN, LIMIT_ROUTER, T1, Y1, M1, R1, T2, Y2, M2, R2),
            "limit-order addresses not packed as expected"
        );
    }

    function testNoLimitOrderLeafUnchanged() external view {
        DecoderCustomTypes.LimitOrderData memory limit; // limitRouter == address(0)
        bytes memory packed = d.swapExactPtForToken(RECEIVER, MARKET, 0, _output(), limit);
        // no limit order => no extra addresses appended (plain-swap leaf is unchanged)
        assertEq(packed, abi.encodePacked(RECEIVER, MARKET, TOKEN), "plain-swap leaf changed");
    }

    function testSwapExactTokenForPtSanitizesLimit() external view {
        DecoderCustomTypes.LimitOrderData memory limit;
        limit.limitRouter = LIMIT_ROUTER;
        limit.normalFills = new DecoderCustomTypes.FillOrderParams[](1);
        limit.normalFills[0].order = _order(T1, Y1, M1, R1);

        DecoderCustomTypes.TokenInput memory input;
        input.tokenIn = TOKEN;
        input.tokenMintSy = TOKEN; // == tokenIn so the aggregator-swap guard passes
        DecoderCustomTypes.ApproxParams memory guess;

        bytes memory packed = d.swapExactTokenForPt(RECEIVER, MARKET, 0, guess, input, limit);
        assertEq(packed, abi.encodePacked(RECEIVER, MARKET, TOKEN, LIMIT_ROUTER, T1, Y1, M1, R1));
    }

}
