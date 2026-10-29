// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { console2 } from "@forge-std/console2.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { IERC20 } from "src/interfaces/IFeeModule.sol";

import { DeployAllWithRoleGrants } from "script/deploy/deployAllWithRoleGrants.s.sol";
import { ForkTest } from "test/LiveDeploy.t.sol";

/**
 * @notice End-user flows for the `vmUSD` mainnet deploy: a real USDC holder approving, depositing,
 *         and redeeming through the audited `WithdrawQueue` — including the cases where the redeem does
 *         NOT go through (vault has no liquidity, teller paused, head-of-line blocking).
 * @dev    Same harness as `VmUsdRolesAndOwnership`: the deploy runs in `setUp`, so every test here
 *         exercises the post-hand-off system (owner = 0xCB06…, operator roles on 0xA072… and 0xCB06…).
 *           LIVE_DEPLOY_READ_FILE_NAME=vmUSD.json \
 *             forge test --mp test/VmUsdUserFlows.t.sol --fork-url $L1_RPC_URL
 */
contract VmUsdUserFlows is ForkTest, DeployAllWithRoleGrants {

    address constant OPERATOR_A = 0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631;
    address constant FINAL_OWNER = 0xCB068924bb3D2Ebb28BD1BB25b09ec15b0D5a03B;

    uint256 constant DEPOSIT = 10_000e6; // 10,000 USDC

    ERC20 usdc;
    BoringVault vault;
    TellerWithMultiAssetSupport teller;
    WithdrawQueue queue;
    AccountantWithRateProviders accountant;

    function setUp() public {
        string memory file = block.chainid == 31_337 ? "vmUSD.json" : vm.envString("LIVE_DEPLOY_READ_FILE_NAME");
        if (block.chainid == 31_337) _startFork("L1_RPC_URL");

        runLiveTestWithRoleGrants(file);

        usdc = ERC20(mainConfig.base);
        vault = BoringVault(payable(mainConfig.boringVault));
        teller = TellerWithMultiAssetSupport(mainConfig.teller);
        queue = WithdrawQueue(mainConfig.withdrawQueue);
        accountant = AccountantWithRateProviders(mainConfig.accountant);
    }

    // ========================================= HAPPY PATH =========================================

    /// @notice A funded user approves USDC, deposits, then redeems the whole position through the queue.
    function testUserApproveDepositThenRedeemFullCycle() public {
        address user = makeAddr("funded user");
        deal(address(usdc), user, DEPOSIT);

        // --- approve + deposit ---
        // NOTE the approval goes to the BoringVault, not the teller: `teller.deposit` pulls the asset via
        // `vault.enter`, which does the `transferFrom(msg.sender, vault, …)`.
        vm.startPrank(user);
        usdc.approve(address(vault), DEPOSIT);
        uint256 shares = teller.deposit(usdc, DEPOSIT, 0);
        vm.stopPrank();

        assertEq(shares, DEPOSIT, "1:1 shares at the starting rate for the pegged base asset");
        assertEq(vault.balanceOf(user), shares, "user holds the shares");
        assertEq(usdc.balanceOf(user), 0, "user spent the USDC");
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT, "vault custodies the USDC");

        // --- submit the redeem order (shares are escrowed in the queue, user gets an ERC721 receipt) ---
        uint256 orderIndex = _submitOrder(user, shares, user);

        assertEq(vault.balanceOf(user), 0, "shares moved into the queue");
        assertEq(vault.balanceOf(address(queue)), shares, "queue escrows the shares");
        assertEq(queue.ownerOf(orderIndex), user, "user holds the receipt NFT");
        assertEq(uint256(queue.getOrderStatus(orderIndex)), uint256(WithdrawQueue.OrderStatus.PENDING), "pending");

        // --- process (operator A, by role — it is not the owner) ---
        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(usdc.balanceOf(user), DEPOSIT, "user got the USDC back, zero fees configured");
        assertEq(vault.balanceOf(address(queue)), 0, "escrowed shares were burned");
        assertEq(vault.totalSupply(), 0, "no shares outstanding");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault drained to the user");
        assertEq(uint256(queue.getOrderStatus(orderIndex)), uint256(WithdrawQueue.OrderStatus.COMPLETE), "complete");
    }

    /// @notice A partial redeem leaves the rest of the position intact and redeemable later.
    function testPartialRedeemLeavesRemainder() public {
        address user = makeAddr("partial redeemer");
        uint256 shares = _deposit(user, DEPOSIT);
        uint256 half = shares / 2;

        uint256 first = _submitOrder(user, half, user);
        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(usdc.balanceOf(user), half, "half out");
        assertEq(vault.balanceOf(user), shares - half, "half of the shares still held");
        assertEq(uint256(queue.getOrderStatus(first)), uint256(WithdrawQueue.OrderStatus.COMPLETE), "first complete");

        _submitOrder(user, shares - half, user);
        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(usdc.balanceOf(user), DEPOSIT, "fully redeemed across two orders");
        assertEq(vault.balanceOf(user), 0, "no shares left");
    }

    /// @notice Two users, two orders, processed FIFO in a single `processOrders(2)` call.
    function testTwoUsersProcessedInOneBatch() public {
        // NOTE: deliberately not `makeAddr("alice")` / `makeAddr("bob")` — on a mainnet fork those two
        // addresses are real EIP-7702-delegated accounts, and the receipt-NFT `_safeMint` reverts on them.
        // See testDelegatedEoaCannotBeTheOrderReceiver below.
        address alice = makeAddr("usdc alice");
        address bob = makeAddr("usdc bob");
        uint256 aliceShares = _deposit(alice, DEPOSIT);
        uint256 bobShares = _deposit(bob, DEPOSIT / 2);

        _submitOrder(alice, aliceShares, alice);
        _submitOrder(bob, bobShares, bob);

        vm.prank(OPERATOR_A);
        queue.processOrders(2);

        assertEq(usdc.balanceOf(alice), DEPOSIT, "alice redeemed");
        assertEq(usdc.balanceOf(bob), DEPOSIT / 2, "bob redeemed");
        assertEq(queue.lastProcessedOrder(), 2, "both orders consumed");
    }

    /// @notice The redeem is priced at the rate when the order is PROCESSED, not when it is submitted.
    function testRedeemUsesRateAtProcessTime() public {
        address user = makeAddr("rate rider");
        uint256 shares = _deposit(user, DEPOSIT);
        _submitOrder(user, shares, user);

        // NAV goes up 0.04% (the configured per-update ceiling), funded by yield arriving in the vault.
        uint256 startRate = accountant.getRate();
        uint96 newRate = uint96(startRate * 10_004 / 10_000);
        deal(address(usdc), address(vault), DEPOSIT * 2); // vault must actually hold the extra assets
        vm.warp(block.timestamp + mainConfig.minimumUpdateDelayInSeconds);
        vm.prank(OPERATOR_A);
        accountant.updateExchangeRate(newRate);

        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        uint256 expected = shares * newRate / 1e6;
        assertEq(usdc.balanceOf(user), expected, "user redeemed at the post-bump rate");
        assertGt(usdc.balanceOf(user), DEPOSIT, "redeemed more than deposited");
    }

    // ===================================== LIQUIDITY / BLOCKING =====================================

    /// @notice The queue can only pay out of assets sitting in the BoringVault. If the strategy is holding
    ///         them, `processOrders` reverts with the exact shortfall and the order stays pending; once the
    ///         assets are back in the vault the same call succeeds.
    function testRedeemRevertsWhenVaultLacksLiquidityThenSucceedsOnReturn() public {
        address user = makeAddr("waiting user");
        uint256 shares = _deposit(user, DEPOSIT);
        uint256 orderIndex = _submitOrder(user, shares, user);

        // Simulate the curator having deployed the USDC into a strategy — it leaves the vault's balance.
        address strategy = makeAddr("some strategy");
        vm.prank(address(vault));
        usdc.transfer(strategy, DEPOSIT);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault is empty");

        vm.prank(OPERATOR_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawQueue.VaultInsufficientBalance.selector, IERC20(address(usdc)), DEPOSIT, uint256(0)
            )
        );
        queue.processOrders(1);

        assertEq(
            uint256(queue.getOrderStatus(orderIndex)),
            uint256(WithdrawQueue.OrderStatus.PENDING),
            "order is untouched, still pending"
        );
        assertEq(vault.balanceOf(address(queue)), shares, "shares still escrowed");

        // Curator unwinds the position; the assets land back in the vault.
        vm.prank(strategy);
        usdc.transfer(address(vault), DEPOSIT);

        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(usdc.balanceOf(user), DEPOSIT, "redeemed once liquidity returned");
    }

    /// @notice The queue is strictly FIFO: one unfillable order at the head blocks everyone behind it.
    ///         `forceProcess` (owner-only) is the escape hatch to pay a later order out of sequence.
    function testHeadOfLineBlockingAndForceProcessEscapeHatch() public {
        address blocked = makeAddr("big order");
        address behind = makeAddr("small order behind");
        uint256 bigShares = _deposit(blocked, DEPOSIT);
        uint256 smallShares = _deposit(behind, DEPOSIT / 10);

        _submitOrder(blocked, bigShares, blocked); // order 1
        uint256 second = _submitOrder(behind, smallShares, behind); // order 2

        // Pull out enough that order 1 cannot be filled, but order 2 easily could be.
        address strategy = makeAddr("strategy");
        vm.prank(address(vault));
        usdc.transfer(strategy, DEPOSIT);

        vm.prank(OPERATOR_A);
        vm.expectRevert(); // VaultInsufficientBalance on order 1 — the whole batch reverts
        queue.processOrders(2);

        assertEq(queue.lastProcessedOrder(), 0, "nothing was processed");

        // The owner force-processes order 2 out of sequence; it is marked PRE_FILLED so the FIFO loop
        // skips it when it eventually reaches that index.
        vm.prank(FINAL_OWNER);
        queue.forceProcess(second);

        assertEq(usdc.balanceOf(behind), DEPOSIT / 10, "order 2 paid out of sequence");
        assertEq(
            uint256(queue.getOrderStatus(second)),
            uint256(WithdrawQueue.OrderStatus.COMPLETE_PRE_FILLED),
            "order 2 marked pre-filled"
        );
        assertEq(usdc.balanceOf(blocked), 0, "order 1 still unpaid");
    }

    /// @notice A paused teller halts redemptions; the PAUSER_ROLE holders can unpause and resume.
    function testRedeemBlockedWhileTellerPausedThenResumes() public {
        address user = makeAddr("paused-out user");
        uint256 shares = _deposit(user, DEPOSIT);
        _submitOrder(user, shares, user);

        vm.prank(OPERATOR_A); // PAUSER_ROLE
        teller.pause();

        vm.prank(OPERATOR_A);
        vm.expectRevert(WithdrawQueue.TellerIsPaused.selector);
        queue.processOrders(1);

        // unpause() is the one capability step 13 adds to PAUSER_ROLE; without it this would be owner-only.
        vm.prank(OPERATOR_A);
        teller.unpause();

        vm.prank(OPERATOR_A);
        queue.processOrders(1);
        assertEq(usdc.balanceOf(user), DEPOSIT, "redeemed after unpause");
    }

    // ========================================= CANCEL / REFUND =========================================

    /// @notice A user can cancel their own pending order; the shares come back on the next process pass.
    function testUserCancelsOrderAndGetsSharesBack() public {
        address user = makeAddr("changed my mind");
        uint256 shares = _deposit(user, DEPOSIT);
        uint256 orderIndex = _submitOrder(user, shares, user);

        vm.prank(user);
        queue.cancelOrder(orderIndex);

        assertEq(
            uint256(queue.getOrderStatus(orderIndex)),
            uint256(WithdrawQueue.OrderStatus.PENDING_REFUND),
            "marked for refund"
        );

        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(vault.balanceOf(user), shares, "shares refunded to the user");
        assertEq(usdc.balanceOf(user), 0, "no USDC paid out");
        assertEq(
            uint256(queue.getOrderStatus(orderIndex)),
            uint256(WithdrawQueue.OrderStatus.COMPLETE_REFUNDED),
            "refund complete"
        );
    }

    /// @notice Only the order's owner may cancel it.
    function testStrangerCannotCancelSomeoneElsesOrder() public {
        address user = makeAddr("order owner");
        uint256 shares = _deposit(user, DEPOSIT);
        uint256 orderIndex = _submitOrder(user, shares, user);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        queue.cancelOrder(orderIndex);
    }

    /// @notice Orders below the configured minimum (1 USDC of shares) are rejected at submit time.
    function testOrderBelowMinimumIsRejected() public {
        address user = makeAddr("dust");
        uint256 shares = _deposit(user, DEPOSIT);
        uint256 dust = mainConfig.withdrawQueueMinimumOrderSize - 1;

        vm.startPrank(user);
        vault.approve(address(queue), shares);
        vm.expectRevert(
            abi.encodeWithSelector(
                WithdrawQueue.AmountBelowMinimum.selector, dust, mainConfig.withdrawQueueMinimumOrderSize
            )
        );
        queue.submitOrder(_orderParams(dust, user, user));
        vm.stopPrank();
    }

    /**
     * @notice A depositor whose address is a contract — including an EIP-7702-delegated EOA — cannot be the
     *         `receiver` of an order unless its code implements `onERC721Received`: the queue mints an ERC721
     *         receipt with `_safeMint`. The deposit itself works fine; only the order receipt is affected.
     * @dev    The workaround is to point `receiver` at an address that can hold the NFT. `amountOffer` is
     *         still pulled from `msg.sender`, and the payout goes to whoever owns the receipt at process time.
     */
    function testDelegatedEoaCannotBeTheOrderReceiver() public {
        // `makeAddr("alice")` is an EIP-7702-delegated account on mainnet whose delegate has no
        // onERC721Received. Skip if the fork is ever at a block before that delegation existed.
        address delegated = makeAddr("alice");
        vm.skip(delegated.code.length == 0);

        uint256 shares = _deposit(delegated, DEPOSIT);
        assertEq(vault.balanceOf(delegated), shares, "deposit itself is unaffected");

        vm.startPrank(delegated);
        vault.approve(address(queue), shares);
        vm.expectRevert(); // ERC721InvalidReceiver
        queue.submitOrder(_orderParams(shares, delegated, delegated));

        // Same order, receipt pointed at an address that can hold an NFT.
        address receipts = makeAddr("usdc receipt holder");
        uint256 orderIndex = queue.submitOrder(_orderParams(shares, delegated, receipts));
        vm.stopPrank();

        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(usdc.balanceOf(receipts), DEPOSIT, "payout follows the receipt owner");
        assertEq(usdc.balanceOf(delegated), 0, "not the share depositor");
        assertEq(uint256(queue.getOrderStatus(orderIndex)), uint256(WithdrawQueue.OrderStatus.COMPLETE), "complete");
    }

    // ================================ THE EXACT MAINNET SEQUENCE ================================

    /**
     * @notice The exact 5-call sequence to run by hand on mainnet for 100 USDC, executed raw (via `.call`
     *         with the literal calldata) rather than through typed helpers — so the encoded payloads in
     *         `deployment-config/vmUSD.md` are the ones actually exercised here.
     * @dev    Calls 1-4 are the user; call 5 is an operator holding WITHDRAW_QUEUE_PROCESSOR_ROLE. There is
     *         no deadline on a queue order — the 100 USDC can sit pending indefinitely. Run with `-vv` to
     *         print each payload.
     */
    function testExactMainnetSequenceFor100Usdc() public {
        address user = makeAddr("manual sequence user");
        uint256 amount = 100e6;
        deal(address(usdc), user, amount);

        vm.startPrank(user);

        // 1) USDC.approve(boringVault, 100e6) — the approval target is the VAULT, not the teller.
        bytes memory c1 = abi.encodeWithSignature("approve(address,uint256)", address(vault), amount);
        _rawCall(address(usdc), c1, "1 approve USDC->vault");

        // 2) teller.deposit(USDC, 100e6, 0)
        bytes memory c2 = abi.encodeWithSignature("deposit(address,uint256,uint256)", address(usdc), amount, uint256(0));
        uint256 shares = abi.decode(_rawCall(address(teller), c2, "2 teller.deposit"), (uint256));
        assertEq(shares, amount, "100 USDC -> 100 shares at the starting 1:1 rate");

        // 3) boringVault.approve(withdrawQueue, 100e6 shares)
        bytes memory c3 = abi.encodeWithSignature("approve(address,uint256)", address(queue), shares);
        _rawCall(address(vault), c3, "3 approve shares->queue");

        // 4) withdrawQueue.submitOrder(...) — intendedDepositor MUST equal msg.sender.
        bytes memory c4 = abi.encodeWithSelector(WithdrawQueue.submitOrder.selector, _orderParams(shares, user, user));
        uint256 orderIndex = abi.decode(_rawCall(address(queue), c4, "4 submitOrder"), (uint256));
        vm.stopPrank();

        assertEq(queue.ownerOf(orderIndex), user, "receipt NFT minted to the user");
        assertEq(uint256(queue.getOrderStatus(orderIndex)), uint256(WithdrawQueue.OrderStatus.PENDING), "pending");

        // 5) withdrawQueue.processOrders(1) — role 9, so NOT the user.
        bytes memory c5 = abi.encodeWithSignature("processOrders(uint256)", uint256(1));
        vm.prank(OPERATOR_A);
        _rawCall(address(queue), c5, "5 processOrders");

        assertEq(usdc.balanceOf(user), amount, "user has their 100 USDC back");
        assertEq(vault.balanceOf(user), 0, "shares burned");
    }

    /// @notice An order has no expiry: it is still processable long after submission.
    function testPendingOrderHasNoDeadline() public {
        address user = makeAddr("patient user");
        uint256 shares = _deposit(user, DEPOSIT);
        _submitOrder(user, shares, user);

        vm.warp(block.timestamp + 365 days);

        vm.prank(OPERATOR_A);
        queue.processOrders(1);
        assertEq(usdc.balanceOf(user), DEPOSIT, "processed a year later, unchanged");
    }

    /**
     * @notice The one-transaction path. `submitOrderAndProcessAll` is `requiresAuth` with no capability
     *         granted by step 10, and it reaches `processOrders` by internal JUMP (so `requiresAuth` still
     *         sees the original caller) — meaning it is effectively OWNER-ONLY.
     */
    function testOwnerCanSubmitAndProcessInOneTransaction() public {
        uint256 shares = _deposit(FINAL_OWNER, DEPOSIT);

        vm.startPrank(FINAL_OWNER);
        vault.approve(address(queue), shares);
        uint256 orderIndex = queue.submitOrderAndProcessAll(_orderParams(shares, FINAL_OWNER, FINAL_OWNER));
        vm.stopPrank();

        assertEq(usdc.balanceOf(FINAL_OWNER), DEPOSIT, "owner redeemed in a single tx");
        assertEq(
            uint256(queue.getOrderStatus(orderIndex)), uint256(WithdrawQueue.OrderStatus.COMPLETE), "order complete"
        );
    }

    /// @notice Operator A holds role 9 but is not the owner, so the one-tx combined call is closed to it —
    ///         it must use the two-call path (public `submitOrder`, then role-gated `processOrders`).
    function testRoleHolderCannotUseTheOneTxCombinedCall() public {
        uint256 shares = _deposit(OPERATOR_A, DEPOSIT);

        vm.startPrank(OPERATOR_A);
        vault.approve(address(queue), shares);
        vm.expectRevert(); // Auth: no capability for submitOrderAndProcessAll
        queue.submitOrderAndProcessAll(_orderParams(shares, OPERATOR_A, OPERATOR_A));

        // Two-call path works.
        uint256 orderIndex = queue.submitOrder(_orderParams(shares, OPERATOR_A, OPERATOR_A));
        queue.processOrders(1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(OPERATOR_A), DEPOSIT, "redeemed via the two-call path");
        assertEq(
            uint256(queue.getOrderStatus(orderIndex)), uint256(WithdrawQueue.OrderStatus.COMPLETE), "order complete"
        );
    }

    /// @notice A plain user cannot process — `processOrders` is role-gated, not public.
    function testUserCannotProcessTheirOwnOrder() public {
        address user = makeAddr("impatient user");
        uint256 shares = _deposit(user, DEPOSIT);
        _submitOrder(user, shares, user);

        vm.prank(user);
        vm.expectRevert();
        queue.processOrders(1);
    }

    // ========================================= HELPERS =========================================

    /// @dev Executes raw calldata and logs it, so the documented payloads are the tested payloads.
    function _rawCall(address target, bytes memory data, string memory label) internal returns (bytes memory ret) {
        console2.log(label);
        console2.log("  target:", target);
        console2.logBytes(data);
        bool ok;
        (ok, ret) = target.call(data);
        require(ok, string.concat("raw call failed: ", label));
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        deal(address(usdc), user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        shares = teller.deposit(usdc, amount, 0);
        vm.stopPrank();
    }

    function _submitOrder(address user, uint256 shares, address receiver) internal returns (uint256 orderIndex) {
        vm.startPrank(user);
        vault.approve(address(queue), shares);
        orderIndex = queue.submitOrder(_orderParams(shares, user, receiver));
        vm.stopPrank();
    }

    /// @dev `depositor` must equal the eventual `msg.sender` — the queue reverts `InvalidDepositor` otherwise.
    function _orderParams(
        uint256 shares,
        address depositor,
        address receiver
    )
        internal
        view
        returns (WithdrawQueue.SubmitOrderParams memory)
    {
        return WithdrawQueue.SubmitOrderParams({
            amountOffer: shares,
            wantAsset: IERC20(address(usdc)),
            intendedDepositor: depositor,
            receiver: receiver,
            refundReceiver: depositor,
            signatureParams: WithdrawQueue.SignatureParams({
                approvalMethod: WithdrawQueue.ApprovalMethod.EIP20_APPROVE,
                approvalV: 0,
                approvalR: bytes32(0),
                approvalS: bytes32(0),
                submitWithSignature: false,
                deadline: 0,
                eip2612Signature: ""
            })
        });
    }

}
