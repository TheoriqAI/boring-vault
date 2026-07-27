// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { AaveV4DecoderAndSanitizer } from "src/base/DecodersAndSanitizers/Protocols/AaveV4DecoderAndSanitizer.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

interface ISpoke {

    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external;
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);

    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    struct ReserveConfig {
        uint24 collateralRisk;
        bool paused;
        bool frozen;
        bool borrowable;
        bool receiveSharesEnabled;
    }

    struct DynamicReserveConfig {
        uint16 collateralFactor;
        uint32 maxLiquidationBonus;
        uint16 liquidationFee;
    }

    function getReserveCount() external view returns (uint256);
    function getReserve(uint256 reserveId) external view returns (Reserve memory);
    function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory);
    function getDynamicReserveConfig(
        uint256 reserveId,
        uint32 dynamicConfigKey
    )
        external
        view
        returns (DynamicReserveConfig memory);

}

/// @notice Discovery-only pass: enumerate MAIN_SPOKE reserves and print reserveId -> underlying + config,
///         so the integration test uses real reserveIds/configs (never guessed). Gated on MAINNET_RPC_URL.
contract AaveV4DiscoveryTest is Test {

    ISpoke internal constant MAIN_SPOKE = ISpoke(0x94e7A5dCbE816e498b89aB752661904E2F56c485);
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant EURC = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;
    address internal constant USDG = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;

    function test_DiscoverMainSpokeReserves() external {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        try vm.createSelectFork(rpc) returns (uint256) { }
        catch {
            vm.skip(true);
            return;
        }

        uint256 n = MAIN_SPOKE.getReserveCount();
        emit log_named_uint("MAIN_SPOKE reserve count", n);
        for (uint256 id; id < n; ++id) {
            ISpoke.Reserve memory r = MAIN_SPOKE.getReserve(id);
            ISpoke.ReserveConfig memory c = MAIN_SPOKE.getReserveConfig(id);
            ISpoke.DynamicReserveConfig memory dc = MAIN_SPOKE.getDynamicReserveConfig(id, r.dynamicConfigKey);
            string memory tag =
                r.underlying == USDC ? "USDC" : r.underlying == EURC ? "EURC" : r.underlying == USDG ? "USDG" : "-";
            emit log_named_string(
                string.concat("reserve ", vm.toString(id), " ", tag),
                string.concat(
                    "underlying=",
                    vm.toString(r.underlying),
                    " hub=",
                    vm.toString(r.hub),
                    " borrowable=",
                    c.borrowable ? "1" : "0",
                    " paused=",
                    c.paused ? "1" : "0",
                    " frozen=",
                    c.frozen ? "1" : "0",
                    " collateralFactor=",
                    vm.toString(uint256(dc.collateralFactor))
                )
            );
        }
    }

}

contract AaveV4IntHarness is AaveV4DecoderAndSanitizer {

    constructor(address bv) BaseDecoderAndSanitizer(bv) { }

}

/// @notice REAL integration on a mainnet fork: drive a full supply(USDC collateral) -> borrow(EURC, USDG)
///         -> repay -> withdraw cycle against the LIVE Aave V4 MAIN_SPOKE, and cross-check that our decoder
///         sanitizes the exact same calldata to the expected addresses.
/// @dev Run with:  MAINNET_RPC_URL=<node> forge test --match-contract AaveV4IntegrationTest --evm-version cancun
///      Aave V4 uses transient storage (Cancun) — under the repo default `evm_version = shanghai` the Spoke
///      reverts `NotActivated`, so this test detects that and SKIPS (rather than failing) if supply reverts.
///      Also gated on MAINNET_RPC_URL so it skips entirely in RPC-less CI.
contract AaveV4IntegrationTest is Test {

    ISpoke internal constant SPOKE = ISpoke(0x94e7A5dCbE816e498b89aB752661904E2F56c485); // MAIN_SPOKE
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant EURC = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;
    address internal constant USDG = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;

    AaveV4IntHarness internal decoder;
    bool internal forked;

    function setUp() external {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        try vm.createSelectFork(rpc) returns (uint256) {
            forked = true;
        } catch {
            return;
        }
        decoder = new AaveV4IntHarness(address(this));
    }

    function test_SupplyCollateralBorrowRepayWithdraw() external {
        if (!forked) {
            vm.skip(true);
            return;
        }

        uint256 usdcId = _reserveId(USDC);
        uint256 eurcId = _reserveId(EURC);
        uint256 usdgId = _reserveId(USDG);

        // 1) supply USDC and enable it as collateral
        uint256 supplyAmt = 1_000_000e6;
        deal(USDC, address(this), supplyAmt);
        ERC20(USDC).approve(address(SPOKE), supplyAmt);
        // Aave V4 uses transient storage (Cancun); under a pre-Cancun EVM the Spoke reverts NotActivated.
        // Treat a supply revert as an environment mismatch and skip with guidance (see contract @dev).
        try SPOKE.supply(usdcId, supplyAmt, address(this)) returns (uint256, uint256) { }
        catch {
            emit log("Aave v4 supply reverted - re-run with `--evm-version cancun` (transient storage)");
            vm.skip(true);
            return;
        }
        SPOKE.setUsingAsCollateral(usdcId, true, address(this));
        assertGe(SPOKE.getUserSuppliedAssets(usdcId, address(this)), supplyAmt - 1, "USDC not supplied");

        // 2) borrow + repay EURC and USDG against the USDC collateral
        _borrowThenRepay(eurcId, EURC, 1000e6);
        _borrowThenRepay(usdgId, USDG, 1000e6);

        // 3) withdraw half the USDC collateral back
        uint256 usdcBefore = ERC20(USDC).balanceOf(address(this));
        SPOKE.withdraw(usdcId, supplyAmt / 2, address(this));
        assertEq(ERC20(USDC).balanceOf(address(this)) - usdcBefore, supplyAmt / 2, "USDC not withdrawn");

        // 4) decoder cross-check: the SAME calldata a strategist would submit sanitizes to onBehalfOf/user
        _decoderCrossCheck(usdcId, eurcId);
    }

    function _borrowThenRepay(uint256 reserveId, address token, uint256 amount) internal {
        uint256 balBefore = ERC20(token).balanceOf(address(this));
        SPOKE.borrow(reserveId, amount, address(this));
        assertEq(ERC20(token).balanceOf(address(this)) - balBefore, amount, "borrow proceeds mismatch");
        assertGt(SPOKE.getUserTotalDebt(reserveId, address(this)), 0, "no debt after borrow");

        uint256 debt = SPOKE.getUserTotalDebt(reserveId, address(this));
        if (ERC20(token).balanceOf(address(this)) < debt) deal(token, address(this), debt); // cover any premium
        ERC20(token).approve(address(SPOKE), debt);
        SPOKE.repay(reserveId, debt, address(this));
        assertEq(SPOKE.getUserTotalDebt(reserveId, address(this)), 0, "debt not cleared after repay");
    }

    function _decoderCrossCheck(uint256 usdcId, uint256 eurcId) internal view {
        bytes memory me = abi.encodePacked(address(this));
        assertEq(decoder.supply(usdcId, 1e6, address(this)), me, "decoder supply");
        assertEq(decoder.withdraw(usdcId, 1e6, address(this)), me, "decoder withdraw");
        assertEq(decoder.borrow(eurcId, 1e6, address(this)), me, "decoder borrow");
        assertEq(decoder.repay(eurcId, 1e6, address(this)), me, "decoder repay");
        assertEq(decoder.setUsingAsCollateral(usdcId, true, address(this)), me, "decoder setUsingAsCollateral");
    }

    function _reserveId(address asset) internal view returns (uint256) {
        uint256 n = SPOKE.getReserveCount();
        for (uint256 id; id < n; ++id) {
            if (SPOKE.getReserve(id).underlying == asset) return id;
        }
        revert("reserve not found");
    }

}
