// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { DeployAll } from "script/deploy/deployAll.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { MockERC20 } from "@solmate/test/utils/mocks/MockERC20.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { EarlyExitRedeemer } from "src/helper/EarlyExitRedeemer.sol";
import { IRedeemPolicy } from "src/interfaces/IRedeemPolicy.sol";
import { MockRedeemPolicy } from "./BasketRedeemer.t.sol";
import { SOLVER_ROLE } from "src/helper/Constants.sol";

/**
 * @notice Operator-executed discounted early-exit tests against a Celo fork of the nXAUT deployment.
 *   LIVE_DEPLOY_READ_FILE_NAME=test-1-xaut-L2.json OVERRIDE_PROTOCOL_ADMIN=0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631 \
 *     forge test --mp test/EarlyExitRedeemer.t.sol --fork-url https://forno.celo.org -vv
 * Pegged 6-decimal mocks => rate == 1e6, so a leg's slice value == its shares and assertions are exact.
 */
abstract contract ForkStart is Test {

    constructor() {
        if (block.chainid == 31_337) vm.selectFork(vm.createFork(vm.envString("L2_RPC_URL")));
    }

}

contract EarlyExitRedeemerTest is ForkStart, DeployAll {

    EarlyExitRedeemer redeemer;
    BoringVault vault;
    TellerWithMultiAssetSupport teller;
    RolesAuthority rolesAuthority;
    ERC20 base;

    MockERC20 usdc; // 30%
    MockERC20 mmf; //  40%
    MockERC20 bond; // 30%

    address admin;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    uint8 constant OP_ROLE = 33; // a fresh role id for the fill executor

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

        redeemer = new EarlyExitRedeemer(admin, teller);
        rolesAuthority.setUserRole(address(redeemer), SOLVER_ROLE, true);

        EarlyExitRedeemer.BasketLeg[] memory legs = new EarlyExitRedeemer.BasketLeg[](3);
        legs[0] = EarlyExitRedeemer.BasketLeg({ asset: ERC20(address(usdc)), weightBps: 3000, illiquid: false });
        legs[1] = EarlyExitRedeemer.BasketLeg({ asset: ERC20(address(mmf)), weightBps: 4000, illiquid: false });
        legs[2] = EarlyExitRedeemer.BasketLeg({ asset: ERC20(address(bond)), weightBps: 3000, illiquid: false });
        redeemer.setBasket(legs);
        redeemer.setFeeBand(10, 500); // 0.1% .. 5%
        redeemer.setMinRequestShares(1e6);

        // Flexible auth: fills are `requiresAuth`. Here we gate them to an OPERATOR role granted to
        // `operator` (could instead be made public via setPublicCapability, or granted to many addresses).
        redeemer.setAuthority(rolesAuthority);
        rolesAuthority.setRoleCapability(
            OP_ROLE, address(redeemer), bytes4(keccak256("fillEarlyExit(uint256,uint16,uint256[])")), true
        );
        rolesAuthority.setRoleCapability(
            OP_ROLE, address(redeemer), bytes4(keccak256("fillEarlyExit(uint256,uint16,uint256[],bytes)")), true
        );
        rolesAuthority.setRoleCapability(OP_ROLE, address(redeemer), redeemer.fillAllCashFromVault.selector, true);
        rolesAuthority.setRoleCapability(OP_ROLE, address(redeemer), redeemer.fillAllCash.selector, true);
        rolesAuthority.setUserRole(operator, OP_ROLE, true);
        vm.stopPrank();

        _fundVault(usdc, 100_000e6);
        _fundVault(mmf, 100_000e6);
        _fundVault(bond, 100_000e6);
    }

    // -------------------------------------------------------- fill pays discounted slice + accretes

    function test_fill_paysDiscountedSlice_andAccretes() public {
        uint256 id = _request(alice, 1000e6, 500);

        uint256 vUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(operator);
        redeemer.fillEarlyExit(id, 200, _zeros()); // 2% discount

        // exiter gets 98% of each leg (300/400/300 gross)
        assertEq(usdc.balanceOf(alice), 294e6);
        assertEq(mmf.balanceOf(alice), 392e6);
        assertEq(bond.balanceOf(alice), 294e6);

        // accretion: vault paid out only 294e6 for the 300e6-share usdc leg — it kept the 6e6 fee.
        assertEq(usdc.balanceOf(address(vault)), vUsdcBefore - 294e6, "fee stays in vault (accretion)");

        assertEq(vault.balanceOf(address(redeemer)), 0, "all escrowed shares burned");
        assertEq(vault.balanceOf(alice), 0);
    }

    // -------------------------------------------------------- guards

    function test_unauthorized_cannotFill() public {
        uint256 id = _request(alice, 1000e6, 500);
        // address(this) has neither OP_ROLE nor ownership => solmate Auth reverts UNAUTHORIZED
        vm.expectRevert(bytes("UNAUTHORIZED"));
        redeemer.fillEarlyExit(id, 200, _zeros());
    }

    function test_publicCapability_allowsAnyone() public {
        // Demonstrate the flexible model: make one fill selector public => any address can execute it.
        vm.prank(admin);
        rolesAuthority.setPublicCapability(
            address(redeemer), bytes4(keccak256("fillEarlyExit(uint256,uint16,uint256[])")), true
        );
        uint256 id = _request(alice, 1000e6, 500);
        vm.prank(makeAddr("random filler"));
        redeemer.fillEarlyExit(id, 200, _zeros()); // no role, no ownership — allowed because public
        assertEq(usdc.balanceOf(alice), 294e6);
    }

    function test_fill_respectsFeeBand_andUserCeiling() public {
        uint256 id = _request(alice, 1000e6, 300); // user accepts up to 3%

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(EarlyExitRedeemer.FeeOutOfBand.selector, uint16(5)));
        redeemer.fillEarlyExit(id, 5, _zeros()); // below feeMin (10)

        vm.expectRevert(abi.encodeWithSelector(EarlyExitRedeemer.FeeOutOfBand.selector, uint16(400)));
        redeemer.fillEarlyExit(id, 400, _zeros()); // above the user's 300 ceiling (even though < feeMax 500)

        redeemer.fillEarlyExit(id, 300, _zeros()); // exactly at the user's ceiling => ok
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 291e6); // 300e6 * 97%
    }

    function test_fill_navStale_reverts() public {
        vm.prank(admin);
        redeemer.setMaxNavAge(1 hours);
        uint256 id = _request(alice, 1000e6, 500);

        vm.warp(block.timestamp + 2 hours); // NAV now stale
        vm.prank(operator);
        vm.expectRevert(EarlyExitRedeemer.NavStale.selector);
        redeemer.fillEarlyExit(id, 200, _zeros());
    }

    function test_periodCap_enforced() public {
        vm.prank(admin);
        redeemer.setPeriodCap(1500e6, 1 days); // <= 1500e6 shares filled per day

        uint256 id1 = _request(alice, 1000e6, 500);
        uint256 id2 = _request(alice, 1000e6, 500);

        vm.startPrank(operator);
        redeemer.fillEarlyExit(id1, 100, _zeros()); // 1000e6 filled
        vm.expectRevert(EarlyExitRedeemer.PeriodCapExceeded.selector);
        redeemer.fillEarlyExit(id2, 100, _zeros()); // +1000e6 => 2000e6 > 1500e6 cap
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1); // new period
        vm.prank(operator);
        redeemer.fillEarlyExit(id2, 100, _zeros()); // now fits
        assertEq(mmf.balanceOf(alice), 400e6 * 2 * 99 / 100);
    }

    function test_cancel_returnsShares() public {
        uint256 id = _request(alice, 1000e6, 500);
        vm.prank(alice);
        redeemer.cancelEarlyExit(id);
        assertEq(vault.balanceOf(alice), 1000e6, "shares back on cancel");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(EarlyExitRedeemer.OrderClosed.selector, id));
        redeemer.fillEarlyExit(id, 200, _zeros()); // can't fill a cancelled order
    }

    function test_cancel_onlyOwner() public {
        uint256 id = _request(alice, 1000e6, 500);
        vm.expectRevert(abi.encodeWithSelector(EarlyExitRedeemer.NotOrderOwner.selector, id));
        redeemer.cancelEarlyExit(id); // caller != alice
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
        redeemer.requestEarlyExit(shares, 500);
        redeemer.requestEarlyExit(shares, 500, good); // authorized
        vm.stopPrank();
    }

    /// Fill re-checks the policy at asset-exit (audit fix): a post-request denylist blocks the slice.
    function test_policy_gates_fill() public {
        bytes memory good = hex"beef";
        MockRedeemPolicy pol = new MockRedeemPolicy(good);

        uint256 shares = _mintShares(alice, 1000e6);
        vm.startPrank(alice);
        vault.approve(address(redeemer), shares);
        uint256 id = redeemer.requestEarlyExit(shares, 500); // no policy yet
        vm.stopPrank();

        vm.prank(admin);
        redeemer.setPolicy(IRedeemPolicy(address(pol)));

        vm.startPrank(operator);
        vm.expectRevert(MockRedeemPolicy.PolicyDenied.selector);
        redeemer.fillEarlyExit(id, 200, _zeros()); // empty authData => denied
        redeemer.fillEarlyExit(id, 200, _zeros(), good); // fresh auth => filled
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 294e6);
    }

    function test_setPeriodCap_rejectsZeroWindow() public {
        vm.prank(admin);
        vm.expectRevert(EarlyExitRedeemer.BadPeriodCap.selector);
        redeemer.setPeriodCap(1000e6, 0);
    }

    function test_setFeeBand_rejectsZeroFloor() public {
        vm.prank(admin);
        vm.expectRevert(EarlyExitRedeemer.BadFeeBand.selector);
        redeemer.setFeeBand(0, 500); // no par exits
    }

    // -------------------------------------------------------- all-cash: vault underwrites (mode B)

    function test_fillAllCashFromVault_paysStable_keepsIlliquid_capturesFullFee() public {
        _configAllCash(); // basket: USDC 60% liquid, BOND 40% illiquid; payoutStable = USDC

        uint256 id = _requestAllCash(alice, 1000e6, 500, 0);
        uint256 vaultBondBefore = bond.balanceOf(address(vault));
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));

        vm.prank(operator);
        redeemer.fillAllCashFromVault(id, 200, 0, ""); // 2% fee

        // exiter gets 98% of NAV entirely in USDC (redeemed against the sleeve)
        assertEq(usdc.balanceOf(alice), 980e6, "all-cash payout in USDC");
        assertEq(bond.balanceOf(alice), 0, "no illiquid to the exiter");
        // vault KEEPS the illiquid untouched, and captures the whole 20e6 fee
        assertEq(bond.balanceOf(address(vault)), vaultBondBefore, "vault keeps the illiquid");
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore - 980e6, "whole fee retained (only 980 left the vault)");
    }

    // -------------------------------------------------------- all-cash: external underwriter (mode A)

    function test_fillAllCash_externalUnderwriter_signed() public {
        _configAllCash();
        uint256 uwPk = 0xA11CE;
        address uw = vm.addr(uwPk);
        vm.prank(admin);
        redeemer.setUnderwriter(uw, true);

        // fund the underwriter with USDC to pay for the illiquid, and approve the redeemer
        deal(address(usdc), uw, 1_000e6);
        vm.prank(uw);
        usdc.approve(address(redeemer), type(uint256).max);

        uint256 id = _requestAllCash(alice, 1000e6, 500, 0);

        // bid: buy the 400e6 BOND leg for 380e6 USDC (5% haircut); fee 2.5% covers illiqWeight*u = 2%
        ERC20[] memory illiqAssets = new ERC20[](1);
        illiqAssets[0] = ERC20(address(bond));
        uint256[] memory minUnits = new uint256[](1);
        minUnits[0] = 400e6;
        EarlyExitRedeemer.UnderwriterBid memory bid = _signBid(uwPk, uw, id, 380e6, illiqAssets, minUnits, 0, block.timestamp + 1 hours);

        vm.prank(operator);
        redeemer.fillAllCash(id, 250, bid, "");

        assertEq(usdc.balanceOf(alice), 975e6, "exiter all cash at 2.5% fee");
        assertEq(bond.balanceOf(uw), 400e6, "underwriter took the illiquid");
        assertEq(usdc.balanceOf(uw), 1_000e6 - 380e6, "underwriter paid 380 USDC");
    }

    function test_fillAllCash_reverts_onAccretionViolation() public {
        _configAllCash();
        uint256 uwPk = 0xB0B;
        address uw = vm.addr(uwPk);
        vm.prank(admin);
        redeemer.setUnderwriter(uw, true);
        deal(address(usdc), uw, 1_000e6);
        vm.prank(uw);
        usdc.approve(address(redeemer), type(uint256).max);

        uint256 id = _requestAllCash(alice, 1000e6, 500, 0);
        ERC20[] memory illiqAssets = new ERC20[](1);
        illiqAssets[0] = ERC20(address(bond));
        uint256[] memory minUnits = new uint256[](1);
        minUnits[0] = 400e6;
        // underwriter underpays (300e6) => cashPot 900 < payout ~975 => revert
        EarlyExitRedeemer.UnderwriterBid memory bid = _signBid(uwPk, uw, id, 300e6, illiqAssets, minUnits, 0, block.timestamp + 1 hours);

        vm.prank(operator);
        vm.expectRevert(); // AccretionViolation
        redeemer.fillAllCash(id, 250, bid, "");
    }

    function test_fillAllCash_reverts_badSig() public {
        _configAllCash();
        uint256 uwPk = 0xC0C;
        address uw = vm.addr(uwPk);
        vm.prank(admin);
        redeemer.setUnderwriter(uw, true);
        deal(address(usdc), uw, 1_000e6);

        uint256 id = _requestAllCash(alice, 1000e6, 500, 0);
        ERC20[] memory illiqAssets = new ERC20[](1);
        illiqAssets[0] = ERC20(address(bond));
        uint256[] memory minUnits = new uint256[](1);
        minUnits[0] = 400e6;
        // sign with the WRONG key
        EarlyExitRedeemer.UnderwriterBid memory bid = _signBid(0xDEAD, uw, id, 380e6, illiqAssets, minUnits, 0, block.timestamp + 1 hours);

        vm.prank(operator);
        vm.expectRevert(); // BadUnderwriterSig
        redeemer.fillAllCash(id, 250, bid, "");
    }

    function test_allCash_notOptedIn_reverts() public {
        _configAllCash();
        uint256 id = _request(alice, 1000e6, 500); // plain request, not all-cash
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(EarlyExitRedeemer.NotOptedIntoAllCash.selector, id));
        redeemer.fillAllCashFromVault(id, 200, 0, "");
    }

    // -------------------------------------------------------- helpers

    function _configAllCash() internal {
        vm.startPrank(admin);
        EarlyExitRedeemer.BasketLeg[] memory legs = new EarlyExitRedeemer.BasketLeg[](2);
        legs[0] = EarlyExitRedeemer.BasketLeg({ asset: ERC20(address(usdc)), weightBps: 6000, illiquid: false });
        legs[1] = EarlyExitRedeemer.BasketLeg({ asset: ERC20(address(bond)), weightBps: 4000, illiquid: true });
        redeemer.setBasket(legs);
        redeemer.setPayoutStable(ERC20(address(usdc)));
        redeemer.setMaxUnderwriterHaircut(1000); // <= 10% haircut on the illiquid
        vm.stopPrank();
    }

    function _requestAllCash(
        address who,
        uint256 baseAmount,
        uint16 maxFeeBps,
        uint256 minStableOut
    )
        internal
        returns (uint256 id)
    {
        uint256 shares = _mintShares(who, baseAmount);
        vm.startPrank(who);
        vault.approve(address(redeemer), shares);
        id = redeemer.requestEarlyExitAllCash(shares, maxFeeBps, minStableOut);
        vm.stopPrank();
    }

    function _signBid(
        uint256 pk,
        address uw,
        uint256 orderId,
        uint256 cashIn,
        ERC20[] memory illiqAssets,
        uint256[] memory minUnits,
        uint256 nonce,
        uint256 deadline
    )
        internal
        view
        returns (EarlyExitRedeemer.UnderwriterBid memory bid)
    {
        bytes32 termsHash = keccak256(abi.encode(illiqAssets, minUnits));
        bytes32 digest = keccak256(
            abi.encode(
                redeemer.FILL_ALL_CASH_TYPEHASH(),
                orderId,
                address(usdc),
                cashIn,
                termsHash,
                uw,
                nonce,
                deadline,
                address(redeemer),
                block.chainid
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bid = EarlyExitRedeemer.UnderwriterBid({
            underwriter: uw,
            cashIn: cashIn,
            illiquidAssets: illiqAssets,
            minUnits: minUnits,
            nonce: nonce,
            deadline: deadline,
            signature: abi.encodePacked(r, s, v)
        });
    }

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

    function _request(address who, uint256 baseAmount, uint16 maxFeeBps) internal returns (uint256 id) {
        uint256 shares = _mintShares(who, baseAmount);
        vm.startPrank(who);
        vault.approve(address(redeemer), shares);
        id = redeemer.requestEarlyExit(shares, maxFeeBps);
        vm.stopPrank();
    }

    function _fundVault(MockERC20 a, uint256 amount) internal {
        a.mint(address(vault), amount);
    }

    function _zeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](3);
    }

}
