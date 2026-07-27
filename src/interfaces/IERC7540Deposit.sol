// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

/**
 * @title IERC7540Deposit
 * @notice The asynchronous-deposit subset of ERC-7540 (Asynchronous ERC-4626 Tokenized Vaults), plus the
 *         operator model and the request-cancel extension, as implemented by EpochDepositor.
 * @dev requestId maps to the epoch id. A request moves through: pending (open epoch) -> claimable
 *      (epoch settled) -> claimed (`deposit`/`mint`). `owner` provides the assets; `controller` owns the
 *      request and its resulting shares; an approved operator may act for a controller.
 */
interface IERC7540Deposit {

    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /// @notice Transfers `assets` from `owner` into a pending deposit request credited to `controller`.
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);

    /// @notice Assets in requests that have not yet been fulfilled (epoch not settled).
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);

    /// @notice Assets in requests that have been fulfilled (epoch settled) and are claimable as shares.
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);

    /// @notice Claims shares for a fulfilled request by asset amount.
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);

    /// @notice Claims shares for a fulfilled request by share amount.
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);

    /// @notice Cancels a pending (unsettled) request and refunds its assets.
    function cancelDepositRequest(uint256 requestId, address controller) external;

    /// @notice Sets or revokes `operator` as an approved actor for msg.sender's requests.
    function setOperator(address operator, bool approved) external returns (bool);

    /// @notice Whether `operator` is approved to act for `controller`.
    function isOperator(address controller, address operator) external view returns (bool);

    /// @notice The deposit asset (ERC-4626 `asset`).
    function asset() external view returns (address);

    /// @notice The share token minted on claim (ERC-7540 `share`).
    function share() external view returns (address);

}
