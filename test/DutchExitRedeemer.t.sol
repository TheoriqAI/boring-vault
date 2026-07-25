// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { DeployAll } from "script/deploy/deployAll.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "@solmate/test/utils/mocks/MockERC20.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { DutchExitRedeemer } from "src/helper/DutchExitRedeemer.sol";
import { IRedeemPolicy } from "src/interfaces/IRedeemPolicy.sol";
import { MockRedeemPolicy } from "./BasketRedeemer.t.sol";
import { SOLVER_ROLE } from "src/helper/Constants.sol";

/**
 * @notice Dutch (declining-price) early-exit tests against a Celo fork of the nXAUT deployment.
 *   LIVE_DEPLOY_READ_FILE_NAME=test-1-xaut-L2.json OVERRIDE_PROTOCOL_ADMIN=0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631 \
 *     forge test --mp test/DutchExitRedeemer.t.sol --fork-url https://forno.celo.org -vv
 * Pegged 6-decimal mocks => rate == 1e6, so a leg's slice value == its shares and assertions are exact.
 */
abstract contract ForkStart is Test {

    constructor() {
        if (block.chainid == 31_337) vm.selectFork(vm.createFork(vm.envString("L2_RPC_URL")));
    }

}

contract DutchExitRedeemerTest is ForkStart, DeployAll {

    DutchExitRedeemer redeemer;
    BoringVault vault;
    TellerWithMultiAssetSupport teller;
    RolesAuthority rolesAuthority;
    ERC20 base;

    MockERC20 usdc; // cash asset + 30% leg
    MockERC20 mmf; //  40%
    MockERC20 bond; // 30% (illiquid)

    address admin;
    address alice = makeAddr("alice"); // exiter
    address filler = makeAddr("filler");

    uint64 constant DURATION = 1 days;

    function setUp() public {
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

        redeemer = new DutchExitRedeemer(admin, teller);
        rolesAuthority.setUserRole(address(redeemer), SOLVER_ROLE, true);

        DutchExitRedeemer.BasketLeg[] memory legs = new DutchExitRedeemer.BasketLeg[](3);
        legs[0] = DutchExitRedeemer.BasketLeg({ asset: ERC20(address(usdc)), weightBps: 3000 });
        legs[1] = DutchExitRedeemer.BasketLeg({ asset: ERC20(address(mmf)), weightBps: 4000 });
        legs[2] = DutchExitRedeemer.BasketLeg({ asset: ERC20(address(bond)), weightBps: 3000 });
        redeemer.setBasket(legs);
        redeemer.setCashAsset(ERC20(address(usdc)));
        redeemer.setVaultFee(100); // 1% accretion cut
        redeemer.setMinRequestShares(1e6);

        // Public Dutch auction: fillDutch is requiresAuth; make it public so any bidder can fill.
        redeemer.setAuthority(rolesAuthority);
        rolesAuthority.setPublicCapability(address(redeemer), redeemer.fillDutch.selector, true);
        vm.stopPrank();

        // fund the filler with cash + approval
        deal(address(usdc), filler, 10_000e6);
        vm.prank(filler);
        usdc.approve(address(redeemer), type(uint256).max);
    }

    // ------------------------------------------------------------------ core fill

    function test_fillDutch_exiterGetsCash_fillerGetsSliceMinusFee_vaultAccretes() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);

        uint256 id = _request(alice, 1000e6, 1000e6, 900e6, DURATION);
        vm.warp(block.timestamp + DURATION / 2); // price decays to 950e6
        assertEq(redeemer.currentPrice(id), 950e6, "linear decay midpoint");

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(filler);
        redeemer.fillDutch(id, 1000e6, _zeros());

        // exiter received the cash
        assertEq(usdc.balanceOf(alice), 950e6, "exiter paid the current dutch price in cash");
        // filler received the slice minus the 1% vault fee (297/396/297 of the 300/400/300 gross)
        assertEq(mmf.balanceOf(filler), 396e6, "filler got mmf leg minus fee");
        assertEq(bond.balanceOf(filler), 297e6, "filler got bond leg minus fee (holds the duration risk)");
        // vault kept the fee => accretion (only 297e6 of the 300e6 usdc leg left the vault)
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore - 297e6, "vault retained the 1% fee");
        assertEq(vault.balanceOf(address(redeemer)), 0, "all escrowed shares burned");
    }

    function test_currentPrice_bounds() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
        uint256 id = _request(alice, 1000e6, 1000e6, 900e6, DURATION);
        assertEq(redeemer.currentPrice(id), 1000e6, "starts at priceStart");
        vm.warp(block.timestamp + DURATION + 1);
        assertEq(redeemer.currentPrice(id), 900e6, "clamps at priceFloor after duration");
    }

    // ------------------------------------------------------------------ guards

    function test_fillDutch_reverts_ifVaultCannotCoverSlice() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        // bond leg unfunded => vault can't cover it

        uint256 id = _request(alice, 1000e6, 1000e6, 900e6, DURATION);
        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(DutchExitRedeemer.InsufficientVaultLiquidity.selector, ERC20(address(bond)), 300e6, 0)
        );
        redeemer.fillDutch(id, 1000e6, _zeros());
    }

    function test_fillDutch_reverts_priceAboveMax() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
        uint256 id = _request(alice, 1000e6, 1000e6, 900e6, DURATION);
        // price is 1000e6 at t0; filler caps at 940e6
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(DutchExitRedeemer.PriceAboveMax.selector, uint256(1000e6), uint256(940e6)));
        redeemer.fillDutch(id, 940e6, _zeros());
    }

    function test_fillDutch_navStale_reverts() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
        vm.prank(admin);
        redeemer.setMaxNavAge(1 hours);
        uint256 id = _request(alice, 1000e6, 1000e6, 900e6, DURATION);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(filler);
        vm.expectRevert(DutchExitRedeemer.NavStale.selector);
        redeemer.fillDutch(id, 1000e6, _zeros());
    }

    function test_cancelDutch_returnsShares() public {
        uint256 id = _request(alice, 1000e6, 1000e6, 900e6, DURATION);
        vm.prank(alice);
        redeemer.cancelDutch(id);
        assertEq(vault.balanceOf(alice), 1000e6, "shares rebated on cancel");

        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(DutchExitRedeemer.OrderClosed.selector, id));
        redeemer.fillDutch(id, 1000e6, _zeros());
    }

    function test_fillDutch_requiresAuth_whenNotPublic() public {
        // revoke the public capability => a random filler is unauthorized
        vm.prank(admin);
        rolesAuthority.setPublicCapability(address(redeemer), redeemer.fillDutch.selector, false);
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
        uint256 id = _request(alice, 1000e6, 1000e6, 900e6, DURATION);
        vm.prank(filler);
        vm.expectRevert(bytes("UNAUTHORIZED"));
        redeemer.fillDutch(id, 1000e6, _zeros());
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
        redeemer.requestDutch(shares, 1000e6, 900e6, DURATION);
        redeemer.requestDutch(shares, 1000e6, 900e6, DURATION, good); // authorized
        vm.stopPrank();
    }

    /// Audit fix: cashAsset is snapshot at request, so an admin swap can't reinterpret an open order.
    function test_cashAssetSnapshot_protectsExiter() public {
        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);

        uint256 id = _request(alice, 1000e6, 1000e6, 900e6, DURATION); // snapshots cashAsset = USDC

        vm.prank(admin);
        redeemer.setCashAsset(ERC20(address(mmf))); // admin swaps the global cash asset to MMF

        vm.prank(filler);
        redeemer.fillDutch(id, 1000e6, _zeros()); // price 1000e6 at t0

        // exiter is paid in USDC (the snapshot), NOT the swapped MMF
        assertEq(usdc.balanceOf(alice), 1000e6, "paid in the snapshot cash asset");
        assertEq(mmf.balanceOf(alice), 0, "not paid in the swapped asset");
    }

    // ------------------------------------------------------------------ helpers

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

    function _request(
        address who,
        uint256 baseAmount,
        uint256 priceStart,
        uint256 priceFloor,
        uint64 duration
    )
        internal
        returns (uint256 id)
    {
        uint256 shares = _mintShares(who, baseAmount);
        vm.startPrank(who);
        vault.approve(address(redeemer), shares);
        id = redeemer.requestDutch(shares, priceStart, priceFloor, duration);
        vm.stopPrank();
    }

    function _fundVault(MockERC20 a, uint256 amount) internal {
        a.mint(address(vault), amount);
    }

    function _zeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](3);
    }

}
