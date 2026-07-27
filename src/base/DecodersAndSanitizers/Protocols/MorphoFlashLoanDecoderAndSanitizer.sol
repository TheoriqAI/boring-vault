// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

/**
 * @title MorphoFlashLoanDecoderAndSanitizer
 * @notice Decoder & sanitizer for the `morphoFlashLoan` initiator on
 *         ManagerWithMerkleAndTokenBalanceVerification. Because the flash-loan provider is passed as an
 *         argument (not immutable), the merkle leaf pins BOTH the `morphoProvider` and the `token`, so the
 *         strategist can only flash-loan the authorized token from an authorized Morpho deployment.
 * @dev The `userData` blob is intentionally not decoded here: every strategy call it carries is
 *      re-verified against the merkle root when the callback re-enters `manageVaultWithMerkleVerification`.
 * @custom:security-contact security@theoriq.ai
 */
abstract contract MorphoFlashLoanDecoderAndSanitizer is BaseDecoderAndSanitizer {

    //============================== MORPHO FLASH LOAN ===============================

    // @desc initiate a Morpho flash loan through the manager
    // @tag morphoProvider:address:the Morpho deployment to borrow from
    // @tag token:address:the token to flash-borrow
    function morphoFlashLoan(
        address morphoProvider,
        address token,
        uint256,
        bytes calldata
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(morphoProvider, token);
    }

    // @desc initiate a Morpho "Midnight" (multi-token) flash loan through the manager
    // @tag midnightProvider:address:the Midnight deployment to borrow from
    // @tag tokens:address:each token to flash-borrow
    function midnightFlashLoan(
        address midnightProvider,
        address[] calldata tokens,
        uint256[] calldata,
        bytes calldata
    )
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(midnightProvider);
        for (uint256 i; i < tokens.length; ++i) {
            addressesFound = abi.encodePacked(addressesFound, tokens[i]);
        }
    }

}
