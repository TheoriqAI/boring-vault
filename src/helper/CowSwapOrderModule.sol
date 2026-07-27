// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Auth, Authority } from "@solmate/auth/Auth.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IGPv2Settlement, GPv2Order, CowSwapLimitParams } from "src/interfaces/IGPv2.sol";

/**
 * @title CowSwapOrderModule  (DRAFT — NOT AUDITED, NOT WIRED INTO DEPLOY)
 * @notice On-chain CoW Protocol (GPv2) limit-order module for a BoringVault. A pure decoder cannot gate
 *         `setPreSignature(bytes orderUid)` — the uid is an opaque hash, so the tokens/amounts are invisible
 *         and a merkle root over it constrains nothing. This module does the checks a decoder can't: it
 *         recomputes the uid from the full order struct and requires it to match (binding the opaque uid to
 *         a checked order), verifies the order's tokens/receiver/amounts/kind, and only then pre-signs.
 * @dev The module is the order's owner/receiver: the vault transfers the sell token in, the module pre-signs
 *      (solvers fill and send the buy token here), and the vault pulls the proceeds back. Only the
 *      BoringVault may drive it (`onlyVault`); the merkle root gates WHICH orders the vault can create, and
 *      the decoder pins the tokens.
 * @dev INTEGRITY-ONLY (by design choice): the order is bound and its tokens allow-listed, but the price
 *      (`minAmountOut`/`order.buyAmount`) is the strategist's responsibility — it is NOT oracle-bounded.
 *      This mirrors the 1inch `minReturn` trust model. Add an oracle bound before relying on it against an
 *      untrusted strategist.
 * @custom:security-contact security@theoriq.ai
 */
contract CowSwapOrderModule is Auth {

    using SafeTransferLib for ERC20;
    using SafeERC20 for IERC20;

    address public immutable boringVault;
    address public immutable cowswapSettlement;
    address public immutable cowswapVaultRelayer;
    bytes32 public immutable domainSeparator; // cached from the settlement at deploy

    mapping(address => bool) public allowedToken;

    error CowSwapOrderModule__OnlyVault();
    error CowSwapOrderModule__TokenNotAllowed();
    error CowSwapOrderModule__SameToken();
    error CowSwapOrderModule__InsufficientBalance();
    error CowSwapOrderModule__Expired();
    error CowSwapOrderModule__OrderMismatch(string field);

    event AllowedTokenSet(address indexed token, bool allowed);
    event LimitOrderCreated(CowSwapLimitParams params, bytes orderUid);
    event OrderInvalidated(bytes orderUid);
    event ApprovalSet(address indexed token, uint256 amount);
    event AssetsPulled(address indexed token, uint256 amount);

    modifier onlyVault() {
        if (msg.sender != boringVault) revert CowSwapOrderModule__OnlyVault();
        _;
    }

    constructor(
        address _owner,
        address _boringVault,
        address _settlement,
        address _relayer
    )
        Auth(_owner, Authority(address(0)))
    {
        boringVault = _boringVault;
        cowswapSettlement = _settlement;
        cowswapVaultRelayer = _relayer;
        domainSeparator = IGPv2Settlement(_settlement).domainSeparator();
    }

    /// @notice Allow-list (or remove) a token that may be used as sell/buy.
    function setAllowedToken(address token, bool allowed) external requiresAuth {
        allowedToken[token] = allowed;
        emit AllowedTokenSet(token, allowed);
    }

    /// @notice Approve the CoW VaultRelayer to pull `amount` of an allow-listed sell token.
    function setCowswapApproval(address token, uint256 amount) external onlyVault {
        if (!allowedToken[token]) revert CowSwapOrderModule__TokenNotAllowed();
        IERC20(token).forceApprove(cowswapVaultRelayer, amount);
        emit ApprovalSet(token, amount);
    }

    /// @notice Verify and pre-sign a CoW limit order. Reverts unless the order struct is internally
    ///         consistent with `params`, the receiver is this module, tokens are allow-listed, and the
    ///         recomputed uid matches `orderUid`.
    function createLimitOrder(
        CowSwapLimitParams calldata params,
        GPv2Order.Data calldata order,
        bytes calldata orderUid
    )
        external
        onlyVault
    {
        _checkParams(params);
        _checkOrder(params, order, orderUid);
        // Approve the relayer for EXACTLY this order's sell amount (feeAmount is required 0 above), so it can
        // never pull more than the order's terms. forceApprove OVERWRITES any prior allowance — one active
        // order per sell token at a time; revoke a cancelled order's leftover with setCowswapApproval(token, 0).
        IERC20(order.sellToken).forceApprove(cowswapVaultRelayer, order.sellAmount);
        IGPv2Settlement(cowswapSettlement).setPreSignature(orderUid, true);
        emit LimitOrderCreated(params, orderUid);
    }

    /// @notice Cancel a previously created order.
    function invalidateOrder(bytes calldata orderUid) external onlyVault {
        IGPv2Settlement(cowswapSettlement).invalidateOrder(orderUid);
        emit OrderInvalidated(orderUid);
    }

    /// @notice Return tokens held by the module (proceeds, or an un-filled sell token) to the vault.
    function pullAssets(address token, uint256 amount) external onlyVault {
        ERC20(token).safeTransfer(boringVault, amount);
        emit AssetsPulled(token, amount);
    }

    function _checkParams(CowSwapLimitParams calldata p) internal view {
        if (!allowedToken[p.tokenIn] || !allowedToken[p.tokenOut]) revert CowSwapOrderModule__TokenNotAllowed();
        if (p.tokenIn == p.tokenOut) revert CowSwapOrderModule__SameToken();
        if (p.amountIn == 0 || ERC20(p.tokenIn).balanceOf(address(this)) < p.amountIn) {
            revert CowSwapOrderModule__InsufficientBalance();
        }
        if (p.deadline < block.timestamp) revert CowSwapOrderModule__Expired();
        // INTEGRITY-ONLY: minAmountOut (the price) is not oracle-bounded here — see the contract notice.
    }

    function _checkOrder(
        CowSwapLimitParams calldata p,
        GPv2Order.Data calldata order,
        bytes calldata orderUid
    )
        internal
        view
    {
        if (order.sellToken != p.tokenIn) revert CowSwapOrderModule__OrderMismatch("sellToken");
        if (order.buyToken != p.tokenOut) revert CowSwapOrderModule__OrderMismatch("buyToken");
        if (order.receiver != address(this)) revert CowSwapOrderModule__OrderMismatch("receiver");
        if (order.sellAmount != p.amountIn) revert CowSwapOrderModule__OrderMismatch("sellAmount");
        if (order.buyAmount != p.minAmountOut) revert CowSwapOrderModule__OrderMismatch("buyAmount");
        if (order.validTo != p.deadline) revert CowSwapOrderModule__OrderMismatch("validTo");
        if (order.kind != GPv2Order.KIND_SELL) revert CowSwapOrderModule__OrderMismatch("kind");
        if (order.sellTokenBalance != GPv2Order.BALANCE_ERC20) revert CowSwapOrderModule__OrderMismatch("sellBalance");
        if (order.buyTokenBalance != GPv2Order.BALANCE_ERC20) revert CowSwapOrderModule__OrderMismatch("buyBalance");
        // A pre-signed limit order must carry NO protocol fee (else the relayer pulls sellAmount + feeAmount,
        // draining beyond the checked terms) and must be fill-or-nothing at these terms.
        if (order.feeAmount != 0) revert CowSwapOrderModule__OrderMismatch("feeAmount");
        if (order.partiallyFillable) revert CowSwapOrderModule__OrderMismatch("partiallyFillable");

        // Bind the opaque uid to the checked struct: recompute it and require an exact match.
        bytes32 digest = GPv2Order.hash(order, domainSeparator);
        bytes memory computed = GPv2Order.packOrderUid(digest, address(this), order.validTo);
        if (keccak256(orderUid) != keccak256(computed)) revert CowSwapOrderModule__OrderMismatch("orderUid");
    }

}
