// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, console } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { IERC20 } from "src/interfaces/IFeeModule.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import "src/helper/Constants.sol";

import { DeployAllWithRoleGrants } from "script/deploy/deployAllWithRoleGrants.s.sol";
import { IAuthority } from "script/ConfigReader.s.sol";
import { VmUsdForkBase } from "test/VmUsdForkBase.sol";

/**
 * @notice Fork test for the `vmUSD` mainnet deploy: proves that after `deployAllWithRoleGrants`
 *         both operator addresses hold every configured role and that the final owner owns the system.
 * @dev    Requires a mainnet RPC in `L1_RPC_URL`, `CREATEX`, and
 *         `OVERRIDE_PROTOCOL_ADMIN=ETH_FROM=0xA072…3631` (the deploy-time admin). Run with:
 *           LIVE_DEPLOY_READ_FILE_NAME=vmUSD.json \
 *             forge test --mp test/VmUsdRolesAndOwnership.t.sol --fork-url $L1_RPC_URL
 */
contract VmUsdRolesAndOwnership is VmUsdForkBase, DeployAllWithRoleGrants {

    address constant OPERATOR_A = 0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631;
    address constant OPERATOR_B = 0xCB068924bb3D2Ebb28BD1BB25b09ec15b0D5a03B;
    address constant FINAL_OWNER = OPERATOR_B;

    /// @dev Every role the config hands to the two operator addresses.
    uint8[6] ROLES = [
        STRATEGIST_ROLE,
        UPDATE_EXCHANGE_RATE_ROLE,
        SOLVER_ROLE,
        PAUSER_ROLE,
        WITHDRAW_QUEUE_PROCESSOR_ROLE,
        FREEZE_MANAGER_ROLE
    ];

    RolesAuthority rolesAuthority;
    WithdrawQueue withdrawQueue;

    function setUp() public {
        string memory file = _liveFileOrSkip();
        if (!liveEnvSet) return;

        runLiveTestWithRoleGrants(file);

        rolesAuthority = RolesAuthority(mainConfig.rolesAuthority);
        withdrawQueue = WithdrawQueue(mainConfig.withdrawQueue);
    }

    /// @notice Both operator addresses hold every configured role.
    function testBothOperatorsHoldEveryRole() public view {
        address[2] memory operators = [OPERATOR_A, OPERATOR_B];
        for (uint256 i; i < operators.length; ++i) {
            for (uint256 r; r < ROLES.length; ++r) {
                assertTrue(
                    rolesAuthority.doesUserHaveRole(operators[i], ROLES[r]),
                    string.concat("operator ", vm.toString(operators[i]), " missing a role")
                );
            }
        }
    }

    /// @notice The role grants actually reach the selectors the operators need day to day.
    function testBothOperatorsCanCallTheirSelectors() public view {
        address[2] memory operators = [OPERATOR_A, OPERATOR_B];
        for (uint256 i; i < operators.length; ++i) {
            address op = operators[i];

            // curator
            assertTrue(
                rolesAuthority.canCall(
                    op, mainConfig.manager, ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector
                ),
                "curator: manageVaultWithMerkleVerification"
            );
            // nav update
            assertTrue(
                rolesAuthority.canCall(
                    op, mainConfig.accountant, AccountantWithRateProviders.updateExchangeRate.selector
                ),
                "nav: updateExchangeRate"
            );
            // withdrawals
            assertTrue(
                rolesAuthority.canCall(op, mainConfig.withdrawQueue, WithdrawQueue.processOrders.selector),
                "queue: processOrders"
            );
            assertTrue(
                rolesAuthority.canCall(op, mainConfig.teller, TellerWithMultiAssetSupport.bulkWithdraw.selector),
                "solver: bulkWithdraw"
            );
            // pause + unpause (unpause is the one opt-in deviation from the stock 07 role table)
            assertTrue(
                rolesAuthority.canCall(op, mainConfig.teller, TellerWithMultiAssetSupport.pause.selector),
                "pauser: teller.pause"
            );
            assertTrue(
                rolesAuthority.canCall(op, mainConfig.teller, TellerWithMultiAssetSupport.unpause.selector),
                "pauser: teller.unpause"
            );
            assertTrue(
                rolesAuthority.canCall(op, mainConfig.accountant, AccountantWithRateProviders.pause.selector),
                "pauser: accountant.pause"
            );
            assertTrue(
                rolesAuthority.canCall(op, mainConfig.manager, ManagerWithMerkleVerification.pause.selector),
                "pauser: manager.pause"
            );
            // freeze list
            assertTrue(
                rolesAuthority.canCall(
                    op, mainConfig.freezeListBeforeTransferHook, FreezeListBeforeTransferHook.setFreezeList.selector
                ),
                "freeze: setFreezeList"
            );
        }
    }

    /// @notice Nothing dangerous leaked: the operator EOAs must not be able to move vault funds directly.
    function testOperatorsDoNotHoldContractOnlyRoles() public view {
        address[2] memory operators = [OPERATOR_A, OPERATOR_B];
        for (uint256 i; i < operators.length; ++i) {
            assertFalse(rolesAuthority.doesUserHaveRole(operators[i], MANAGER_ROLE), "must not hold MANAGER_ROLE");
            assertFalse(rolesAuthority.doesUserHaveRole(operators[i], TELLER_ROLE), "must not hold TELLER_ROLE");
            assertFalse(
                rolesAuthority.canCall(
                    operators[i], mainConfig.boringVault, bytes4(keccak256("manage(address,bytes,uint256)"))
                ),
                "must not be able to call BoringVault.manage"
            );
        }
    }

    /**
     * @notice Depositing and the user-facing queue calls are PUBLIC (no role needed) — step 07 sets a public
     *         capability for `teller.deposit` because `distributorCodeDepositor.deploy` is false, and step 10
     *         does the same for `submitOrder` / `cancelOrder` / `cancelOrderWithSignature`.
     * @dev    `depositAndBridge` is deliberately NOT public (see the comment in 07); it is unreachable today
     *         anyway because no LayerZero peer is wired.
     */
    function testDepositAndQueueEntryArePublic() public view {
        address anyone = address(0xBEEF); // any address with no roles at all

        assertTrue(
            rolesAuthority.canCall(anyone, mainConfig.teller, TellerWithMultiAssetSupport.deposit.selector),
            "teller.deposit must be public"
        );
        assertTrue(
            rolesAuthority.canCall(anyone, mainConfig.withdrawQueue, WithdrawQueue.submitOrder.selector),
            "withdrawQueue.submitOrder must be public"
        );
        assertTrue(
            rolesAuthority.canCall(anyone, mainConfig.withdrawQueue, WithdrawQueue.cancelOrder.selector),
            "withdrawQueue.cancelOrder must be public"
        );
        assertTrue(
            rolesAuthority.canCall(anyone, mainConfig.withdrawQueue, WithdrawQueue.cancelOrderWithSignature.selector),
            "withdrawQueue.cancelOrderWithSignature must be public"
        );

        // Processing is NOT public — it stays behind WITHDRAW_QUEUE_PROCESSOR_ROLE.
        assertFalse(
            rolesAuthority.canCall(anyone, mainConfig.withdrawQueue, WithdrawQueue.processOrders.selector),
            "processOrders must not be public"
        );
    }

    /// @notice Every contract in the system is owned by the final owner, and the deploy admin no longer is.
    function testFinalOwnerOwnsEverything() public view {
        address feeModule = address(withdrawQueue.feeModule());
        address[8] memory owned = [
            mainConfig.boringVault,
            mainConfig.manager,
            mainConfig.accountant,
            mainConfig.teller,
            mainConfig.withdrawQueue,
            mainConfig.rolesAuthority,
            mainConfig.freezeListBeforeTransferHook,
            feeModule
        ];
        for (uint256 i; i < owned.length; ++i) {
            assertEq(IAuthority(owned[i]).owner(), FINAL_OWNER, "owner must be the final owner");
        }
        assertTrue(FINAL_OWNER != OPERATOR_A, "sanity: the two addresses differ");
    }

    /// @notice The authority wiring survived the ownership hand-off.
    function testAuthorityStillPointsAtRolesAuthority() public view {
        assertEq(address(BoringVault(payable(mainConfig.boringVault)).authority()), mainConfig.rolesAuthority);
        assertEq(address(TellerWithMultiAssetSupport(mainConfig.teller).authority()), mainConfig.rolesAuthority);
        assertEq(address(AccountantWithRateProviders(mainConfig.accountant).authority()), mainConfig.rolesAuthority);
        assertEq(address(ManagerWithMerkleVerification(mainConfig.manager).authority()), mainConfig.rolesAuthority);
        assertEq(address(withdrawQueue.authority()), mainConfig.rolesAuthority);
    }

    /// @notice The nav-update role works from the non-owner operator (i.e. it is the role, not ownership).
    function testNonOwnerOperatorCanUpdateRate() public {
        AccountantWithRateProviders accountant = AccountantWithRateProviders(mainConfig.accountant);
        vm.warp(block.timestamp + mainConfig.minimumUpdateDelayInSeconds);

        uint96 newRate = uint96(accountant.getRate()) * 10_002 / 10_000;
        vm.prank(OPERATOR_A); // no longer the owner — only the role can authorize this
        accountant.updateExchangeRate(newRate);

        assertEq(accountant.getRate(), newRate, "rate should have been updated by the role holder");
        (,,,,,,,, bool isPaused,,,) = accountant.accountantState();
        assertFalse(isPaused, "accountant should not have paused on an in-bounds rate change");
    }

    /// @notice Full redeem path through the audited WithdrawQueue, processed by the non-owner operator.
    function testWithdrawQueueRedeemProcessedByNonOwnerOperator() public {
        ERC20 usdc = ERC20(mainConfig.base);
        BoringVault vault = BoringVault(payable(mainConfig.boringVault));
        uint256 depositAmount = 10_000e6; // 10,000 USDC, well above the 1 USDC minimum order size

        address user = makeAddr("usdc depositor");
        deal(address(usdc), user, depositAmount);

        vm.startPrank(user);
        usdc.approve(mainConfig.boringVault, depositAmount);
        uint256 shares = TellerWithMultiAssetSupport(mainConfig.teller).deposit(usdc, depositAmount, 0);
        assertEq(shares, depositAmount, "1:1 shares for the pegged base asset");

        vault.approve(mainConfig.withdrawQueue, shares);
        uint256 orderIndex = withdrawQueue.submitOrder(
            WithdrawQueue.SubmitOrderParams({
                amountOffer: shares,
                wantAsset: IERC20(address(usdc)),
                intendedDepositor: user,
                receiver: user,
                refundReceiver: user,
                signatureParams: WithdrawQueue.SignatureParams({
                    approvalMethod: WithdrawQueue.ApprovalMethod.EIP20_APPROVE,
                    approvalV: 0,
                    approvalR: bytes32(0),
                    approvalS: bytes32(0),
                    submitWithSignature: false,
                    deadline: 0,
                    eip2612Signature: ""
                })
            })
        );
        vm.stopPrank();

        assertEq(
            uint256(withdrawQueue.getOrderStatus(orderIndex)),
            uint256(WithdrawQueue.OrderStatus.PENDING),
            "order should be pending"
        );

        // OPERATOR_A is not the owner anymore; this only succeeds via WITHDRAW_QUEUE_PROCESSOR_ROLE.
        vm.prank(OPERATOR_A);
        withdrawQueue.processOrders(1);

        assertEq(
            uint256(withdrawQueue.getOrderStatus(orderIndex)),
            uint256(WithdrawQueue.OrderStatus.COMPLETE),
            "order should be complete"
        );

        assertEq(usdc.balanceOf(user), depositAmount, "user should have the USDC back (zero fees configured)");
        assertEq(vault.balanceOf(user), 0, "shares should be burned");
    }

    /// @notice An address holding neither a role nor ownership cannot drive the system.
    function testRandomAddressCannotOperate() public {
        address stranger = makeAddr("stranger");

        vm.startPrank(stranger);
        vm.expectRevert();
        AccountantWithRateProviders(mainConfig.accountant).updateExchangeRate(1e6);
        vm.expectRevert();
        withdrawQueue.processOrders(1);
        vm.expectRevert();
        TellerWithMultiAssetSupport(mainConfig.teller).pause();
        vm.stopPrank();
    }

}
