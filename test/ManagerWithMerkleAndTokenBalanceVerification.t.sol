// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleAndTokenBalanceVerification } from
    "src/base/Roles/ManagerWithMerkleAndTokenBalanceVerification.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { IMorphoFlashLoanCallback } from "src/interfaces/IMorpho.sol";
import { IMidnightFlashLoanCallback } from "src/interfaces/IMidnight.sol";

contract MockToken is ERC20 {

    constructor(string memory n, string memory s) ERC20(n, s, 18) { }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

}

/// @notice Minimal Morpho Blue stand-in: lends `assets` to the borrower, calls back, then pulls repayment
///         via transferFrom (the borrower must have approved this contract) — the "approve and let it take".
contract MockMorpho {

    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        ERC20(token).transfer(msg.sender, assets);
        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        ERC20(token).transferFrom(msg.sender, address(this), assets);
    }

}

/// @notice Minimal Midnight stand-in: sends each token to `callback`, calls back (requiring the success
///         magic return), then pulls each amount back via transferFrom.
contract MockMidnight {

    bytes32 internal constant SUCCESS = 0x7f87788ea698181ea4d28d1576d0ba4fc92c0dbe5bf75b43692af2ce91dbaea2;

    error WrongFlashLoanCallbackReturnValue();
    error InconsistentInput();

    function flashLoan(
        address[] calldata tokens,
        uint256[] calldata assets,
        address callback,
        bytes calldata data
    )
        external
    {
        if (tokens.length != assets.length) revert InconsistentInput();
        for (uint256 i; i < tokens.length; ++i) {
            ERC20(tokens[i]).transfer(callback, assets[i]);
        }
        bytes32 ret = IMidnightFlashLoanCallback(callback).onFlashLoan(msg.sender, tokens, assets, data);
        if (ret != SUCCESS) revert WrongFlashLoanCallbackReturnValue();
        for (uint256 i; i < tokens.length; ++i) {
            ERC20(tokens[i]).transferFrom(callback, address(this), assets[i]);
        }
    }

}

/**
 * @notice Unit tests for the merkle + token-balance-delta manager. Non-forked: a real BoringVault holds
 *         mock tokens, and the managed call is a plain ERC20 `transfer` so the batch's balance delta is
 *         exactly controllable. Single-leaf merkle trees are used (root == leaf, empty proof).
 */
contract ManagerWithMerkleAndTokenBalanceVerificationTest is Test {

    BoringVault internal vault;
    ManagerWithMerkleAndTokenBalanceVerification internal manager;
    BaseDecoderAndSanitizer internal decoder;
    RolesAuthority internal auth;
    MockToken internal tokenA;
    MockToken internal tokenB;
    MockMorpho internal morpho;
    MockMidnight internal midnight;

    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant MANAGER_INTERNAL_ROLE = 3;
    address internal constant RECIPIENT = address(0xCAFE);

    function setUp() external {
        vault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        manager = new ManagerWithMerkleAndTokenBalanceVerification(address(this), address(vault), address(0));
        decoder = new BaseDecoderAndSanitizer(address(vault));
        morpho = new MockMorpho();
        midnight = new MockMidnight();

        auth = new RolesAuthority(address(this), Authority(address(0)));
        vault.setAuthority(auth);
        manager.setAuthority(auth);
        // Manager (as MANAGER_ROLE) may drive the vault; the test contract is the manager's owner, so it
        // can call the manager's requiresAuth entrypoints directly without a role.
        auth.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );
        auth.setUserRole(address(manager), MANAGER_ROLE, true);
        // The manager re-enters manageVaultWithMerkleVerification during the flash-loan callback (an
        // external self-call), so it needs the internal manager role — same wiring as the Balancer path.
        auth.setRoleCapability(
            MANAGER_INTERNAL_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
        );
        auth.setUserRole(address(manager), MANAGER_INTERNAL_ROLE, true);

        tokenA = new MockToken("Token A", "A");
        tokenB = new MockToken("Token B", "B");
        tokenA.mint(address(vault), 1000e18);
        tokenB.mint(address(vault), 1000e18);
    }

    /// @dev Empty strategy batch for the Blue path: token-prefixed (the callback isn't passed the token).
    function _emptyStrategyUserData(address token) internal pure returns (bytes memory) {
        return abi.encode(
            token,
            new bytes32[][](0),
            new address[](0),
            new address[](0),
            new bytes[](0),
            new uint256[](0)
        );
    }

    /// @dev Empty strategy batch for the Midnight path: no token prefix (tokens arrive via the callback).
    function _emptyMidnightUserData() internal pure returns (bytes memory) {
        return abi.encode(
            new bytes32[][](0), new address[](0), new address[](0), new bytes[](0), new uint256[](0)
        );
    }

    // --- helpers -------------------------------------------------------------

    function _leaf(address target, bytes memory packedAddrs) internal view returns (bytes32) {
        // value is always 0 here, so valueIsNonZero = false.
        return keccak256(abi.encodePacked(address(decoder), target, false, ERC20.transfer.selector, packedAddrs));
    }

    /// @dev Builds a one-call batch that transfers `amt` of `token` from the vault to `to`, and sets the
    ///      strategist root to the single leaf that authorizes exactly that call.
    function _transferBatch(
        address token,
        address to,
        uint256 amt
    )
        internal
        returns (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        )
    {
        manager.setManageRoot(address(this), _leaf(token, abi.encodePacked(to)));
        proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0); // single-leaf tree => empty proof
        decoders = new address[](1);
        decoders[0] = address(decoder);
        targets = new address[](1);
        targets[0] = token;
        data = new bytes[](1);
        data[0] = abi.encodeWithSelector(ERC20.transfer.selector, to, amt);
        values = new uint256[](1);
        values[0] = 0;
    }

    function _checks(
        address token,
        int256 minDelta
    )
        internal
        pure
        returns (ManagerWithMerkleAndTokenBalanceVerification.TokenDeltaCheck[] memory c)
    {
        c = new ManagerWithMerkleAndTokenBalanceVerification.TokenDeltaCheck[](1);
        c[0] = ManagerWithMerkleAndTokenBalanceVerification.TokenDeltaCheck(token, minDelta);
    }

    // --- tests ---------------------------------------------------------------

    function testLossWithinBoundSucceeds() external {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _transferBatch(address(tokenA), RECIPIENT, 100e18);

        manager.manageVaultWithMerkleAndBalanceVerification(
            proofs, decoders, targets, data, values, _checks(address(tokenA), -100e18)
        );

        assertEq(tokenA.balanceOf(address(vault)), 900e18);
        assertEq(tokenA.balanceOf(RECIPIENT), 100e18);
    }

    function testLossExceedsBoundReverts() external {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _transferBatch(address(tokenA), RECIPIENT, 100e18);

        // Allow losing at most 99, but the batch loses 100 => revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleAndTokenBalanceVerification
                    .ManagerWithMerkleAndTokenBalanceVerification__TokenDeltaViolation
                    .selector,
                address(tokenA),
                uint256(1000e18),
                uint256(900e18),
                int256(-100e18),
                int256(-99e18)
            )
        );
        manager.manageVaultWithMerkleAndBalanceVerification(
            proofs, decoders, targets, data, values, _checks(address(tokenA), -99e18)
        );

        assertEq(tokenA.balanceOf(address(vault)), 1000e18); // reverted => no change
    }

    function testPositiveDeltaNotMetReverts() external {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _transferBatch(address(tokenA), RECIPIENT, 100e18);

        // Require a +1 gain on tokenB, which the batch never touches => delta 0 < 1 => revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleAndTokenBalanceVerification
                    .ManagerWithMerkleAndTokenBalanceVerification__TokenDeltaViolation
                    .selector,
                address(tokenB),
                uint256(1000e18),
                uint256(1000e18),
                int256(0),
                int256(1)
            )
        );
        manager.manageVaultWithMerkleAndBalanceVerification(
            proofs, decoders, targets, data, values, _checks(address(tokenB), 1)
        );
    }

    function testMultiTokenDeltasSucceed() external {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _transferBatch(address(tokenA), RECIPIENT, 100e18);

        ManagerWithMerkleAndTokenBalanceVerification.TokenDeltaCheck[] memory checks =
            new ManagerWithMerkleAndTokenBalanceVerification.TokenDeltaCheck[](2);
        checks[0] = ManagerWithMerkleAndTokenBalanceVerification.TokenDeltaCheck(address(tokenA), -100e18);
        checks[1] = ManagerWithMerkleAndTokenBalanceVerification.TokenDeltaCheck(address(tokenB), 0);

        manager.manageVaultWithMerkleAndBalanceVerification(proofs, decoders, targets, data, values, checks);

        assertEq(tokenA.balanceOf(address(vault)), 900e18);
        assertEq(tokenB.balanceOf(address(vault)), 1000e18);
    }

    function testMerkleStillEnforced() external {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _transferBatch(address(tokenA), RECIPIENT, 100e18);

        // Root authorizes transfer to RECIPIENT; swap in a different, unauthorized recipient.
        data[0] = abi.encodeWithSelector(ERC20.transfer.selector, address(0xBAD), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerWithMerkleVerification.ManagerWithMerkleVerification__FailedToVerifyManageProof.selector,
                address(tokenA),
                data[0],
                uint256(0)
            )
        );
        manager.manageVaultWithMerkleAndBalanceVerification(
            proofs, decoders, targets, data, values, _checks(address(tokenA), -100e18)
        );
    }

    function testEmptyDeltaChecksReverts() external {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _transferBatch(address(tokenA), RECIPIENT, 100e18);

        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__InvalidTokenArrayLength
                .selector
        );
        manager.manageVaultWithMerkleAndBalanceVerification(
            proofs,
            decoders,
            targets,
            data,
            values,
            new ManagerWithMerkleAndTokenBalanceVerification.TokenDeltaCheck[](0)
        );
    }

    function testInheritedPlainManageStillWorks() external {
        (
            bytes32[][] memory proofs,
            address[] memory decoders,
            address[] memory targets,
            bytes[] memory data,
            uint256[] memory values
        ) = _transferBatch(address(tokenA), RECIPIENT, 100e18);

        // The inherited entrypoint (no balance check) must still function on the derived contract.
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
        assertEq(tokenA.balanceOf(address(vault)), 900e18);
    }

    // --- Morpho Blue flash loan ---------------------------------------------

    function testMorphoFlashLoanBorrowsAndRepays() external {
        tokenA.mint(address(morpho), 500e18); // provider liquidity

        // Only the vault may initiate (as it would via a merkle-verified manage call).
        vm.prank(address(vault));
        manager.morphoFlashLoan(address(morpho), address(tokenA), 100e18, _emptyStrategyUserData(address(tokenA)));

        // Borrowed then repaid in full: everyone is whole, no residual allowance.
        assertEq(tokenA.balanceOf(address(vault)), 1000e18, "vault net zero");
        assertEq(tokenA.balanceOf(address(morpho)), 500e18, "provider repaid");
        assertEq(tokenA.balanceOf(address(manager)), 0, "no dust in manager");
        assertEq(tokenA.allowance(address(manager), address(morpho)), 0, "allowance consumed to zero");
    }

    function testMorphoFlashLoanOnlyCallableByVault() external {
        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanOnlyCallableByBoringVault
                .selector
        );
        // caller is the test contract, not the vault
        manager.morphoFlashLoan(address(morpho), address(tokenA), 100e18, _emptyStrategyUserData(address(tokenA)));
    }

    function testOnMorphoFlashLoanNotCallableDirectly() external {
        // expectedFlashLoanCaller is unset (no flash loan active), so any direct call is rejected.
        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__MorphoFlashLoanOnlyCallableByProvider
                .selector
        );
        manager.onMorphoFlashLoan(100e18, _emptyStrategyUserData(address(tokenA)));
    }

    // --- Midnight (multi-token) flash loan ----------------------------------

    function testMidnightFlashLoanBorrowsAndRepays() external {
        tokenA.mint(address(midnight), 500e18);
        tokenB.mint(address(midnight), 500e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory assets = new uint256[](2);
        assets[0] = 100e18;
        assets[1] = 50e18;

        vm.prank(address(vault));
        manager.midnightFlashLoan(address(midnight), tokens, assets, _emptyMidnightUserData());

        // Both tokens borrowed then repaid in full; no dust or residual allowance in the manager.
        assertEq(tokenA.balanceOf(address(vault)), 1000e18, "vault A net zero");
        assertEq(tokenB.balanceOf(address(vault)), 1000e18, "vault B net zero");
        assertEq(tokenA.balanceOf(address(midnight)), 500e18, "provider A repaid");
        assertEq(tokenB.balanceOf(address(midnight)), 500e18, "provider B repaid");
        assertEq(tokenA.balanceOf(address(manager)), 0, "no A dust");
        assertEq(tokenB.balanceOf(address(manager)), 0, "no B dust");
        assertEq(tokenA.allowance(address(manager), address(midnight)), 0, "A allowance consumed");
        assertEq(tokenB.allowance(address(manager), address(midnight)), 0, "B allowance consumed");
    }

    function testMidnightFlashLoanOnlyCallableByVault() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory assets = new uint256[](1);
        assets[0] = 100e18;

        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanOnlyCallableByBoringVault
                .selector
        );
        manager.midnightFlashLoan(address(midnight), tokens, assets, _emptyMidnightUserData());
    }

    function testMidnightFlashLoanInconsistentInputReverts() external {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory assets = new uint256[](1); // mismatched length
        assets[0] = 100e18;

        vm.prank(address(vault));
        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanInconsistentInput
                .selector
        );
        manager.midnightFlashLoan(address(midnight), tokens, assets, _emptyMidnightUserData());
    }

    function testOnFlashLoanNotCallableDirectly() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory assets = new uint256[](1);
        assets[0] = 100e18;

        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__MidnightFlashLoanOnlyCallableByProvider
                .selector
        );
        manager.onFlashLoan(address(this), tokens, assets, _emptyMidnightUserData());
    }

}
