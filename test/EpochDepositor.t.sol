// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { EpochDepositor } from "src/helper/EpochDepositor.sol";
import { IDepositPolicy } from "src/interfaces/IDepositPolicy.sol";

contract MockToken is ERC20 {

    constructor(string memory n, string memory s) ERC20(n, s, 18) { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

}

/// @notice Only implements the one function EpochDepositor calls on the accountant.
contract MockAccountant {

    uint256 public rate;

    constructor(uint256 r) {
        rate = r;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function getRateInQuoteSafe(ERC20) external view returns (uint256) {
        return rate;
    }

}

contract MockDepositPolicy is IDepositPolicy {

    bool public allow = true;
    bytes public lastAuthData;

    error Denied();

    function setAllow(bool a) external {
        allow = a;
    }

    function authorizeDeposit(address, address, uint256, bytes calldata authData) external {
        lastAuthData = authData;
        if (!allow) revert Denied();
    }

}

contract EpochDepositorTest is Test {

    BoringVault internal vault;
    MockToken internal asset;
    MockAccountant internal accountant;
    EpochDepositor internal depositor;
    RolesAuthority internal auth;

    uint8 internal constant MINTER_ROLE = 1;
    uint64 internal constant EPOCH = 7 days;
    uint256 internal constant MIN = 100e18;
    uint256 internal constant ONE = 1e18;
    address internal constant FEE_RECIPIENT = address(0xFEE);

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() external {
        vault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        asset = new MockToken("USD", "USD");
        accountant = new MockAccountant(ONE); // 1:1 by default
        depositor = new EpochDepositor(
            address(this), address(vault), address(accountant), address(asset), EPOCH, MIN, FEE_RECIPIENT
        );

        auth = new RolesAuthority(address(this), Authority(address(0)));
        vault.setAuthority(auth);
        auth.setRoleCapability(MINTER_ROLE, address(vault), BoringVault.enter.selector, true);
        auth.setUserRole(address(depositor), MINTER_ROLE, true);

        for (uint256 i; i < 3; ++i) {
            address u = [alice, bob, carol][i];
            asset.mint(u, 1_000_000e18);
            vm.prank(u);
            asset.approve(address(depositor), type(uint256).max);
        }
    }

    function _request(address u, uint256 amt) internal {
        vm.prank(u);
        depositor.requestDeposit(amt, u, u);
    }

    function _closePastSettle() internal {
        vm.warp(block.timestamp + EPOCH + 1);
        depositor.closeEpoch();
    }

    // --- requests / minimum -------------------------------------------------

    function testRequestAccumulatesAndEnforcesMin() external {
        vm.prank(alice);
        vm.expectRevert(EpochDepositor.EpochDepositor__BelowMinimum.selector);
        depositor.requestDeposit(50e18, alice, alice); // below MIN

        _request(alice, 100e18);
        _request(alice, 50e18); // adds
        assertEq(depositor.deposited(0, alice), 150e18);
        assertEq(asset.balanceOf(address(depositor)), 150e18);
        assertEq(depositor.pendingDepositRequest(0, alice), 150e18);
    }

    // --- cancel / dust guard ------------------------------------------------

    function testCancelPartialKeepsAboveFloorAndDustReverts() external {
        _request(alice, 150e18);

        vm.prank(alice);
        depositor.cancelDeposit(40e18, alice); // remaining 110 >= MIN
        assertEq(depositor.deposited(0, alice), 110e18);
        assertEq(asset.balanceOf(alice), 1_000_000e18 - 110e18);

        vm.prank(alice);
        vm.expectRevert(EpochDepositor.EpochDepositor__BelowMinimum.selector);
        depositor.cancelDeposit(20e18, alice); // would leave 90 < MIN

        vm.prank(alice);
        depositor.cancelAll(alice); // full exit ok
        assertEq(depositor.deposited(0, alice), 0);
        assertEq(asset.balanceOf(alice), 1_000_000e18);
    }

    // --- settlement / claim -------------------------------------------------

    function testCloseAndClaimProRata() external {
        _request(alice, 100e18);
        _request(bob, 300e18);

        _closePastSettle();
        (,, bool settled,, uint256 total, uint256 sharesMinted, uint256 rate) = depositor.epochs(0);
        assertTrue(settled);
        assertEq(total, 400e18);
        assertEq(sharesMinted, 400e18); // 1:1
        assertEq(rate, ONE);
        assertEq(depositor.currentEpoch(), 1);
        assertEq(vault.balanceOf(address(depositor)), 400e18);

        vm.prank(alice);
        depositor.claim(0, alice, alice);
        vm.prank(bob);
        depositor.claim(0, bob, bob);
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.balanceOf(bob), 300e18);
        assertEq(vault.balanceOf(address(depositor)), 0);
    }

    function testProRataNonUnitRate() external {
        accountant.setRate(2 * ONE); // each share worth 2 asset
        _request(alice, 100e18);
        _request(bob, 300e18);
        _closePastSettle();

        (,,,,, uint256 sharesMinted,) = depositor.epochs(0);
        assertEq(sharesMinted, 200e18); // 400 * 1e18 / 2e18

        vm.prank(alice);
        assertEq(depositor.claim(0, alice, alice), 50e18); // 100 * 200/400
        vm.prank(bob);
        assertEq(depositor.claim(0, bob, bob), 150e18);
    }

    // --- ERC-7540 claim path ------------------------------------------------

    function testErc7540DepositAndMintClaim() external {
        _request(alice, 200e18);
        _request(bob, 100e18);
        _closePastSettle();

        assertEq(depositor.claimableDepositRequest(0, alice), 200e18);
        assertEq(depositor.previewClaim(0, alice), 200e18);

        // deposit(assets) claims the sole settled epoch
        vm.prank(alice);
        assertEq(depositor.deposit(200e18, alice, alice), 200e18);
        assertEq(vault.balanceOf(alice), 200e18);

        // mint(shares) for bob
        vm.prank(bob);
        depositor.mint(100e18, bob, bob);
        assertEq(vault.balanceOf(bob), 100e18);
    }

    // --- disperse -----------------------------------------------------------

    function testDisperseBatch() external {
        _request(alice, 100e18);
        _request(bob, 200e18);
        _closePastSettle();

        address[] memory who = new address[](2);
        who[0] = alice;
        who[1] = bob;
        depositor.disperse(0, who); // permissionless
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.balanceOf(bob), 200e18);
    }

    // --- atomic mint --------------------------------------------------------

    function testAtomicMintWithFee() external {
        depositor.setFeeConfig(FEE_RECIPIENT, 100); // 1%
        asset.mint(address(this), 100e18);
        asset.approve(address(depositor), 100e18);

        uint256 shares = depositor.atomicMint(carol, 100e18, 0);
        assertEq(shares, 99e18); // net 99 at 1:1
        assertEq(vault.balanceOf(carol), 99e18);
        assertEq(asset.balanceOf(FEE_RECIPIENT), 1e18);
    }

    function testAtomicMintOnlyAuthorized() external {
        asset.mint(alice, 100e18);
        vm.startPrank(alice);
        asset.approve(address(depositor), 100e18);
        vm.expectRevert("UNAUTHORIZED");
        depositor.atomicMint(carol, 100e18, 0);
        vm.stopPrank();
    }

    // --- operator -----------------------------------------------------------

    function testOperatorActsForController() external {
        vm.prank(alice);
        depositor.setOperator(bob, true);

        // bob requests on alice's behalf (owner = alice, so alice's approval/funds used)
        vm.prank(bob);
        depositor.requestDeposit(100e18, alice, alice);
        assertEq(depositor.deposited(0, alice), 100e18);

        _closePastSettle();
        // bob claims for alice
        vm.prank(bob);
        depositor.claim(0, alice, alice);
        assertEq(vault.balanceOf(alice), 100e18);
    }

    // --- policy -------------------------------------------------------------

    function testPolicyGate() external {
        MockDepositPolicy policy = new MockDepositPolicy();
        depositor.setDepositPolicy(address(policy));

        policy.setAllow(false);
        vm.prank(alice);
        vm.expectRevert(MockDepositPolicy.Denied.selector);
        depositor.requestDeposit(100e18, alice, alice, hex"abcd");

        policy.setAllow(true);
        vm.prank(alice);
        depositor.requestDeposit(100e18, alice, alice, hex"abcd");
        assertEq(depositor.deposited(0, alice), 100e18);
        assertEq(policy.lastAuthData(), hex"abcd");
    }

    // --- timing guard -------------------------------------------------------

    function testRetimeGuard() external {
        // valid retime (>24h before settle): extend by a day
        uint64 newSettle = uint64(block.timestamp) + EPOCH + 1 days;
        depositor.retimeCurrentEpoch(newSettle);
        (, uint64 st,,,,,) = depositor.epochs(0);
        assertEq(st, newSettle);

        // within 24h of settle -> frozen
        vm.warp(newSettle - 12 hours);
        vm.expectRevert(EpochDepositor.EpochDepositor__TimingGuardActive.selector);
        depositor.retimeCurrentEpoch(newSettle + 1 days);
    }

    // --- refund -------------------------------------------------------------

    function testRefundStuckEpoch() external {
        _request(alice, 100e18);
        vm.warp(block.timestamp + EPOCH + 1);

        depositor.refundEpoch(); // abandons settlement, opens epoch 1
        assertEq(depositor.currentEpoch(), 1);

        vm.prank(alice);
        uint256 got = depositor.refund(0, alice);
        assertEq(got, 100e18);
        assertEq(asset.balanceOf(alice), 1_000_000e18);
    }

    function testCannotClaimBeforeSettle() external {
        _request(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(EpochDepositor.EpochDepositor__NotSettled.selector);
        depositor.claim(0, alice, alice);
    }

    // --- hardening -----------------------------------------------------------

    function testCloseRevertsOnDegenerateRateThenRefund() external {
        _request(alice, 200e18);
        accountant.setRate(1e40); // absurd rate -> sharesMinted would round to 0
        vm.warp(block.timestamp + EPOCH + 1);

        vm.expectRevert(EpochDepositor.EpochDepositor__MinSharesNotMet.selector);
        depositor.closeEpoch(); // refuses to sweep assets for zero shares

        // epoch stays recoverable
        depositor.refundEpoch();
        vm.prank(alice);
        assertEq(depositor.refund(0, alice), 200e18);
    }

    function testPreviewClaimEmptySettledEpoch() external {
        _closePastSettle(); // no deposits -> epoch 0 settles empty
        (,, bool settled,, uint256 total,,) = depositor.epochs(0);
        assertTrue(settled);
        assertEq(total, 0);
        assertEq(depositor.previewClaim(0, alice), 0); // 0/0 guarded, no revert
    }

    // --- fuzz: pro-rata never over-distributes -------------------------------

    function testFuzz_twoUserClaimConserves(uint256 aAmt, uint256 bAmt, uint256 rate) external {
        aAmt = bound(aAmt, MIN, 100_000e18);
        bAmt = bound(bAmt, MIN, 100_000e18);
        accountant.setRate(bound(rate, ONE / 2, 10 * ONE)); // sane rate band

        _request(alice, aAmt);
        _request(bob, bAmt);
        _closePastSettle();

        (,,,,, uint256 sharesMinted,) = depositor.epochs(0);
        assertEq(vault.balanceOf(address(depositor)), sharesMinted); // whole epoch minted to the pool

        vm.prank(alice);
        uint256 sA = depositor.claim(0, alice, alice);
        vm.prank(bob);
        uint256 sB = depositor.claim(0, bob, bob);

        // never mints/distributes more than the pool; dust (if any) stays in the contract
        assertLe(sA + sB, sharesMinted);
        assertEq(vault.balanceOf(alice), sA);
        assertEq(vault.balanceOf(bob), sB);
        assertEq(vault.balanceOf(address(depositor)), sharesMinted - sA - sB);
    }

}
