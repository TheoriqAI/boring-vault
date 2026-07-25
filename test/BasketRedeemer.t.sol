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
import { BasketRedeemer } from "src/helper/BasketRedeemer.sol";
import { IRedeemPolicy } from "src/interfaces/IRedeemPolicy.sol";
import { SOLVER_ROLE } from "src/helper/Constants.sol";

/// @dev Minimal policy stub: records the last call and denies unless `expectedAuth` is presented.
/// Stands in for a Predicate/EIP-712 policy so the seam can be tested without a live registry.
contract MockRedeemPolicy is IRedeemPolicy {

    bytes public expectedAuth;
    address public lastCaller;
    address public lastReceiver;
    uint256 public lastShares;
    bytes public lastAuthData;

    error PolicyDenied();

    constructor(bytes memory _expectedAuth) {
        expectedAuth = _expectedAuth;
    }

    function authorizeRedeem(address caller, address receiver, uint256 shares, bytes calldata authData) external {
        lastCaller = caller;
        lastReceiver = receiver;
        lastShares = shares;
        lastAuthData = authData;
        if (keccak256(authData) != keccak256(expectedAuth)) revert PolicyDenied();
    }

}

/**
 * @notice End-to-end tests for BasketRedeemer against a Celo fork of the nXAUT deployment.
 *   LIVE_DEPLOY_READ_FILE_NAME=xaut-L2.json forge test --mp test/BasketRedeemer.t.sol \
 *     --fork-url https://forno.celo.org -vv
 * Base asset XAUt0 is the deposit token; the basket pays out three pegged 6-decimal mock assets so
 * every leg prices 1:1 (rate == 1e6) and assertions are exact (assetsOut == shares).
 */
abstract contract ForkStart is Test {

    constructor() {
        if (block.chainid == 31_337) {
            vm.selectFork(vm.createFork(vm.envString("L2_RPC_URL")));
        }
    }

}

contract BasketRedeemerTest is ForkStart, DeployAll {

    BasketRedeemer redeemer;
    BoringVault vault;
    TellerWithMultiAssetSupport teller;
    AccountantWithRateProviders accountant;
    RolesAuthority rolesAuthority;
    ERC20 base; // XAUt0

    MockERC20 usdc; // leg 0, 30%
    MockERC20 mmf; //  leg 1, 40%
    MockERC20 bond; // leg 2, 30% (the "illiquid" one)

    address admin;
    address user = makeAddr("redeemer user");

    uint16 constant W0 = 3000;
    uint16 constant W1 = 4000;
    uint16 constant W2 = 3000;
    uint64 constant EXPIRY = 3 days;

    function setUp() public {
        runLiveTest(vm.envString("LIVE_DEPLOY_READ_FILE_NAME"));

        vault = BoringVault(payable(mainConfig.boringVault));
        teller = TellerWithMultiAssetSupport(mainConfig.teller);
        accountant = AccountantWithRateProviders(mainConfig.accountant);
        rolesAuthority = RolesAuthority(mainConfig.rolesAuthority);
        base = ERC20(mainConfig.base);
        admin = mainConfig.protocolAdmin;

        // three pegged 6-decimal payout assets
        usdc = new MockERC20("USD Coin", "USDC", 6);
        mmf = new MockERC20("Money Market Fund", "MMF", 6);
        bond = new MockERC20("Illiquid Bond", "BOND", 6);

        vm.startPrank(admin);
        _addPeggedWithdrawAsset(usdc);
        _addPeggedWithdrawAsset(mmf);
        _addPeggedWithdrawAsset(bond);

        redeemer = new BasketRedeemer(admin, teller);
        rolesAuthority.setUserRole(address(redeemer), SOLVER_ROLE, true);

        BasketRedeemer.BasketLeg[] memory legs = new BasketRedeemer.BasketLeg[](3);
        legs[0] = BasketRedeemer.BasketLeg({ asset: ERC20(address(usdc)), weightBps: W0 });
        legs[1] = BasketRedeemer.BasketLeg({ asset: ERC20(address(mmf)), weightBps: W1 });
        legs[2] = BasketRedeemer.BasketLeg({ asset: ERC20(address(bond)), weightBps: W2 });
        redeemer.setBasket(legs);
        redeemer.setMinRedeemShares(1e6);
        redeemer.setClaimExpiry(EXPIRY);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ covered path

    function test_redeem_covered_paysUniformSlice() public {
        uint256 shares = _mintShares(user, 3000e6);
        _fundVault(usdc, 10_000e6);
        _fundVault(mmf, 10_000e6);
        _fundVault(bond, 10_000e6);

        _redeem(user, shares);

        assertEq(usdc.balanceOf(user), 900e6, "usdc leg (30%)");
        assertEq(mmf.balanceOf(user), 1200e6, "mmf leg (40%)");
        assertEq(bond.balanceOf(user), 900e6, "bond leg (30%)");
        assertEq(vault.balanceOf(user), 0, "shares fully spent");
        assertEq(vault.balanceOf(address(redeemer)), 0, "no shares stranded in redeemer");
        assertEq(redeemer.claimCount(), 0, "no claim opened when covered");
    }

    function test_redeem_revertsLoudly_withoutSolverRole() public {
        uint256 shares = _mintShares(user, 3000e6);
        _fundVault(usdc, 10_000e6);
        _fundVault(mmf, 10_000e6);
        _fundVault(bond, 10_000e6);

        vm.prank(admin);
        rolesAuthority.setUserRole(address(redeemer), SOLVER_ROLE, false); // misconfig

        vm.startPrank(user);
        vault.approve(address(redeemer), shares);
        vm.expectRevert(); // bulkWithdraw is requiresAuth => whole redeem reverts, no silent partial pay
        redeemer.redeem(shares, user, _zeros());
        vm.stopPrank();
    }

    function test_redeem_dust_reverts() public {
        // shares=3 => leg0 = 3*3000/10000 = 0, so the uniform-slice guard must reject it.
        vm.prank(admin);
        redeemer.setMinRedeemShares(1); // lower the coarse floor so we exercise the per-leg guard
        uint256 shares = _mintShares(user, 3);

        vm.startPrank(user);
        vault.approve(address(redeemer), shares);
        vm.expectRevert(BasketRedeemer.RedeemTooSmallForSlice.selector);
        redeemer.redeem(shares, user, _zeros());
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ defer / settle / cancel

    function test_redeem_defers_whenVaultShort() public {
        uint256 shares = _mintShares(user, 3000e6);
        _fundVault(usdc, 10_000e6);
        _fundVault(mmf, 10_000e6);
        // BOND intentionally NOT funded => not coverable

        _redeem(user, shares);

        assertEq(usdc.balanceOf(user), 0, "nothing paid on defer");
        assertEq(mmf.balanceOf(user), 0, "nothing paid on defer");
        assertEq(vault.balanceOf(address(redeemer)), shares, "all shares escrowed");
        assertEq(redeemer.claimCount(), 1, "one coupled claim opened");

        (ERC20[] memory a, uint256[] memory s) = redeemer.claimSnapshot(1);
        assertEq(a.length, 3);
        assertEq(s[0], 900e6);
        assertEq(s[1], 1200e6);
        assertEq(s[2], 900e6);
    }

    function test_settleClaim_afterLiquidityArrives() public {
        uint256 shares = _mintShares(user, 3000e6);
        _fundVault(usdc, 10_000e6);
        _fundVault(mmf, 10_000e6);
        _redeem(user, shares); // defers (no bond)

        _fundVault(bond, 10_000e6); // liquidity arrives

        vm.prank(user); // receiver self-settles
        redeemer.settleClaim(1, _zeros());

        assertEq(usdc.balanceOf(user), 900e6);
        assertEq(mmf.balanceOf(user), 1200e6);
        assertEq(bond.balanceOf(user), 900e6);
        assertEq(vault.balanceOf(address(redeemer)), 0, "escrow fully burned on settle");
    }

    function test_cancelClaim_returnsAllShares() public {
        uint256 shares = _mintShares(user, 3000e6);
        _fundVault(usdc, 10_000e6);
        _redeem(user, shares); // defers

        vm.prank(user);
        redeemer.cancelClaim(1);

        assertEq(vault.balanceOf(user), shares, "100% shares returned, no cash taken");
        assertEq(vault.balanceOf(address(redeemer)), 0);
        assertEq(usdc.balanceOf(user), 0, "no partial cash on cancel");
    }

    function test_cancelClaim_expirySweep_paysReceiver() public {
        uint256 shares = _mintShares(user, 3000e6);
        _redeem(user, shares); // defers (nothing funded)

        vm.warp(block.timestamp + EXPIRY + 1);
        address stranger = makeAddr("stranger");
        vm.prank(stranger); // anyone may sweep after expiry
        redeemer.cancelClaim(1);

        assertEq(vault.balanceOf(user), shares, "sweep always pays the receiver");
    }

    function test_settle_usesSnapshot_notDriftedBasket() public {
        uint256 shares = _mintShares(user, 3000e6);
        _fundVault(usdc, 10_000e6);
        _fundVault(mmf, 10_000e6);
        _redeem(user, shares); // defers under basket A (usdc/mmf/bond)

        // admin drifts the basket to a completely different single asset
        vm.startPrank(admin);
        BasketRedeemer.BasketLeg[] memory legsB = new BasketRedeemer.BasketLeg[](1);
        legsB[0] = BasketRedeemer.BasketLeg({ asset: ERC20(address(usdc)), weightBps: 10_000 });
        redeemer.setBasket(legsB);
        vm.stopPrank();

        _fundVault(bond, 10_000e6);
        vm.prank(user);
        redeemer.settleClaim(1, _zeros()); // snapshot has 3 legs => _zeros() length 3 matches snapshot

        // settled against snapshot A, not drifted basket B
        assertEq(usdc.balanceOf(user), 900e6);
        assertEq(mmf.balanceOf(user), 1200e6);
        assertEq(bond.balanceOf(user), 900e6);
    }

    // ------------------------------------------------------------------ policy hook

    function test_policy_permissionlessWhenUnset() public view {
        // no policy set in setUp => redeem path is permissionless (covered by other tests);
        assertEq(address(redeemer.policy()), address(0), "policy defaults to none");
    }

    function test_policy_gatesRedeem_denyThenAllow() public {
        bytes memory goodAuth = hex"c0ffee";
        MockRedeemPolicy pol = new MockRedeemPolicy(goodAuth);
        vm.prank(admin);
        redeemer.setPolicy(IRedeemPolicy(address(pol)));

        uint256 shares = _mintShares(user, 3000e6);
        _fundVault(usdc, 10_000e6);
        _fundVault(mmf, 10_000e6);
        _fundVault(bond, 10_000e6);

        vm.startPrank(user);
        vault.approve(address(redeemer), shares);

        // wrong/empty authData => policy denies => whole redeem reverts, no shares pulled
        vm.expectRevert(MockRedeemPolicy.PolicyDenied.selector);
        redeemer.redeem(shares, user, _zeros());
        assertEq(vault.balanceOf(user), shares, "shares untouched on policy denial");

        // correct authData => allowed, forwarded verbatim, slice pays out
        redeemer.redeem(shares, user, _zeros(), goodAuth);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), 900e6, "slice paid once authorized");
        assertEq(pol.lastCaller(), user, "policy saw the caller");
        assertEq(pol.lastReceiver(), user, "policy saw the receiver");
        assertEq(pol.lastShares(), shares, "policy saw the shares");
        assertEq(pol.lastAuthData(), goodAuth, "authData forwarded verbatim");
    }

    function test_policy_gatesSettle() public {
        // defer a claim first (no policy), then require auth on settle
        uint256 shares = _mintShares(user, 3000e6);
        _fundVault(usdc, 10_000e6);
        _fundVault(mmf, 10_000e6);
        _redeem(user, shares); // defers (no bond)

        bytes memory goodAuth = hex"beef";
        MockRedeemPolicy pol = new MockRedeemPolicy(goodAuth);
        vm.prank(admin);
        redeemer.setPolicy(IRedeemPolicy(address(pol)));
        _fundVault(bond, 10_000e6);

        vm.startPrank(user);
        vm.expectRevert(MockRedeemPolicy.PolicyDenied.selector);
        redeemer.settleClaim(1, _zeros()); // no authData => denied

        redeemer.settleClaim(1, _zeros(), goodAuth); // authorized
        vm.stopPrank();
        assertEq(bond.balanceOf(user), 900e6, "settled once authorized");
        assertEq(pol.lastReceiver(), user, "policy re-checked the receiver at settle");
    }

    // ------------------------------------------------------------------ helpers

    function _addPeggedWithdrawAsset(MockERC20 a) internal {
        teller.addWithdrawAsset(ERC20(address(a)));
        accountant.setRateProviderData(ERC20(address(a)), true, address(0));
    }

    function _mintShares(address to, uint256 baseAmount) internal returns (uint256 shares) {
        deal(address(base), to, baseAmount);
        vm.startPrank(to);
        base.approve(address(vault), baseAmount);
        shares = teller.deposit(base, baseAmount, 0);
        vm.stopPrank();
    }

    function _fundVault(MockERC20 a, uint256 amount) internal {
        a.mint(address(vault), amount);
    }

    function _redeem(address who, uint256 shares) internal {
        vm.startPrank(who);
        vault.approve(address(redeemer), shares);
        redeemer.redeem(shares, who, _zeros());
        vm.stopPrank();
    }

    function _zeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](3);
    }

}
