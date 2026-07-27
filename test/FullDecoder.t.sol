// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { FullDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/nextgen/FullDecoderAndSanitizer.sol";

/// @notice Smoke test that the next-gen combined decoder dispatches to each merged mixin (no silent
///         selector collision / missing-override). Deep per-protocol behavior is covered by the individual
///         protocol test suites.
contract FullDecoderTest is Test {

    FullDecoderAndSanitizer internal d;

    address internal constant BV = address(0xBEEF);
    address internal constant SPENDER = address(0x11);
    address internal constant RECEIVER = address(0x22);
    address internal constant EVAULT = address(0x33);
    address internal constant TOKEN = address(0x44);

    function setUp() external {
        d = new FullDecoderAndSanitizer(BV, address(0x1)); // vault, uniswapV3 NFPM
    }

    function testDispatchesToEachMixin() external view {
        // Base
        assertEq(d.approve(SPENDER, 1), abi.encodePacked(SPENDER), "approve (Base)");
        // ERC4626/Curve/Balancer resolved deposit override
        assertEq(d.deposit(1, RECEIVER), abi.encodePacked(RECEIVER), "deposit override");
        // Euler (new)
        assertEq(d.enableCollateral(BV, EVAULT), abi.encodePacked(EVAULT), "euler enableCollateral");
        assertEq(d.borrow(1, BV), "", "euler borrow");
        // CowSwap (new)
        assertEq(d.setCowswapApproval(TOKEN, 1), abi.encodePacked(TOKEN), "cowswap approval");
        assertEq(d.pullAssets(TOKEN, 1), abi.encodePacked(TOKEN), "cowswap pull");
        // Aave V4 Spoke (new) — supply(uint256,uint256,address) overloads cleanly beside AaveV3/MorphoBlue
        assertEq(d.supply(7, 100, RECEIVER), abi.encodePacked(RECEIVER), "aave v4 supply");
        assertEq(d.setUserPositionManager(TOKEN, true), abi.encodePacked(TOKEN), "aave v4 positionManager");
        // Morpho Midnight (new)
        assertEq(d.setIsAuthorized(SPENDER, true, RECEIVER), abi.encodePacked(SPENDER, RECEIVER), "midnight auth");
    }

}
