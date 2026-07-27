// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { RolesAuthority, Authority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { EpochDepositor } from "src/helper/EpochDepositor.sol";
import { MockToken, MockAccountant } from "./EpochDepositor.t.sol";

/// @notice Drives random valid-ish sequences against the depositor. Every action swallows reverts so the
///         fuzzer explores freely; the invariants below must hold after any sequence.
contract EpochDepositorHandler is Test {

    EpochDepositor internal immutable depositor;
    MockToken internal immutable asset;
    MockAccountant internal immutable accountant;
    address[] internal actors;

    uint256 internal constant MIN = 100e18;
    uint64 internal constant EPOCH = 7 days;

    constructor(EpochDepositor _d, MockToken _a, MockAccountant _acc, address[] memory _actors) {
        depositor = _d;
        asset = _a;
        accountant = _acc;
        actors = _actors;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function requestDeposit(uint256 actorSeed, uint256 amt) external {
        address a = _actor(actorSeed);
        uint256 lo = depositor.deposited(depositor.currentEpoch(), a) == 0 ? MIN : 1;
        amt = bound(amt, lo, 10_000e18);
        vm.prank(a);
        try depositor.requestDeposit(amt, a, a) { } catch { }
    }

    function cancel(uint256 actorSeed, uint256 amt, bool full) external {
        address a = _actor(actorSeed);
        uint256 bal = depositor.deposited(depositor.currentEpoch(), a);
        if (bal == 0) return;
        if (full) {
            vm.prank(a);
            try depositor.cancelAll(a) { } catch { }
        } else {
            amt = bound(amt, 1, bal);
            vm.prank(a);
            try depositor.cancelDeposit(amt, a) { } catch { }
        }
    }

    function warpClose(uint256 warpSeed) external {
        vm.warp(block.timestamp + bound(warpSeed, 1 hours, EPOCH + 2 days));
        try depositor.closeEpoch() { } catch { }
    }

    function claim(uint256 actorSeed, uint256 epochSeed) external {
        address a = _actor(actorSeed);
        uint256 e = bound(epochSeed, 0, depositor.currentEpoch());
        vm.prank(a);
        try depositor.claim(e, a, a) { } catch { }
    }

    function atomicMint(uint256 recvSeed, uint256 amt) external {
        address r = _actor(recvSeed);
        amt = bound(amt, 1e18, 10_000e18);
        asset.mint(address(this), amt);
        asset.approve(address(depositor), amt);
        try depositor.atomicMint(r, amt, 0) { } catch { }
    }

    function setRate(uint256 r) external {
        accountant.setRate(bound(r, 0.5e18, 5e18)); // sane band: never trips the zero-shares guard
    }

}

contract EpochDepositorInvariantTest is Test {

    BoringVault internal vault;
    MockToken internal asset;
    MockAccountant internal accountant;
    EpochDepositor internal depositor;
    RolesAuthority internal auth;
    EpochDepositorHandler internal handler;
    address[] internal actors;

    uint256 internal constant ONE = 1e18;

    function setUp() external {
        vault = new BoringVault(address(this), "Boring Vault", "BV", 18);
        asset = new MockToken("USD", "USD");
        accountant = new MockAccountant(ONE);
        depositor = new EpochDepositor(
            address(this), address(vault), address(accountant), address(asset), 7 days, 100e18, address(0xFEE)
        );

        auth = new RolesAuthority(address(this), Authority(address(0)));
        vault.setAuthority(auth);
        auth.setRoleCapability(1, address(vault), BoringVault.enter.selector, true);
        auth.setUserRole(address(depositor), 1, true);

        for (uint256 i; i < 4; ++i) {
            address u = address(uint160(0x100000 + i));
            actors.push(u);
            asset.mint(u, 100_000_000e18);
            vm.prank(u);
            asset.approve(address(depositor), type(uint256).max);
        }

        handler = new EpochDepositorHandler(depositor, asset, accountant, actors);
        // Hand ownership to the handler so it can call the trusted `atomicMint` path during fuzzing.
        depositor.transferOwnership(address(handler));

        targetContract(address(handler));
    }

    /// @notice The pool must always hold enough shares to cover every outstanding claimable position, and
    ///         enough escrowed asset to cover every open/refundable deposit. This is the property the audit
    ///         reasoned through by hand (no cross-epoch or atomic-mint drain, dust-only surplus).
    function invariant_poolCoversClaimsAndEscrow() external view {
        uint256 claimableShares;
        uint256 escrowAssets;
        uint256 cur = depositor.currentEpoch();
        for (uint256 e; e <= cur; ++e) {
            (,, bool settled,, uint256 total, uint256 sharesMinted,) = depositor.epochs(e);
            for (uint256 i; i < actors.length; ++i) {
                uint256 dep = depositor.deposited(e, actors[i]);
                if (dep == 0) continue;
                if (settled) {
                    if (total != 0) claimableShares += (dep * sharesMinted) / total;
                } else {
                    escrowAssets += dep; // open or refundable: assets still held here
                }
            }
        }
        assertGe(vault.balanceOf(address(depositor)), claimableShares, "pool < outstanding claimable shares");
        assertGe(asset.balanceOf(address(depositor)), escrowAssets, "escrow < open/refundable deposits");
    }

    /// @notice Every epoch listed in a controller's live set has a non-zero position (set stays consistent).
    function invariant_liveSetMatchesDeposits() external view {
        for (uint256 i; i < actors.length; ++i) {
            uint256[] memory live = depositor.liveEpochs(actors[i]);
            for (uint256 j; j < live.length; ++j) {
                assertGt(depositor.deposited(live[j], actors[i]), 0, "live epoch has zero deposit");
            }
        }
    }

}
