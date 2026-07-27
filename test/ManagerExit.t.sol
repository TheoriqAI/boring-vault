// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { ManagerWithMerkleAndTokenBalanceVerification } from
    "src/base/Roles/ManagerWithMerkleAndTokenBalanceVerification.sol";
import { ManagerWithMerkleVerification } from "src/base/Roles/ManagerWithMerkleVerification.sol";
import { BaseDecoderAndSanitizer } from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";

contract MockToken is ERC20 {

    constructor() ERC20("RWA", "RWA", 18) { }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

}

/// @dev Decodes BoringVault.exit(address,ERC20,uint256,address,uint256) — pins to/asset/from.
contract MockExitDecoder is BaseDecoderAndSanitizer {

    constructor(address bv) BaseDecoderAndSanitizer(bv) { }

    function exit(address to, address asset, uint256, address from, uint256) external pure returns (bytes memory) {
        return abi.encodePacked(to, asset, from);
    }

}

contract ManagerExitTest is Test {

    BoringVault internal vault;
    ManagerWithMerkleAndTokenBalanceVerification internal manager;
    MockExitDecoder internal decoder;
    MockToken internal asset;
    RolesAuthority internal auth;

    uint8 internal constant MANAGER_ROLE = 1;
    uint8 internal constant MINTER_ROLE = 2;
    uint8 internal constant EXIT_ROLE = 3;
    address internal constant RECIPIENT = address(0xCAFE);

    function setUp() external {
        vault = new BoringVault(address(this), "BV", "BV", 18);
        manager = new ManagerWithMerkleAndTokenBalanceVerification(address(this), address(vault), address(0));
        decoder = new MockExitDecoder(address(vault));
        asset = new MockToken();

        auth = new RolesAuthority(address(this), Authority(address(0)));
        vault.setAuthority(auth);
        auth.setRoleCapability(MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address,bytes,uint256)")), true);
        auth.setUserRole(address(manager), MANAGER_ROLE, true);
        auth.setRoleCapability(MINTER_ROLE, address(vault), BoringVault.enter.selector, true);
        auth.setUserRole(address(this), MINTER_ROLE, true);
        // the vault must be able to call exit on itself (invoked via manage self-call)
        auth.setRoleCapability(EXIT_ROLE, address(vault), BoringVault.exit.selector, true);
        auth.setUserRole(address(vault), EXIT_ROLE, true);

        // mint 1000 treasury shares to the vault, backed by 1000 asset
        asset.mint(address(this), 1000e18);
        asset.approve(address(vault), 1000e18);
        vault.enter(address(this), asset, 1000e18, address(vault), 1000e18);
    }

    function _exitData(
        address to,
        uint256 assetAmt,
        address from,
        uint256 shareAmt
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(BoringVault.exit.selector, to, address(asset), assetAmt, from, shareAmt);
    }

    function _setRootForExit(address to, address from) internal {
        bytes32 leaf = keccak256(
            abi.encodePacked(
                address(decoder),
                address(vault),
                false,
                BoringVault.exit.selector,
                abi.encodePacked(to, address(asset), from)
            )
        );
        manager.setManageRoot(address(this), leaf);
    }

    // --- happy path ---------------------------------------------------------

    function testExitBurnsTreasurySharesNoAssetMoves() external {
        _setRootForExit(RECIPIENT, address(vault));
        // burn-only: assetAmount = 0
        manager.exitVaultWithMerkleVerification(
            new bytes32[](0), address(decoder), _exitData(RECIPIENT, 0, address(vault), 100e18)
        );
        assertEq(vault.totalSupply(), 900e18, "supply not reduced");
        assertEq(vault.balanceOf(address(vault)), 900e18, "treasury shares not burned");
        assertEq(asset.balanceOf(address(vault)), 1000e18, "asset must NOT move (burn-only)");
        assertEq(asset.balanceOf(RECIPIENT), 0, "no asset delivered");
    }

    // --- the relaxation is contained: normal manage STILL forbids the burn ---

    function testNormalManageStillRejectsBurn() external {
        _setRootForExit(RECIPIENT, address(vault));
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        address[] memory decoders = new address[](1);
        decoders[0] = address(decoder);
        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        bytes[] memory data = new bytes[](1);
        data[0] = _exitData(RECIPIENT, 0, address(vault), 100e18); // burn-only, still changes supply
        uint256[] memory values = new uint256[](1);

        vm.expectRevert(
            ManagerWithMerkleVerification
                .ManagerWithMerkleVerification__TotalSupplyMustRemainConstantDuringManagement
                .selector
        );
        manager.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    // --- hard-scoping guards -------------------------------------------------

    function testRejectsNonExitSelector() external {
        bytes memory notExit = abi.encodeWithSignature("transfer(address,uint256)", RECIPIENT, 1);
        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__ExitSelectorRequired
                .selector
        );
        manager.exitVaultWithMerkleVerification(new bytes32[](0), address(decoder), notExit);
    }

    function testRejectsFromNotVault() external {
        // exit with from = an external holder is rejected before any merkle check
        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__ExitFromMustBeVault
                .selector
        );
        manager.exitVaultWithMerkleVerification(
            new bytes32[](0), address(decoder), _exitData(RECIPIENT, 0, address(0xBAD), 100e18)
        );
    }

    // --- CATASTROPHIC-LOSS is now blocked (burn-only) -----------------------

    /// @notice The former drain (burn 1 wei of shares, transfer the ENTIRE asset balance out) is now
    ///         rejected: any non-zero `assetAmount` reverts, so the supply-reducing path can never move
    ///         assets. Asset release happens on a SEPARATE, supply-constant merkle leaf.
    function testExitRejectsAssetTransfer() external {
        _setRootForExit(RECIPIENT, address(vault));
        bytes memory data = _exitData(RECIPIENT, 1000e18, address(vault), 1); // non-zero assetAmount
        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__ExitMustBeBurnOnly
                .selector
        );
        manager.exitVaultWithMerkleVerification(new bytes32[](0), address(decoder), data);

        // nothing moved, nothing burned
        assertEq(asset.balanceOf(RECIPIENT), 0);
        assertEq(vault.totalSupply(), 1000e18);
    }

    // --- fuzz: the guards that DO exist -------------------------------------

    /// @notice The supply drops by EXACTLY the shares the exit claimed to burn, for any valid amount.
    function testFuzz_exitBurnsExactShareAmount(uint256 shareAmt) external {
        shareAmt = bound(shareAmt, 0, 1000e18); // vault only holds 1000 treasury shares
        _setRootForExit(RECIPIENT, address(vault));
        bytes memory data = _exitData(RECIPIENT, 0, address(vault), shareAmt); // burn only, no asset out
        manager.exitVaultWithMerkleVerification(new bytes32[](0), address(decoder), data);
        assertEq(vault.totalSupply(), 1000e18 - shareAmt, "supply != exactly shareAmount burned");
        assertEq(asset.balanceOf(address(vault)), 1000e18, "asset must NOT move");
    }

    function testFuzz_anyNonZeroAssetAmountReverts(uint256 assetAmt) external {
        assetAmt = bound(assetAmt, 1, type(uint256).max); // any non-zero amount is rejected
        _setRootForExit(RECIPIENT, address(vault));
        bytes memory data = _exitData(RECIPIENT, assetAmt, address(vault), 100e18);
        vm.expectRevert(
            ManagerWithMerkleAndTokenBalanceVerification
                .ManagerWithMerkleAndTokenBalanceVerification__ExitMustBeBurnOnly
                .selector
        );
        manager.exitVaultWithMerkleVerification(new bytes32[](0), address(decoder), data);
    }

}
