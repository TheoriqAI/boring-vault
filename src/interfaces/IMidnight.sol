// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

/**
 * @title IMidnight
 * @notice Flash-loan interface for the Morpho "Midnight" protocol.
 * @dev MULTI-token and FREE (no fee): `flashLoan` sends each `assets[i]` of `tokens[i]` to the `callback`
 *      contract (NOT to msg.sender), invokes `onFlashLoan(msg.sender, tokens, assets, data)` on it — which
 *      must return CALLBACK_SUCCESS — then pulls each amount back from the callback via `transferFrom`
 *      (so the callback must approve this contract for each `assets[i]` before returning). `tokens` and
 *      `assets` are parallel arrays (equal length or it reverts). Midnight can only lend what it currently
 *      holds, so a fresh bilateral market has little free liquidity — size accordingly.
 * @custom:security-contact security@theoriq.ai
 */
interface IMidnight {

    function flashLoan(
        address[] calldata tokens,
        uint256[] calldata assets,
        address callback,
        bytes calldata data
    )
        external;

}

/**
 * @title IMidnightFlashLoanCallback
 * @notice Callback a Midnight flash-loan `callback` contract must implement.
 * @dev Must return keccak256("morpho.midnight.callbackSuccess") or Midnight reverts
 *      `WrongFlashLoanCallbackReturnValue()`. `caller` is the original initiator (msg.sender of flashLoan).
 */
interface IMidnightFlashLoanCallback {

    function onFlashLoan(
        address caller,
        address[] calldata tokens,
        uint256[] calldata assets,
        bytes calldata data
    )
        external
        returns (bytes32);

}
