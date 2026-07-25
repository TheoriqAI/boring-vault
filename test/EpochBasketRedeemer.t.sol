// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { DeployAll } from "script/deploy/deployAll.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "@solmate/test/utils/mocks/MockERC20.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { EpochBasketRedeemer } from "src/helper/EpochBasketRedeemer.sol";
import { IRedeemPolicy } from "src/interfaces/IRedeemPolicy.sol";
import { MockRedeemPolicy } from "./BasketRedeemer.t.sol";
import { SOLVER_ROLE } from "src/helper/Constants.sol";

/**
 * @notice End-to-end tests for EpochBasketRedeemer against a Celo fork of the nXAUT deployment.
 *   LIVE_DEPLOY_READ_FILE_NAME=test-1-xaut-L2.json OVERRIDE_PROTOCOL_ADMIN=0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631 \
 *     forge test --mp test/EpochBasketRedeemer.t.sol --fork-url https://forno.celo.org -vv
 * Base XAUt0 is the deposit token; the basket pays three pegged 6-decimal mocks (rate == 1e6 so
 * assetsOut == shares and every assertion is exact).
 */
abstract contract ForkStart is Test {

    constructor() {
        if (bytes(vm.envOr("LIVE_DEPLOY_READ_FILE_NAME", string(""))).length > 0) {
            if (block.chainid == 31_337) vm.selectFork(vm.createFork(vm.envString("L2_RPC_URL")));
        } else {
            // Not running the live integration test: stub CreateX so the DeployAll base constructor's
            // presence check passes; setUp() then skips before CreateX is ever used.
            vm.etch(vm.envOr("CREATEX", 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed), hex"00");
        }
    }

}

contract EpochBasketRedeemerTest is ForkStart, DeployAll {

    EpochBasketRedeemer redeemer;
    BoringVault vault;
    TellerWithMultiAssetSupport teller;
    RolesAuthority rolesAuthority;
    ERC20 base;

    MockERC20 usdc; // 30%
    MockERC20 mmf; //  40%
    MockERC20 bond; // 30%

    address admin;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant CAP = 3000e6;
    uint64 constant DURATION = 1 days;

    function setUp() public {
        if (bytes(vm.envOr("LIVE_DEPLOY_READ_FILE_NAME", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        runLiveTest(vm.envString("LIVE_DEPLOY_READ_FILE_NAME"));
        vault = BoringVault(payable(mainConfig.boringVault));
        teller = TellerWithMultiAssetSupport(mainConfig.teller);
        rolesAuthority = RolesAuthority(mainConfig.rolesAuthority);
        base = ERC20(mainConfig.base);
        admin = mainConfig.protocolAdmin;

        usdc = new MockERC20("USD Coin", "USDC", 6);
        mmf = new MockERC20("Money Market Fund", "MMF", 6);
        bond = new MockERC20("Illiquid Bond", "BOND", 6);

        vm.startPrank(admin);
        _peg(usdc);
        _peg(mmf);
        _peg(bond);

        redeemer = new EpochBasketRedeemer(admin, teller);
        rolesAuthority.setUserRole(address(redeemer), SOLVER_ROLE, true);

        EpochBasketRedeemer.BasketLeg[] memory legs = new EpochBasketRedeemer.BasketLeg[](3);
        legs[0] = EpochBasketRedeemer.BasketLeg({ asset: ERC20(address(usdc)), weightBps: 3000 });
        legs[1] = EpochBasketRedeemer.BasketLeg({ asset: ERC20(address(mmf)), weightBps: 4000 });
        legs[2] = EpochBasketRedeemer.BasketLeg({ asset: ERC20(address(bond)), weightBps: 3000 });
        redeemer.setBasket(legs);
        redeemer.setMaxSharesPerEpoch(CAP);
        redeemer.setEpochDuration(DURATION);
        redeemer.setMinRequestShares(1e6);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- undersubscribed => full fill

    function test_undersubscribed_fullFill() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);

        _request(alice, 1000e6);
        _request(bob, 1000e6); // total 2000e6 <= CAP 3000e6

        _closeAfterDuration();

        (,, bool settled,, uint256 filled) = redeemer.epochInfo(1);
        assertTrue(settled);
        assertEq(filled, 2000e6, "under cap => 100% filled");

        vm.prank(alice);
        redeemer.claim(1);
        // alice = half of pooled (600/800/600 pooled at 2000e6 fill)
        assertEq(usdc.balanceOf(alice), 300e6);
        assertEq(mmf.balanceOf(alice), 400e6);
        assertEq(bond.balanceOf(alice), 300e6);
        assertEq(vault.balanceOf(alice), 0, "no shares returned when fully filled");
    }

    // ---------------------------------------------------------------- oversubscribed => pro-rata

    function test_oversubscribed_prorata() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);

        _request(alice, 2000e6);
        _request(bob, 2000e6); // total 4000e6 > CAP 3000e6 => filled 3000e6

        _closeAfterDuration();

        (,,,, uint256 filled) = redeemer.epochInfo(1);
        assertEq(filled, 3000e6, "capped fill");

        // alice holds 2000/4000 of the epoch => half the 3000e6 pool (900/1200/900)
        vm.prank(alice);
        redeemer.claim(1);
        assertEq(usdc.balanceOf(alice), 450e6);
        assertEq(mmf.balanceOf(alice), 600e6);
        assertEq(bond.balanceOf(alice), 450e6);
        // unfilled shares returned: 2000e6 * (4000e6-3000e6)/4000e6 = 500e6
        assertEq(vault.balanceOf(alice), 500e6, "pro-rata unfilled shares returned");

        vm.prank(bob);
        redeemer.claim(1);
        assertEq(usdc.balanceOf(bob), 450e6);
        assertEq(vault.balanceOf(bob), 500e6);
    }

    // ---------------------------------------------------------------- coverage-limited fill

    function test_coverageLimited_scalesEveryoneDown() public {
        vm.prank(admin);
        redeemer.setMaxSharesPerEpoch(0); // uncapped so only coverage limits

        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 450e6); // bond leg wants 900e6 for a 3000e6 fill => covBps = 5000

        _request(alice, 3000e6);
        _closeAfterDuration();

        (,,,, uint256 filled) = redeemer.epochInfo(1);
        assertEq(filled, 1500e6, "scaled to 50% by bond coverage");

        vm.prank(alice);
        redeemer.claim(1);
        assertEq(usdc.balanceOf(alice), 450e6); // 1500e6 * 30%
        assertEq(mmf.balanceOf(alice), 600e6); //  1500e6 * 40%
        assertEq(bond.balanceOf(alice), 450e6); // 1500e6 * 30% == all the bond there was
        assertEq(vault.balanceOf(alice), 1500e6, "unfilled half returned as shares");
    }

    // ---------------------------------------------------------------- lifecycle guards

    function test_cancelRequest_returnsShares() public {
        _request(alice, 1000e6);
        vm.prank(alice);
        redeemer.cancelRequest(400e6);
        assertEq(vault.balanceOf(alice), 400e6, "cancelled shares back");
        (, uint256 total,,,) = redeemer.epochInfo(1);
        assertEq(total, 600e6, "totalRequested decremented");
    }

    function test_emptyEpoch_advances() public {
        _closeAfterDuration();
        assertEq(redeemer.currentEpoch(), 2, "empty epoch still advances");
    }

    function test_request_reverts_afterElapsed() public {
        uint256 shares = _mintShares(alice, 1000e6);
        vm.warp(block.timestamp + DURATION);
        vm.startPrank(alice);
        vault.approve(address(redeemer), shares);
        vm.expectRevert(EpochBasketRedeemer.EpochNeedsClose.selector);
        redeemer.request(shares);
        vm.stopPrank();
    }

    function test_claim_guards() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
        _request(alice, 1000e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EpochBasketRedeemer.EpochNotSettled.selector, uint256(1)));
        redeemer.claim(1);

        _closeAfterDuration();
        vm.prank(alice);
        redeemer.claim(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EpochBasketRedeemer.AlreadyClaimed.selector, uint256(1)));
        redeemer.claim(1);
    }

    function test_settle_usesSnapshot_notDriftedBasket() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
        _request(alice, 1000e6); // snapshots the 3-asset basket into epoch 1

        // admin drifts the live basket to a single asset; epoch 1 must be unaffected
        vm.startPrank(admin);
        EpochBasketRedeemer.BasketLeg[] memory legsB = new EpochBasketRedeemer.BasketLeg[](1);
        legsB[0] = EpochBasketRedeemer.BasketLeg({ asset: ERC20(address(usdc)), weightBps: 10_000 });
        redeemer.setBasket(legsB);
        vm.stopPrank();

        _closeAfterDuration();
        vm.prank(alice);
        redeemer.claim(1);
        assertEq(usdc.balanceOf(alice), 300e6, "settled against snapshot A");
        assertEq(mmf.balanceOf(alice), 400e6);
        assertEq(bond.balanceOf(alice), 300e6);
    }

    function test_policy_gates_request() public {
        bytes memory good = hex"c0ffee";
        MockRedeemPolicy pol = new MockRedeemPolicy(good);
        vm.prank(admin);
        redeemer.setPolicy(IRedeemPolicy(address(pol)));

        uint256 shares = _mintShares(alice, 1000e6);
        vm.startPrank(alice);
        vault.approve(address(redeemer), shares);
        vm.expectRevert(MockRedeemPolicy.PolicyDenied.selector);
        redeemer.request(shares); // empty authData => denied
        redeemer.request(shares, good); // authorized
        vm.stopPrank();
        (, uint256 total,,,) = redeemer.epochInfo(1);
        assertEq(total, shares);
    }

    // ---------------------------------------------------------------- audit-fix behaviors

    /// Fix 1: claim re-checks the policy at asset-exit, so a post-request denylist blocks the slice.
    function test_policy_gates_claim() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);

        bytes memory good = hex"c0ffee";
        MockRedeemPolicy pol = new MockRedeemPolicy(good);
        vm.prank(admin);
        redeemer.setPolicy(IRedeemPolicy(address(pol)));

        uint256 shares = _mintShares(alice, 1000e6);
        vm.startPrank(alice);
        vault.approve(address(redeemer), shares);
        redeemer.request(shares, good); // authorized request
        vm.stopPrank();

        _closeAfterDuration();

        vm.startPrank(alice);
        vm.expectRevert(MockRedeemPolicy.PolicyDenied.selector);
        redeemer.claim(1); // empty authData => denied at claim
        redeemer.claim(1, good); // fresh auth => assets released
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 300e6);
    }

    /// Fix 3: a zero-liquidity leg settles the epoch as a 0-fill full refund instead of reverting.
    function test_uncoverableLeg_settlesAsFullRefund() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        // bond intentionally unfunded (bal == 0) => covBps 0 => 0-fill refund

        _request(alice, 3000e6);
        _closeAfterDuration(); // must NOT revert

        (,,,, uint256 filled) = redeemer.epochInfo(1);
        assertEq(filled, 0, "0-fill on uncoverable leg");

        vm.prank(alice);
        redeemer.claim(1);
        assertEq(usdc.balanceOf(alice), 0, "no assets");
        assertEq(vault.balanceOf(alice), 3000e6, "full shares refunded");
        assertEq(redeemer.currentEpoch(), 2, "epoch still advanced (un-bricked)");
    }

    /// Fix 3: a de-listed leg also degrades to full refund rather than wedging settlement.
    function test_delistedLeg_settlesAsFullRefund() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
        _request(alice, 3000e6);

        vm.prank(admin);
        teller.removeWithdrawAsset(ERC20(address(bond))); // de-list a basket leg after request

        _closeAfterDuration(); // must NOT revert
        (,,,, uint256 filled) = redeemer.epochInfo(1);
        assertEq(filled, 0, "de-listed leg => 0-fill refund");
        vm.prank(alice);
        redeemer.claim(1);
        assertEq(vault.balanceOf(alice), 3000e6, "shares refunded");
    }

    // ---------------------------------------------------------------- interval-fund safety fixes

    /// requestCutoffBuffer locks the book ahead of pricing: no new requests, no cancels (irrevocable).
    function test_requestCutoff_locksBook() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);

        vm.prank(admin);
        redeemer.setRequestCutoffBuffer(1 hours); // book locks 1h before close

        _request(alice, 1000e6); // before cutoff => ok

        vm.warp(block.timestamp + DURATION - 30 minutes); // past cutoff, before close

        uint256 bobShares = _mintShares(bob, 1000e6);
        vm.startPrank(bob);
        vault.approve(address(redeemer), bobShares);
        vm.expectRevert(EpochBasketRedeemer.RequestsClosed.selector);
        redeemer.request(bobShares); // no new requests after cutoff
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(EpochBasketRedeemer.RequestsLocked.selector);
        redeemer.cancelRequest(500e6); // irrevocable after cutoff (kills the look-back option)

        // still settles + claims normally
        vm.warp(block.timestamp + 30 minutes + 1);
        redeemer.closeEpoch();
        vm.prank(alice);
        redeemer.claim(1);
        assertEq(usdc.balanceOf(alice), 300e6);
    }

    /// A NAV staler than maxNavAge at close => 0-fill full refund (never price on a stale mark).
    function test_staleNav_settlesAsFullRefund() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);

        vm.prank(admin);
        redeemer.setMaxNavAge(1 hours); // NAV must be < 1h old to price

        _request(alice, 3000e6);
        _closeAfterDuration(); // NAV last marked ~1 day ago => stale => refund

        (,,,, uint256 filled) = redeemer.epochInfo(1);
        assertEq(filled, 0, "stale NAV => 0-fill");
        vm.prank(alice);
        redeemer.claim(1);
        assertEq(vault.balanceOf(alice), 3000e6, "full refund on stale NAV");
        assertEq(usdc.balanceOf(alice), 0);
    }

    /// A fresh NAV (within maxNavAge) prices normally.
    function test_freshNav_fills() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);

        vm.prank(admin);
        redeemer.setMaxNavAge(2 days); // > epoch duration, so still fresh at close

        _request(alice, 3000e6);
        _closeAfterDuration();

        (,,,, uint256 filled) = redeemer.epochInfo(1);
        assertEq(filled, 3000e6, "fresh NAV prices normally");
        vm.prank(alice);
        redeemer.claim(1);
        assertEq(usdc.balanceOf(alice), 900e6);
    }

    // ---------------------------------------------------------------- helpers

    function _peg(MockERC20 a) internal {
        teller.addWithdrawAsset(ERC20(address(a)));
        teller.accountant().setRateProviderData(ERC20(address(a)), true, address(0));
    }

    function _mintShares(address to, uint256 baseAmount) internal returns (uint256 shares) {
        deal(address(base), to, baseAmount);
        vm.startPrank(to);
        base.approve(address(vault), baseAmount);
        shares = teller.deposit(base, baseAmount, 0);
        vm.stopPrank();
    }

    function _request(address who, uint256 baseAmount) internal returns (uint256 shares) {
        shares = _mintShares(who, baseAmount);
        vm.startPrank(who);
        vault.approve(address(redeemer), shares);
        redeemer.request(shares);
        vm.stopPrank();
    }

    function _fundVault(MockERC20 a, uint256 amount) internal {
        a.mint(address(vault), amount);
    }

    function _closeAfterDuration() internal {
        vm.warp(block.timestamp + DURATION + 1);
        redeemer.closeEpoch();
    }

}
