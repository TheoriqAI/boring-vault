// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { console2 } from "@forge-std/console2.sol";

import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { MultiChainLayerZeroTellerWithMultiAssetSupport } from
    "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";
import { FreezeListBeforeTransferHook } from "src/helper/FreezeListBeforeTransferHook.sol";
import "src/helper/Constants.sol";

import { BaseScript } from "script/Base.s.sol";
import { ConfigReader, IAuthority } from "script/ConfigReader.s.sol";

/// @notice Thrown when the config asks for a role that must never be held by an EOA.
error ROLE_NOT_GRANTABLE_TO_EOA(uint256 role);

/**
 * @notice Post-deploy step: grants the operator roles listed in `postDeploy` of the deployment config to
 *         every address in `postDeploy.additionalRoleUsers`, then (optionally) hands ownership of the whole
 *         system over to `postDeploy.finalOwner`.
 * @dev    Runs AFTER `11_SetAuthorityAndTransferOwnerships`, so at entry the owner of every contract is
 *         `config.protocolAdmin`. Every call made here is `requiresAuth` and passes only because
 *         solmate's `Auth.isAuthorized` short-circuits for the owner — which is why this script requires
 *         `broadcaster == config.protocolAdmin`. If the protocol admin is a multisig, do NOT run this
 *         script: execute the logged calls from the multisig instead.
 *
 *         Role grants happen before any ownership transfer, and the `RolesAuthority` hand-off is last, so
 *         the script never locks itself out mid-way.
 */
contract GrantRolesAndFinalizeOwner is BaseScript {

    using StdJson for string;

    /// @notice Roles this script is willing to hand to an externally owned account.
    /// @dev    MANAGER_ROLE (2) and TELLER_ROLE (3) are deliberately excluded: MANAGER_ROLE can call
    ///         `BoringVault.manage` with arbitrary calldata (i.e. drain the vault) and TELLER_ROLE can
    ///         mint/burn shares. Both belong to contracts only. DEPOSITOR_ROLE (7) belongs to the
    ///         DistributorCodeDepositor and SELF_BURN_ROLE (8) is unused by this pipeline.
    function _isGrantableRole(uint256 role) internal pure returns (bool) {
        return role == STRATEGIST_ROLE || role == UPDATE_EXCHANGE_RATE_ROLE || role == SOLVER_ROLE
            || role == PAUSER_ROLE || role == WITHDRAW_QUEUE_PROCESSOR_ROLE || role == FREEZE_MANAGER_ROLE;
    }

    /**
     * @notice Standalone entrypoint. `deployFile` is the deployment config under `deployment-config/`;
     *         the already-deployed addresses are read from `deployment-config/out.json`.
     */
    function run(string memory deployFile) public {
        string memory json = vm.readFile(string.concat(CONFIG_PATH_ROOT, deployFile));
        ConfigReader.Config memory config = ConfigReader.toConfig(json, getChainConfigFile());

        string memory out = vm.readFile("./deployment-config/out.json");
        config.boringVault = out.readAddress(".boringVault");
        config.manager = out.readAddress(".manager");
        config.accountant = out.readAddress(".accountant");
        config.teller = out.readAddress(".teller");
        config.rolesAuthority = out.readAddress(".rolesAuthority");
        config.freezeListBeforeTransferHook = out.readAddress(".freezeListBeforeTransferHook");
        config.withdrawQueue = out.readAddress(".withdrawQueue");

        grant(config, json);
    }

    /**
     * @notice Chained entrypoint, called by `deployAllWithRoleGrants` with the in-memory config.
     * @param config The fully-populated config (all `address` fields already point at live contracts).
     * @param json   The raw deployment-config JSON, re-read so the `postDeploy` section can be parsed.
     */
    function grant(ConfigReader.Config memory config, string memory json) public broadcast {
        require(broadcaster == config.protocolAdmin, "13: broadcaster must be the protocolAdmin (current owner)");

        require(config.rolesAuthority.code.length != 0, "13: rolesAuthority must have code");
        require(config.withdrawQueue.code.length != 0, "13: withdrawQueue must have code");
        require(config.freezeListBeforeTransferHook.code.length != 0, "13: freeze hook must have code");

        RolesAuthority rolesAuthority = RolesAuthority(config.rolesAuthority);
        require(IAuthority(config.rolesAuthority).owner() == broadcaster, "13: not the rolesAuthority owner");

        address[] memory users = json.readAddressArray(".postDeploy.additionalRoleUsers");
        uint256[] memory roles = json.readUintArray(".postDeploy.roles");
        require(users.length != 0, "13: postDeploy.additionalRoleUsers must not be empty");
        require(roles.length != 0, "13: postDeploy.roles must not be empty");

        // --- Extra role capabilities (deviations from the stock 07/10 role table, opt-in via config) ---

        // `unpause` has no role capability in 07, so out of the box only the owner can un-pause. Without this
        // the PAUSER_ROLE holders can halt the system but cannot restart it.
        if (json.readBool(".postDeploy.grantUnpauseToPauserRole")) {
            rolesAuthority.setRoleCapability(
                PAUSER_ROLE, config.teller, TellerWithMultiAssetSupport.unpause.selector, true
            );
            rolesAuthority.setRoleCapability(
                PAUSER_ROLE, config.accountant, AccountantWithRateProviders.unpause.selector, true
            );
            rolesAuthority.setRoleCapability(
                PAUSER_ROLE, config.manager, ManagerWithMerkleVerification.unpause.selector, true
            );
            console2.log("13: PAUSER_ROLE granted unpause() on teller/accountant/manager");
        }

        // 10 only gives the processor `processOrders`. These let it also force/refund individual orders.
        if (json.readBool(".postDeploy.grantQueueAdminToProcessorRole")) {
            rolesAuthority.setRoleCapability(
                WITHDRAW_QUEUE_PROCESSOR_ROLE, config.withdrawQueue, WithdrawQueue.forceProcessOrders.selector, true
            );
            rolesAuthority.setRoleCapability(
                WITHDRAW_QUEUE_PROCESSOR_ROLE, config.withdrawQueue, WithdrawQueue.forceProcess.selector, true
            );
            rolesAuthority.setRoleCapability(
                WITHDRAW_QUEUE_PROCESSOR_ROLE, config.withdrawQueue, WithdrawQueue.refundOrder.selector, true
            );
            rolesAuthority.setRoleCapability(
                WITHDRAW_QUEUE_PROCESSOR_ROLE, config.withdrawQueue, WithdrawQueue.refundOrders.selector, true
            );
            console2.log("13: WITHDRAW_QUEUE_PROCESSOR_ROLE granted force/refund on the withdraw queue");
        }

        // --- Grant every requested role to every requested user ---

        for (uint256 r; r < roles.length; ++r) {
            if (!_isGrantableRole(roles[r])) revert ROLE_NOT_GRANTABLE_TO_EOA(roles[r]);
            for (uint256 u; u < users.length; ++u) {
                require(users[u] != address(0), "13: role user must not be zero address");
                rolesAuthority.setUserRole(users[u], uint8(roles[r]), true);
                console2.log("13: granted role", roles[r], "to", users[u]);
            }
        }

        // --- Post-grant checks: the role bit is set AND the role actually reaches a real selector ---

        for (uint256 r; r < roles.length; ++r) {
            for (uint256 u; u < users.length; ++u) {
                require(rolesAuthority.doesUserHaveRole(users[u], uint8(roles[r])), "13: role not set");
                _assertRoleIsUsable(config, rolesAuthority, users[u], roles[r]);
            }
        }

        // --- Hand the system over to the final owner ---

        address finalOwner = json.readAddress(".postDeploy.finalOwner");
        if (finalOwner == address(0) || finalOwner == config.protocolAdmin) {
            console2.log("13: no finalOwner change requested; owner stays", config.protocolAdmin);
            return;
        }
        _transferOwnership(config, finalOwner);
    }

    /// @dev Confirms the granted role resolves to a capability, so a role number that was granted but has no
    ///      `setRoleCapability` behind it (i.e. a silently useless grant) fails the deploy.
    function _assertRoleIsUsable(
        ConfigReader.Config memory config,
        RolesAuthority rolesAuthority,
        address user,
        uint256 role
    )
        internal
        view
    {
        if (role == STRATEGIST_ROLE) {
            require(
                rolesAuthority.canCall(
                    user, config.manager, ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector
                ),
                "13: STRATEGIST_ROLE cannot manageVaultWithMerkleVerification"
            );
        } else if (role == UPDATE_EXCHANGE_RATE_ROLE) {
            require(
                rolesAuthority.canCall(user, config.accountant, AccountantWithRateProviders.updateExchangeRate.selector),
                "13: UPDATE_EXCHANGE_RATE_ROLE cannot updateExchangeRate"
            );
        } else if (role == SOLVER_ROLE) {
            require(
                rolesAuthority.canCall(user, config.teller, TellerWithMultiAssetSupport.bulkWithdraw.selector),
                "13: SOLVER_ROLE cannot bulkWithdraw"
            );
        } else if (role == PAUSER_ROLE) {
            require(
                rolesAuthority.canCall(user, config.teller, TellerWithMultiAssetSupport.pause.selector)
                    && rolesAuthority.canCall(user, config.accountant, AccountantWithRateProviders.pause.selector)
                    && rolesAuthority.canCall(user, config.manager, ManagerWithMerkleVerification.pause.selector),
                "13: PAUSER_ROLE cannot pause the system"
            );
        } else if (role == WITHDRAW_QUEUE_PROCESSOR_ROLE) {
            require(
                rolesAuthority.canCall(user, config.withdrawQueue, WithdrawQueue.processOrders.selector),
                "13: WITHDRAW_QUEUE_PROCESSOR_ROLE cannot processOrders"
            );
        } else if (role == FREEZE_MANAGER_ROLE) {
            require(
                rolesAuthority.canCall(
                    user, config.freezeListBeforeTransferHook, FreezeListBeforeTransferHook.setFreezeList.selector
                ),
                "13: FREEZE_MANAGER_ROLE cannot setFreezeList"
            );
        }
    }

    /// @dev Transfers every owned contract to `finalOwner`. The `RolesAuthority` goes last so that an early
    ///      revert leaves the admin still able to finish the job.
    function _transferOwnership(ConfigReader.Config memory config, address finalOwner) internal {
        address feeModule = address(WithdrawQueue(config.withdrawQueue).feeModule());
        require(feeModule.code.length != 0, "13: withdraw queue fee module must have code");

        // The LayerZero delegate (endpoint config authority) is independent of Auth ownership and was pointed at
        // the protocol admin in 06b. Move it with the owner, or the old admin keeps endpoint-config rights.
        if (compareStrings(config.tellerContractName, "MultiChainLayerZeroTellerWithMultiAssetSupport")) {
            MultiChainLayerZeroTellerWithMultiAssetSupport(config.teller).setDelegate(finalOwner);
            console2.log("13: LayerZero delegate moved to", finalOwner);
        }

        IAuthority(config.boringVault).transferOwnership(finalOwner);
        IAuthority(config.manager).transferOwnership(finalOwner);
        IAuthority(config.accountant).transferOwnership(finalOwner);
        IAuthority(config.teller).transferOwnership(finalOwner);
        IAuthority(config.withdrawQueue).transferOwnership(finalOwner);
        IAuthority(feeModule).transferOwnership(finalOwner);
        IAuthority(config.freezeListBeforeTransferHook).transferOwnership(finalOwner);
        IAuthority(config.rolesAuthority).transferOwnership(finalOwner);

        require(IAuthority(config.boringVault).owner() == finalOwner, "13: boringVault owner");
        require(IAuthority(config.manager).owner() == finalOwner, "13: manager owner");
        require(IAuthority(config.accountant).owner() == finalOwner, "13: accountant owner");
        require(IAuthority(config.teller).owner() == finalOwner, "13: teller owner");
        require(IAuthority(config.withdrawQueue).owner() == finalOwner, "13: withdrawQueue owner");
        require(IAuthority(feeModule).owner() == finalOwner, "13: fee module owner");
        require(IAuthority(config.freezeListBeforeTransferHook).owner() == finalOwner, "13: freeze hook owner");
        require(IAuthority(config.rolesAuthority).owner() == finalOwner, "13: rolesAuthority owner");

        console2.log("13: ownership of the full system transferred to", finalOwner);
    }

}
