// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { ICreateX } from "lib/createx/src/ICreateX.sol";

import { ForkTest } from "test/LiveDeploy.t.sol";

/**
 * @notice Proves the `sharedSalt` property directly against the real mainnet CreateX: a salt whose first 20
 *         bytes are the shared sentinel yields the SAME address from two different deployers, while a
 *         deployer-bound salt yields different addresses (and cannot be used by anyone else at all).
 * @dev    Deliberately independent of the vault deploy — this tests the salt mechanism itself, so a change
 *         to `makeConfigSalt` that silently broke the cross-deployer property would fail here.
 *
 *           forge test --mp test/SharedSalt.t.sol --fork-url $L1_RPC_URL
 */
contract SharedSaltTest is ForkTest {

    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);
    address constant SHARED_SALT_SENTINEL = 0x0000000000000000000000000000000000005A17;

    // Minimal valid init code: PUSH1 0x01, PUSH1 0x00, RETURN -> deploys a single 0x00 (STOP) byte.
    // CreateX reverts FailedContractCreation on empty resulting code, so this must return at least 1 byte.
    bytes constant TRIVIAL_INIT_CODE = hex"60016000f3";

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    /// @dev Mirrors `BaseScript.makeSalt`: owner(20) ‖ flag(1) ‖ bytes11(keccak256(entropy)).
    function _salt(address owner, string memory entropy) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(owner, bytes1(0x00), bytes11(keccak256(abi.encodePacked(entropy)))));
    }

    /// @notice THE PROPERTY: a sentinel-prefixed salt is deployer-independent.
    function testSharedSaltGivesTheSameAddressForDifferentDeployers() public {
        bytes32 salt = _salt(SHARED_SALT_SENTINEL, "vmUSD1:BoringVault");

        vm.prank(alice);
        address fromAlice = CREATEX.computeCreate3Address(keccak256(abi.encode(salt)));
        vm.prank(bob);
        address fromBob = CREATEX.computeCreate3Address(keccak256(abi.encode(salt)));

        assertEq(fromAlice, fromBob, "shared salt must be deployer-independent");

        // And it really deploys there, from a deployer that is not the salt prefix.
        vm.prank(bob);
        address deployed = CREATEX.deployCreate3(salt, TRIVIAL_INIT_CODE);
        assertEq(deployed, fromAlice, "bob deployed to the address alice would have computed");
    }

    /// @notice A deployer-bound salt (the default) is NOT reusable: different deployers get different
    ///         addresses, and a non-owner cannot use someone else's salt at all.
    function testDeployerBoundSaltIsNotPortable() public {
        bytes32 aliceSalt = _salt(alice, "vmUSD1:BoringVault");

        // Alice's salt resolves through the permissioned branch: guardedSalt folds in msg.sender.
        vm.prank(alice);
        address aliceAddr = CREATEX.deployCreate3(aliceSalt, TRIVIAL_INIT_CODE);

        bytes32 bobSalt = _salt(bob, "vmUSD1:BoringVault");
        vm.prank(bob);
        address bobAddr = CREATEX.deployCreate3(bobSalt, TRIVIAL_INIT_CODE);

        assertTrue(aliceAddr != bobAddr, "deployer-bound salts must not collide across deployers");

        // Bob using ALICE's salt lands on a third address (the Random branch), not Alice's — i.e. he can
        // never occupy the address Alice's salt reserves for her.
        vm.prank(bob);
        address bobUsingAliceSalt = CREATEX.deployCreate3(aliceSalt, TRIVIAL_INIT_CODE);
        assertTrue(bobUsingAliceSalt != aliceAddr, "alice's reserved address must be unreachable by bob");
    }

    /// @notice The flip side of `sharedSalt`, stated as a test so it is impossible to forget: once the salt
    ///         is known, ANY address can claim the slot — including with code of their choosing. This is the
    ///         front-run exposure that the deployer-bound default protects against.
    function testSharedSaltSlotIsClaimableByAnyoneAndThenBurned() public {
        bytes32 salt = _salt(SHARED_SALT_SENTINEL, "vmUSD1:SomeFutureChainContract");

        address squatter = makeAddr("salt squatter");
        vm.prank(squatter);
        address claimed = CREATEX.deployCreate3(salt, TRIVIAL_INIT_CODE);

        // The rightful deployer now cannot use that salt — the slot is gone on this chain.
        vm.prank(alice);
        vm.expectRevert();
        CREATEX.deployCreate3(salt, TRIVIAL_INIT_CODE);

        assertGt(uint160(claimed), 0, "claimed by a stranger");
    }

}
