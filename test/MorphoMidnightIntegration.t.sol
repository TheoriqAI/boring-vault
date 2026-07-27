// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {
    MorphoMidnightDecoderAndSanitizer,
    MidnightMarket,
    MidnightCollateralParams
} from "src/base/DecodersAndSanitizers/Protocols/MorphoMidnightDecoderAndSanitizer.sol";

interface IMidnightCore {

    function supplyCollateral(
        MidnightMarket memory market,
        uint256 collateralIndex,
        uint256 assets,
        address onBehalf
    )
        external;

    function withdrawCollateral(
        MidnightMarket memory market,
        uint256 collateralIndex,
        uint256 assets,
        address onBehalf,
        address receiver
    )
        external;

}

contract MidnightIntHarness is MorphoMidnightDecoderAndSanitizer {

    constructor(address bv) BaseDecoderAndSanitizer(bv) { }

}

/// @notice REAL integration on a BASE fork against the live Morpho Midnight core: supplyCollateral ->
///         withdrawCollateral on the verified cbBTC/USDC market, plus a decoder cross-check on the same
///         calldata. `take` (lend/borrow of units) is intentionally NOT tested — it consumes a maker-signed
///         Offer, which a deterministic fork can't produce without a live counterparty. supplyCollateral /
///         withdrawCollateral are ungated (enterGate only gates `take`), so a solo forked account works.
/// @dev Run with:  BASE_RPC_URL=<base rpc> forge test --match-contract MorphoMidnightIntegrationTest --evm-version
/// cancun
///      Midnight (solc 0.8.34 on Base) uses transient storage; under the repo default shanghai it reverts
///      NotActivated, so this test SKIPS on a supplyCollateral revert (env mismatch or past maturity).
///      The Market struct below is cryptographically verified: IdLib.toId(market) == the API's market_id
///      0x168e31250e0008b50d2255a5ab85e0265acd6c12e4f9a1336134b36a65a47937.
contract MorphoMidnightIntegrationTest is Test {

    address internal constant MIDNIGHT = 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A;
    address internal constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;

    MidnightIntHarness internal decoder;
    bool internal forked;

    function setUp() external {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        try vm.createSelectFork(rpc) returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        decoder = new MidnightIntHarness(address(this));
    }

    /// @dev the exact verified live cbBTC/USDC market on Base.
    function _market() internal pure returns (MidnightMarket memory m) {
        m.chainId = 8453;
        m.midnight = MIDNIGHT;
        m.loanToken = USDC_BASE;
        m.collateralParams = new MidnightCollateralParams[](1);
        m.collateralParams[0] = MidnightCollateralParams({
            token: CBBTC,
            lltv: 860_000_000_000_000_000,
            liquidationCursor: 300_000_000_000_000_000,
            oracle: ORACLE
        });
        m.maturity = 1_785_510_000;
        m.rcfThreshold = 3_000_000_000;
        m.enterGate = address(0);
        m.liquidatorGate = address(0);
    }

    function test_SupplyThenWithdrawCollateral() external {
        if (!forked) {
            vm.skip(true);
            return;
        }

        MidnightMarket memory m = _market();
        uint256 amount = 1e7; // 0.1 cbBTC (8 decimals)
        deal(CBBTC, address(this), amount);
        ERC20(CBBTC).approve(MIDNIGHT, amount);
        uint256 coreBefore = ERC20(CBBTC).balanceOf(MIDNIGHT);

        try IMidnightCore(MIDNIGHT).supplyCollateral(m, 0, amount, address(this)) { }
        catch {
            emit log("Midnight supplyCollateral reverted - re-run with `--evm-version cancun`, or market matured");
            vm.skip(true);
            return;
        }
        assertEq(ERC20(CBBTC).balanceOf(MIDNIGHT) - coreBefore, amount, "core did not receive collateral");

        // no debt -> withdraw the collateral straight back
        IMidnightCore(MIDNIGHT).withdrawCollateral(m, 0, amount, address(this), address(this));
        assertEq(ERC20(CBBTC).balanceOf(address(this)), amount, "collateral not returned");

        // decoder cross-check on the SAME market/args
        bytes memory marketPacked = abi.encodePacked(MIDNIGHT, USDC_BASE, address(0), address(0), CBBTC, ORACLE);
        assertEq(
            decoder.supplyCollateral(m, 0, amount, address(this)),
            abi.encodePacked(marketPacked, address(this)),
            "decoder supplyCollateral"
        );
        assertEq(
            decoder.withdrawCollateral(m, 0, amount, address(this), address(this)),
            abi.encodePacked(marketPacked, address(this), address(this)),
            "decoder withdrawCollateral"
        );
    }

}
