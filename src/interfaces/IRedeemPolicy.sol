// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

/**
 * @title IRedeemPolicy
 * @notice Pluggable authorization hook for BasketRedeemer. A zero policy address means
 *         "permissionless" (the hook is skipped entirely). When set, the redeemer calls
 *         `authorizeRedeem` before a redeem/settle; the implementation MUST revert to deny.
 * @dev `authData` is opaque to the redeemer: a Predicate `Attestation`, an EIP-712 signature, or
 *      empty for list/pause/rate-limit policies. This keeps the audited redeemer policy-agnostic —
 *      swap the policy to change compliance without touching (or re-auditing) the core.
 */
interface IRedeemPolicy {

    /// @notice Reverts if this redemption/settlement is not permitted.
    /// @param caller the address invoking redeem/settleClaim (may be a keeper on settle)
    /// @param receiver the recipient of the slice (the party usually subject to KYC/sanctions checks)
    /// @param shares the total shares being redeemed / settled
    /// @param authData opaque authorization payload (attestation / signature / empty)
    function authorizeRedeem(address caller, address receiver, uint256 shares, bytes calldata authData) external;

}
