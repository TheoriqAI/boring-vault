// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/// @dev EVC batch item — ABI tuple (address,address,uint256,bytes). `targetContract` is the EVC or an eVault.
struct BatchItem {
    address targetContract;
    address onBehalfOfAccount;
    uint256 value;
    bytes data;
}

/**
 * @title EulerDecoderAndSanitizer
 * @notice Decoder & sanitizer for Euler v2 (EVK/EVC). Covers the full operation set: EVC collateral/
 *         controller management, eVault borrow/repay/pullDebt, and the EVC `batch` (multi-item), whose
 *         sub-calls are decoded and sanitized inline.
 * @dev The eVault ERC-4626 ops (deposit/mint/withdraw/redeem) share selectors with the standard
 *      ERC4626DecoderAndSanitizer; sanitize DIRECT eVault deposit/withdraw by combining this with that
 *      decoder. They ARE handled here when they appear inside a `batch` sub-call. Every account/receiver/
 *      owner that should be the vault is required to equal `boringVault`; the eVault/EVC target itself is
 *      pinned by the merkle leaf.
 */
abstract contract EulerDecoderAndSanitizer is BaseDecoderAndSanitizer {

    error EulerDecoderAndSanitizer__BoringVaultOnly();
    error EulerDecoderAndSanitizer__InvalidSelector();

    // Euler v2 selectors (see cast sig)
    bytes4 private constant ENABLE_COLLATERAL = 0xd44fee5a; // enableCollateral(address,address)
    bytes4 private constant DISABLE_COLLATERAL = 0xe920e8e0; // disableCollateral(address,address)
    bytes4 private constant ENABLE_CONTROLLER = 0xc368516c; // enableController(address,address)
    bytes4 private constant DISABLE_CONTROLLER_EVC = 0xf4fc3570; // disableController(address)  [EVC]
    bytes4 private constant DEPOSIT = 0x6e553f65; // deposit(uint256,address)
    bytes4 private constant MINT = 0x94bf804d; // mint(uint256,address)
    bytes4 private constant WITHDRAW = 0xb460af94; // withdraw(uint256,address,address)
    bytes4 private constant REDEEM = 0xba087652; // redeem(uint256,address,address)
    bytes4 private constant BORROW = 0x4b3fd148; // borrow(uint256,address)
    bytes4 private constant REPAY = 0xacb70815; // repay(uint256,address)
    bytes4 private constant REPAY_WITH_SHARES = 0xa9c8eb7e; // repayWithShares(uint256,address)
    bytes4 private constant PULL_DEBT = 0xaebde56b; // pullDebt(uint256,address)
    bytes4 private constant DISABLE_CONTROLLER_VAULT = 0x869e50c7; // disableController()  [eVault]

    //============================== EVC ===============================

    // @desc enable a collateral vault on the EVC for the boring vault account
    // @tag vault:address:the collateral eVault
    function enableCollateral(address account, address vault) external view virtual returns (bytes memory) {
        return _evcCollateralOrController(account, vault);
    }

    // @desc disable a collateral vault on the EVC for the boring vault account
    // @tag vault:address:the collateral eVault
    function disableCollateral(address account, address vault) external view virtual returns (bytes memory) {
        return _evcCollateralOrController(account, vault);
    }

    // @desc enable a controller vault on the EVC for the boring vault account
    // @tag vault:address:the controller eVault
    function enableController(address account, address vault) external view virtual returns (bytes memory) {
        return _evcCollateralOrController(account, vault);
    }

    // @desc disable the controller on the EVC for the boring vault account (EVC variant, takes the account)
    function disableController(address account) external view virtual returns (bytes memory) {
        if (account != boringVault) revert EulerDecoderAndSanitizer__BoringVaultOnly();
        return "";
    }

    //============================== EVAULT ===============================

    // @desc borrow from an eVault to the boring vault
    function borrow(uint256, address receiver) external view virtual returns (bytes memory) {
        return _requireVault(receiver);
    }

    // @desc repay an eVault debt for the boring vault
    function repay(uint256, address receiver) external view virtual returns (bytes memory) {
        return _requireVault(receiver);
    }

    // @desc repay an eVault debt using the boring vault's shares
    function repayWithShares(uint256, address receiver) external view virtual returns (bytes memory) {
        return _requireVault(receiver);
    }

    // @desc pull (take over) another account's debt into the boring vault
    // @tag from:address:the account whose debt is pulled
    function pullDebt(uint256, address from) external pure virtual returns (bytes memory) {
        return abi.encodePacked(from);
    }

    // @desc disable the controller on the eVault (eVault variant, no args)
    function disableController() external pure virtual returns (bytes memory) {
        return "";
    }

    //============================== BATCH ===============================

    // @desc batch actions on Euler via the EVC; each sub-call is decoded and sanitized inline
    // @tag packedArgs:bytes:per item — targetContract, value, then the sub-call's sanitized addresses
    function batch(BatchItem[] calldata items) external view virtual returns (bytes memory addressesFound) {
        for (uint256 i; i < items.length; ++i) {
            if (items[i].onBehalfOfAccount != boringVault) revert EulerDecoderAndSanitizer__BoringVaultOnly();
            addressesFound = abi.encodePacked(
                addressesFound, items[i].targetContract, items[i].value, _sanitizeEulerCall(items[i].data)
            );
        }
    }

    //============================== INTERNAL ===============================

    function _evcCollateralOrController(address account, address vault) internal view returns (bytes memory) {
        if (account != boringVault) revert EulerDecoderAndSanitizer__BoringVaultOnly();
        return abi.encodePacked(vault);
    }

    function _requireVault(address receiver) internal view returns (bytes memory) {
        if (receiver != boringVault) revert EulerDecoderAndSanitizer__BoringVaultOnly();
        return "";
    }

    /// @dev Decodes and sanitizes one EVC-batch sub-call, returning the same packed addresses the direct
    ///      entrypoints would. Reverts on any selector not in the Euler op set.
    function _sanitizeEulerCall(bytes calldata data) internal view returns (bytes memory found) {
        bytes4 selector;
        /// @solidity memory-safe-assembly
        assembly {
            selector := calldataload(data.offset)
        }
        bytes calldata args = data[4:];

        if (selector == ENABLE_COLLATERAL || selector == DISABLE_COLLATERAL || selector == ENABLE_CONTROLLER) {
            (address account, address vault) = abi.decode(args, (address, address));
            found = _evcCollateralOrController(account, vault);
        } else if (selector == DISABLE_CONTROLLER_EVC) {
            address account = abi.decode(args, (address));
            if (account != boringVault) revert EulerDecoderAndSanitizer__BoringVaultOnly();
        } else if (
            selector == DEPOSIT || selector == MINT || selector == BORROW || selector == REPAY
                || selector == REPAY_WITH_SHARES
        ) {
            (, address receiver) = abi.decode(args, (uint256, address));
            found = _requireVault(receiver);
        } else if (selector == WITHDRAW || selector == REDEEM) {
            (, address receiver, address owner) = abi.decode(args, (uint256, address, address));
            if (receiver != boringVault || owner != boringVault) revert EulerDecoderAndSanitizer__BoringVaultOnly();
        } else if (selector == PULL_DEBT) {
            (, address from) = abi.decode(args, (uint256, address));
            found = abi.encodePacked(from);
        } else if (selector == DISABLE_CONTROLLER_VAULT) {
            // no args
        } else {
            revert EulerDecoderAndSanitizer__InvalidSelector();
        }
    }

}
