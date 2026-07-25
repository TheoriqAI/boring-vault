// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";
import { DeployAll } from "script/deploy/deployAll.s.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { TellerWithMultiAssetSupport } from "src/base/Roles/TellerWithMultiAssetSupport.sol";
import { CrossChainTellerBase, BridgeData } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { MultiChainLayerZeroTellerWithMultiAssetSupport } from
    "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";

/**
 * @notice Proves the LayerZero cross-chain path for the nXAUT vault works once the peer is wired.
 * @dev The production configs deploy with `setupLZConfigs=false`, so the teller ships with NO peer
 * (a poisoned DVN cannot reach an unconfigured teller). This test deploys the full stack via the
 * standard deployAll harness, then wires the peer + chain exactly as the protocol-admin multisig
 * would post-deploy, and exercises deposit -> bridge. Run against a Celo fork:
 *   LIVE_DEPLOY_READ_FILE_NAME=xaut-L2.json forge test --mp test/XautCrossChainWiring.t.sol \
 *     --fork-url https://forno.celo.org -vv
 */
abstract contract ForkStart is Test {

    constructor() {
        if (bytes(vm.envOr("LIVE_DEPLOY_READ_FILE_NAME", string(""))).length > 0) {
            if (block.chainid == 31_337) vm.selectFork(vm.createFork(vm.envString("L2_RPC_URL")));
        } else {
            // Not running the live integration test: stub CreateX so the DeployAll base constructor's
            // presence check passes; setUp() then skips before CreateX is ever used.
            vm.etch(vm.envOr("CREATEX", 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed), hex"00");
        }
    }

}

contract XautCrossChainWiring is ForkStart, DeployAll {

    using FixedPointMathLib for uint256;

    ERC20 constant NATIVE_ERC20 = ERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    function setUp() public {
        if (bytes(vm.envOr("LIVE_DEPLOY_READ_FILE_NAME", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        runLiveTest(vm.envString("LIVE_DEPLOY_READ_FILE_NAME"));
        _wirePeer();
    }

    /// @dev Mirrors what 06b does when `setupLZConfigs=true`, minus the interactive DVN/ULN prompt
    /// (LayerZero default libraries are used for the Celo<->Ethereum pathway).
    function _wirePeer() internal {
        MultiChainLayerZeroTellerWithMultiAssetSupport teller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(mainConfig.teller);

        // Deterministic CREATE3 salt => the sibling-chain teller shares this address.
        bytes32 peer = bytes32(uint256(uint160(address(teller))));

        vm.startPrank(mainConfig.protocolAdmin);
        teller.setPeer(uint32(mainConfig.peerEid), peer);
        teller.addChain(
            uint32(mainConfig.peerEid), true, true, address(teller), mainConfig.maxGasForPeer, mainConfig.minGasForPeer
        );
        vm.stopPrank();
    }

    function testWiredDepositAndBridge(uint256 amount) public {
        MultiChainLayerZeroTellerWithMultiAssetSupport teller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(mainConfig.teller);
        BoringVault vault = BoringVault(payable(mainConfig.boringVault));
        AccountantWithRateProviders accountant = AccountantWithRateProviders(mainConfig.accountant);
        ERC20 asset = ERC20(mainConfig.base);

        amount = bound(amount, 0.0001e6, 10_000e6);

        address user = makeAddr("xaut user");
        address userOnPeer = makeAddr("xaut user on peer chain");
        deal(address(asset), user, amount);

        vm.startPrank(user);
        vm.deal(user, 10 ether);
        asset.approve(address(vault), amount);

        // 1. deposit base asset -> receive shares (public capability)
        uint256 shares = teller.deposit(asset, amount, 0);
        assertEq(vault.balanceOf(user), shares, "user should hold minted shares");

        // 2. bridge the shares to the peer chain (public capability)
        BridgeData memory data = BridgeData({
            chainSelector: uint32(mainConfig.peerEid),
            destinationChainReceiver: userOnPeer,
            bridgeFeeToken: NATIVE_ERC20,
            messageGas: 100_000,
            data: ""
        });

        uint256 fee = teller.previewFee(shares, data);
        assertGt(fee, 0, "LZ quote should return a non-zero native fee");

        teller.bridge{ value: fee }(shares, data);
        assertEq(vault.balanceOf(user), 0, "shares should be burned on bridge");
        vm.stopPrank();
    }

}
