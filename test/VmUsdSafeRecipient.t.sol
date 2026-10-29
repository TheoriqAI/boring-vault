// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ERC20 } from "@solmate/tokens/ERC20.sol";

import { BoringVault } from "src/base/BoringVault.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { WithdrawQueue } from "src/base/Roles/WithdrawQueue.sol";
import { IERC20 } from "src/interfaces/IFeeModule.sol";

import { DeployAllWithRoleGrants } from "script/deploy/deployAllWithRoleGrants.s.sol";
import { ForkTest } from "test/LiveDeploy.t.sol";

interface ISafeProxyFactory {

    function createProxyWithNonce(
        address singleton,
        bytes memory initializer,
        uint256 saltNonce
    )
        external
        returns (address proxy);

}

interface ISafeSetup {

    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address paymentReceiver
    )
        external;

}

/**
 * @notice Proves a Gnosis Safe can deposit and redeem to ITSELF through the audited `WithdrawQueue`.
 * @dev    The queue mints an ERC721 receipt with OpenZeppelin's `_safeMint`, so any `receiver` with code
 *         must answer `onERC721Received`. Safes do — via the `CompatibilityFallbackHandler`
 *         (`TokenCallbackHandler`) that the Safe factory wires in by default. This test deploys REAL Safes
 *         through the canonical mainnet `SafeProxyFactory` (1.3.0 and 1.4.1) rather than a mock, and also
 *         pins the one configuration that does NOT work: a Safe with no fallback handler.
 *
 *         Safe calls are driven with `vm.prank(safe)` — the thing under test is whether the teller/queue
 *         accept a contract caller and whether `_safeMint` to the Safe succeeds, not Safe's own multisig
 *         signature assembly.
 *
 *           LIVE_DEPLOY_READ_FILE_NAME=vmUSD.json \
 *             forge test --mp test/VmUsdSafeRecipient.t.sol --fork-url $L1_RPC_URL
 */
contract VmUsdSafeRecipient is ForkTest, DeployAllWithRoleGrants {

    address constant OPERATOR_A = 0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631;
    address constant FINAL_OWNER = 0xCB068924bb3D2Ebb28BD1BB25b09ec15b0D5a03B;

    // Canonical Safe deployments on Ethereum mainnet.
    address constant SAFE_FACTORY_130 = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address constant SAFE_SINGLETON_130 = 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552;
    address constant SAFE_FALLBACK_130 = 0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4;
    address constant SAFE_FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant SAFE_SINGLETON_141 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address constant SAFE_FALLBACK_141 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    bytes4 constant ERC721_RECEIVED = 0x150b7a02;

    uint256 constant DEPOSIT = 25_000e6; // 25,000 USDC

    ERC20 usdc;
    BoringVault vault;
    TellerWithMultiAssetSupport teller;
    WithdrawQueue queue;

    function setUp() public {
        string memory file = block.chainid == 31_337 ? "vmUSD.json" : vm.envString("LIVE_DEPLOY_READ_FILE_NAME");
        if (block.chainid == 31_337) _startFork("L1_RPC_URL");

        runLiveTestWithRoleGrants(file);

        usdc = ERC20(mainConfig.base);
        vault = BoringVault(payable(mainConfig.boringVault));
        teller = TellerWithMultiAssetSupport(mainConfig.teller);
        queue = WithdrawQueue(mainConfig.withdrawQueue);
    }

    // ===================================== THE CASE THAT MATTERS =====================================

    /// @notice Safe 1.4.1 deposits USDC and redeems back to itself — receipt NFT and payout both land on the Safe.
    function testSafe141DepositsAndRedeemsToItself() public {
        address safe = _deploySafe(SAFE_FACTORY_141, SAFE_SINGLETON_141, SAFE_FALLBACK_141, 1);
        _assertSafeRoundTrip(safe);
    }

    /// @notice Same for Safe 1.3.0 (the version both of your admin addresses resolve to).
    function testSafe130DepositsAndRedeemsToItself() public {
        address safe = _deploySafe(SAFE_FACTORY_130, SAFE_SINGLETON_130, SAFE_FALLBACK_130, 2);
        _assertSafeRoundTrip(safe);
    }

    /// @notice A Safe can also be the `receiver` of an order submitted (and funded) by someone else.
    function testEoaCanRedeemIntoASafe() public {
        address safe = _deploySafe(SAFE_FACTORY_141, SAFE_SINGLETON_141, SAFE_FALLBACK_141, 3);
        address eoa = makeAddr("eoa funding a safe redeem");

        uint256 shares = _deposit(eoa, DEPOSIT);

        vm.startPrank(eoa);
        vault.approve(address(queue), shares);
        // depositor = the EOA (shares pulled from it), receiver = the Safe (gets the receipt and the payout).
        uint256 orderIndex = queue.submitOrder(_orderParams(shares, eoa, safe));
        vm.stopPrank();

        assertEq(queue.ownerOf(orderIndex), safe, "Safe holds the receipt");

        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(usdc.balanceOf(safe), DEPOSIT, "payout went to the Safe");
        assertEq(usdc.balanceOf(eoa), 0, "not back to the funding EOA");
    }

    /// @notice A Safe can cancel its own order and get the shares back.
    function testSafeCanCancelItsOwnOrder() public {
        address safe = _deploySafe(SAFE_FACTORY_141, SAFE_SINGLETON_141, SAFE_FALLBACK_141, 4);
        uint256 shares = _deposit(safe, DEPOSIT);
        uint256 orderIndex = _submitOrder(safe, shares, safe);

        vm.prank(safe);
        queue.cancelOrder(orderIndex);

        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(vault.balanceOf(safe), shares, "shares refunded to the Safe");
        assertEq(usdc.balanceOf(safe), 0, "no USDC paid out");
    }

    // ===================================== THE FAILURE MODE =====================================

    /**
     * @notice The one Safe configuration that CANNOT be an order receiver: `fallbackHandler == address(0)`.
     *         Without the handler the Safe has no `onERC721Received`, so the receipt mint reverts.
     * @dev    The Safe UI/SDK always sets the handler, so this is only reachable by deploying a Safe
     *         programmatically with `fallbackHandler = 0`. The deposit still works; only the order fails,
     *         and the fix is either `setFallbackHandler` on the Safe or naming a different `receiver`.
     */
    function testSafeWithNoFallbackHandlerCannotReceiveTheReceipt() public {
        address safe = _deploySafe(SAFE_FACTORY_141, SAFE_SINGLETON_141, address(0), 5);

        // Confirm the premise. NOTE Safe's `fallback()` does `return(0, 0)` when no handler is set, so the
        // call *succeeds* with empty returndata rather than reverting — it just never produces the magic
        // value. OZ's `checkOnERC721Received` then fails decoding the empty return and reverts.
        (bool ok, bytes memory ret) = safe.staticcall(
            abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", address(1), address(1), 1, "")
        );
        assertFalse(
            ok && ret.length >= 32 && abi.decode(ret, (bytes4)) == ERC721_RECEIVED,
            "handler-less Safe must not return the ERC721 magic value"
        );
        assertEq(ret.length, 0, "handler-less Safe returns empty data");

        uint256 shares = _deposit(safe, DEPOSIT);
        assertEq(vault.balanceOf(safe), shares, "the deposit itself is unaffected");

        vm.startPrank(safe);
        vault.approve(address(queue), shares);
        vm.expectRevert(); // ERC721InvalidReceiver
        queue.submitOrder(_orderParams(shares, safe, safe));

        // Workaround: point the receipt at an address that can hold it. Shares still come from the Safe.
        address receipts = makeAddr("safe ops receipt holder");
        queue.submitOrder(_orderParams(shares, safe, receipts));
        vm.stopPrank();

        vm.prank(OPERATOR_A);
        queue.processOrders(1);
        assertEq(usdc.balanceOf(receipts), DEPOSIT, "payout follows the receipt owner");
    }

    // ============================== THE CONFIGURED ADMIN ADDRESSES ==============================

    /**
     * @notice Both configured operator addresses can themselves receive the receipt NFT, so either can be
     *         named as a withdraw `receiver`. `0xA072…` is a plain EOA; `0xCB06…` is an EIP-7702-delegated
     *         account whose delegate does implement the ERC721 callback.
     */
    function testConfiguredAdminAddressesCanReceiveTheReceipt() public {
        assertEq(OPERATOR_A.code.length, 0, "0xA072... is expected to be a plain EOA");
        _assertCanReceiveReceipt(OPERATOR_A);

        // Not asserting 0xCB06 is/ isn't a contract — only that whatever it is, it answers the callback.
        _assertCanReceiveReceipt(FINAL_OWNER);
    }

    // ========================================= HELPERS =========================================

    /// @dev Deposits from `who`, redeems the whole position back to `who`, asserting every leg.
    function _assertSafeRoundTrip(address safe) internal {
        assertGt(safe.code.length, 0, "the Safe must be a contract");
        _assertCanReceiveReceipt(safe);

        uint256 shares = _deposit(safe, DEPOSIT);
        assertEq(shares, DEPOSIT, "1:1 shares at the starting rate");
        assertEq(vault.balanceOf(safe), shares, "Safe holds the shares");

        uint256 orderIndex = _submitOrder(safe, shares, safe);
        assertEq(queue.ownerOf(orderIndex), safe, "Safe holds the receipt NFT");
        assertEq(vault.balanceOf(address(queue)), shares, "shares escrowed");

        vm.prank(OPERATOR_A);
        queue.processOrders(1);

        assertEq(usdc.balanceOf(safe), DEPOSIT, "Safe redeemed to itself");
        assertEq(vault.balanceOf(safe), 0, "no shares left");
        assertEq(
            uint256(queue.getOrderStatus(orderIndex)), uint256(WithdrawQueue.OrderStatus.COMPLETE), "order complete"
        );
    }

    function _assertCanReceiveReceipt(address receiver) internal view {
        if (receiver.code.length == 0) return; // EOAs (incl. MPC-signed EOAs) need no callback
        (bool ok, bytes memory ret) = receiver.staticcall(
            abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", address(1), address(1), 1, "")
        );
        assertTrue(ok && ret.length >= 32 && abi.decode(ret, (bytes4)) == ERC721_RECEIVED, "cannot hold the receipt");
    }

    function _deploySafe(
        address factory,
        address singleton,
        address fallbackHandler,
        uint256 saltNonce
    )
        internal
        returns (address safe)
    {
        address[] memory owners = new address[](1);
        owners[0] = makeAddr("safe owner");
        bytes memory initializer = abi.encodeCall(
            ISafeSetup.setup, (owners, 1, address(0), "", fallbackHandler, address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactory(factory).createProxyWithNonce(singleton, initializer, saltNonce);
        vm.label(safe, "Safe");
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        deal(address(usdc), who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        shares = teller.deposit(usdc, amount, 0);
        vm.stopPrank();
    }

    function _submitOrder(address who, uint256 shares, address receiver) internal returns (uint256 orderIndex) {
        vm.startPrank(who);
        vault.approve(address(queue), shares);
        orderIndex = queue.submitOrder(_orderParams(shares, who, receiver));
        vm.stopPrank();
    }

    function _orderParams(
        uint256 shares,
        address depositor,
        address receiver
    )
        internal
        view
        returns (WithdrawQueue.SubmitOrderParams memory)
    {
        return WithdrawQueue.SubmitOrderParams({
            amountOffer: shares,
            wantAsset: IERC20(address(usdc)),
            intendedDepositor: depositor,
            receiver: receiver,
            refundReceiver: depositor,
            signatureParams: WithdrawQueue.SignatureParams({
                approvalMethod: WithdrawQueue.ApprovalMethod.EIP20_APPROVE,
                approvalV: 0,
                approvalR: bytes32(0),
                approvalS: bytes32(0),
                submitWithSignature: false,
                deadline: 0,
                eip2612Signature: ""
            })
        });
    }

}
