// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";
import { PredicateClient } from "@predicate/mixins/PredicateClient.sol";
import { IRedeemPolicy } from "src/interfaces/IRedeemPolicy.sol";

/**
 * @title PredicateRedeemPolicy
 * @notice An IRedeemPolicy backed by Predicate, mirroring the flag-gated KYT pattern used by
 *         DistributorCodeDepositor. When `enabled` is false the check is a no-op (ignored); when true
 *         a valid off-chain Predicate `Attestation` for (caller, receiver, shares) is required.
 * @dev Set as the BasketRedeemer's policy via `redeemer.setPolicy(this)`. The redeemer forwards the
 *      opaque `authData`, which this contract decodes as an `Attestation`.
 *
 * SECURITY: draft, unaudited. Only the configured `redeemer` may call `authorizeRedeem` so a griefer
 *      cannot pre-spend a user's single-use attestation uuid before their real redeem lands.
 */
contract PredicateRedeemPolicy is IRedeemPolicy, Auth, PredicateClient {

    /// @dev The signature Predicate's off-chain policy evaluates. Bind an attestation to exactly the
    /// (caller, receiver, shares) it authorizes.
    string public constant PREDICATE_REDEEM_SIGNATURE = "authorizeRedeem(address,address,uint256)";

    /// @notice The BasketRedeemer allowed to invoke `authorizeRedeem`.
    address public redeemer;

    /// @notice When false, `authorizeRedeem` is a no-op. Defaults to TRUE (enforced) so that wiring a
    /// policy can never silently leave redemptions permissionless; disable it explicitly to opt out.
    bool public enabled;

    event RedeemerUpdated(address indexed redeemer);
    event EnabledUpdated(bool indexed enabled);

    error ZeroAddress();
    error NotRedeemer(address caller);
    error UnauthorizedTransaction();

    constructor(address _owner, address _registry, string memory _policyID) Auth(_owner, Authority(address(0))) {
        if (_owner == address(0) || _registry == address(0)) revert ZeroAddress();
        enabled = true; // secure by default: a set policy enforces unless explicitly disabled
        _initPredicateClient(_registry, _policyID);
    }

    // ============================================ ADMIN ============================================

    function setRedeemer(address _redeemer) external requiresAuth {
        if (_redeemer == address(0)) revert ZeroAddress();
        redeemer = _redeemer;
        emit RedeemerUpdated(_redeemer);
    }

    function setEnabled(bool _enabled) external requiresAuth {
        enabled = _enabled;
        emit EnabledUpdated(_enabled);
    }

    function setPolicyID(string calldata _policyID) external requiresAuth {
        _setPolicyID(_policyID);
    }

    function setRegistry(address _registry) external requiresAuth {
        _setRegistry(_registry);
    }

    // ============================================ POLICY ==========================================

    /// @inheritdoc IRedeemPolicy
    function authorizeRedeem(address caller, address receiver, uint256 shares, bytes calldata authData) external {
        // Disabled check first: a disabled policy is a pure no-op regardless of caller, so an unset
        // `redeemer` cannot brick the "disabled" path. When enabled, only the pinned redeemer may call
        // (prevents a griefer pre-spending a user's single-use attestation uuid).
        if (!enabled) return;
        if (msg.sender != redeemer) revert NotRedeemer(msg.sender);

        Attestation memory attestation = abi.decode(authData, (Attestation));
        bytes memory encodedSigAndArgs = abi.encodeWithSignature(PREDICATE_REDEEM_SIGNATURE, caller, receiver, shares);

        // msgValue is 0: redeem/settle are non-payable. Attestation is bound to this policy contract
        // as target; the off-chain Predicate policy must be configured with this address.
        if (!_authorizeTransaction(attestation, encodedSigAndArgs, caller, 0)) {
            revert UnauthorizedTransaction();
        }
    }

}
