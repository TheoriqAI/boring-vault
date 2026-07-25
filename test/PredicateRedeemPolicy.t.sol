// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { PredicateRedeemPolicy } from "src/helper/PredicateRedeemPolicy.sol";
import { Statement, Attestation } from "@predicate/interfaces/IPredicateRegistry.sol";

/// @dev Minimal registry stub matching the selectors PredicateClient calls: setPolicyID + validateAttestation.
contract MockPredicateRegistry {

    bool public result = true;

    function setResult(bool r) external {
        result = r;
    }

    function setPolicyID(string memory) external { }

    function validateAttestation(Statement memory, Attestation memory) external view returns (bool) {
        return result;
    }

}

contract PredicateRedeemPolicyTest is Test {

    MockPredicateRegistry registry;
    PredicateRedeemPolicy policy;
    address redeemer = makeAddr("basketRedeemer");
    address user = makeAddr("user");

    function setUp() public {
        registry = new MockPredicateRegistry();
        policy = new PredicateRedeemPolicy(address(this), address(registry), "policy-1");
        policy.setRedeemer(redeemer);
    }

    function _auth() internal view returns (bytes memory) {
        return abi.encode(
            Attestation({ uuid: "uuid-1", expiration: block.timestamp + 1 hours, attester: address(1), signature: "" })
        );
    }

    function test_enabled_defaultsTrue() public view {
        assertTrue(policy.enabled(), "secure-by-default: enforced on deploy");
    }

    function test_constructor_rejectsZeroRegistry() public {
        vm.expectRevert(PredicateRedeemPolicy.ZeroAddress.selector);
        new PredicateRedeemPolicy(address(this), address(0), "p");
    }

    function test_onlyRedeemer_mayCall_whenEnabled() public {
        vm.expectRevert(abi.encodeWithSelector(PredicateRedeemPolicy.NotRedeemer.selector, user));
        vm.prank(user);
        policy.authorizeRedeem(user, user, 1e6, _auth());
    }

    function test_allows_whenRegistryVerifies() public {
        registry.setResult(true);
        vm.prank(redeemer);
        policy.authorizeRedeem(user, user, 1e6, _auth()); // no revert
    }

    function test_denies_whenRegistryRejects() public {
        registry.setResult(false);
        vm.expectRevert(PredicateRedeemPolicy.UnauthorizedTransaction.selector);
        vm.prank(redeemer);
        policy.authorizeRedeem(user, user, 1e6, _auth());
    }

    function test_disabled_isNoOp_evenForNonRedeemer() public {
        policy.setEnabled(false);
        // disabled short-circuits before the redeemer check and before any decode => pure no-op
        vm.prank(user);
        policy.authorizeRedeem(user, user, 1e6, "");
    }

}
