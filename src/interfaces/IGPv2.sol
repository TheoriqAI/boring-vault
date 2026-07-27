// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

/// @notice Minimal CoW Protocol (GPv2) settlement surface used by CowSwapOrderModule.
///         Mainnet settlement 0x9008D19f58AAbD9eD0D60971565AA8510560ab41,
///         vault relayer 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110.
interface IGPv2Settlement {

    function setPreSignature(bytes calldata orderUid, bool signed) external;
    function invalidateOrder(bytes calldata orderUid) external;
    function domainSeparator() external view returns (bytes32);

}

/// @notice Caller-supplied intent, checked against the GPv2 order (the price/amounts the strategist wants).
struct CowSwapLimitParams {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    uint32 deadline;
}

/**
 * @title GPv2Order
 * @notice CoW Protocol order struct + EIP-712 hashing / uid packing, matching the deployed GPv2Settlement.
 * @dev `hash` reproduces the on-chain order digest (already EIP-712 domain-separated); `packOrderUid`
 *      reproduces the 56-byte uid (`orderDigest[32] ++ owner[20] ++ validTo[4]`). Constants are the live
 *      verified values. `sellToken`/`buyToken` are `address` here (ABI-identical to the canonical `IERC20`).
 */
library GPv2Order {

    struct Data {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind;
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }

    bytes32 internal constant TYPE_HASH = 0xd5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489;
    bytes32 internal constant KIND_SELL = 0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775;
    bytes32 internal constant BALANCE_ERC20 = 0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9;

    function hash(Data memory order, bytes32 domainSeparator) internal pure returns (bytes32 orderDigest) {
        bytes32 structHash = keccak256(
            abi.encode(
                TYPE_HASH,
                order.sellToken,
                order.buyToken,
                order.receiver,
                order.sellAmount,
                order.buyAmount,
                order.validTo,
                order.appData,
                order.feeAmount,
                order.kind,
                order.partiallyFillable,
                order.sellTokenBalance,
                order.buyTokenBalance
            )
        );
        orderDigest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function packOrderUid(bytes32 orderDigest, address owner, uint32 validTo) internal pure returns (bytes memory) {
        return abi.encodePacked(orderDigest, owner, validTo);
    }

}
