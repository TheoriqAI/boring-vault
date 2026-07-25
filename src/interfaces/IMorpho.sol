// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

/**
 * @title IMorpho
 * @notice Minimal Morpho Blue flash-loan interface (mainnet 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb).
 * @dev Morpho Blue flash loans are SOLO (single token) and FREE (no fee): `flashLoan` transfers `assets`
 *      of `token` to the caller, invokes `onMorphoFlashLoan(assets, data)` on it, then pulls `assets` back
 *      via `transferFrom` — so the borrower must approve this contract for `assets` before returning.
 */
interface IMorpho {

    function flashLoan(address token, uint256 assets, bytes calldata data) external;

}

/**
 * @title IMorphoFlashLoanCallback
 * @notice Callback a Morpho Blue flash-loan borrower must implement. `data` is passed through verbatim
 *         from `flashLoan`; the borrowed token is NOT included, so it must be carried inside `data`.
 */
interface IMorphoFlashLoanCallback {

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;

}
