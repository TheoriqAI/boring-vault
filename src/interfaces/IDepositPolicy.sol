// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

/**
 * @title IDepositPolicy
 * @notice Pluggable authorization hook for EpochDepositor (the deposit-side mirror of IRedeemPolicy).
 *         A zero policy address means "permissionless" (the hook is skipped entirely). When set, the
 *         depositor calls `authorizeDeposit` before accepting a request; the implementation MUST revert
 *         to deny.
 * @dev `authData` is opaque to the depositor: a Predicate `Attestation`, an EIP-712 signature, or empty
 *      for list/pause/rate-limit policies. This keeps the (audited) depositor policy-agnostic — swap the
 *      policy to change compliance without touching or re-auditing the core.
 */
interface IDepositPolicy {

    /// @notice Reverts if this deposit request is not permitted.
    /// @param caller the address invoking the request (may be an ERC-7540 operator)
    /// @param controller the party the request is credited to (usually subject to KYC/sanctions checks)
    /// @param assets the amount of asset being deposited into the epoch
    /// @param authData opaque authorization payload (attestation / signature / empty)
    function authorizeDeposit(address caller, address controller, uint256 assets, bytes calldata authData) external;

}
