// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Script, stdJson } from "@forge-std/Script.sol";
import { console2 } from "@forge-std/console2.sol";
import {
    MultiChainLayerZeroTellerWithMultiAssetSupport
} from "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";

/**
 * @title WireLZPeers
 * @notice Post-deploy LayerZero peer wiring for a MultiChainLayerZeroTeller that was deployed with
 *         `setupLZConfigs: false`. Run ONCE PER CHAIN, broadcast from the teller OWNER (protocolAdmin),
 *         passing that chain's deployment-config file and the (deterministic, same-on-both-chains)
 *         teller address. Wires the local teller to its sibling on the config's `peerEid`, using the
 *         LayerZero DEFAULT send/receive libraries + DVNs (fine for a first version; pin a ULN/DVN
 *         config from the multisig for production).
 *
 * @dev Because the teller is deployed via CREATE3 with the same (deployer, nameEntropy), its address is
 *      identical on both chains — so the peer teller == this teller address.
 *
 * Example (mainnet, then celo):
 *   forge script script/WireLZPeers.s.sol --sig "run(string,address)" \
 *     testTqGOLD-L1.json 0x19B7e216A8F8c1cb76e2b181f4f9a5856a87ED3A \
 *     --rpc-url http://127.0.0.1:8545 --sender 0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631 \
 *     --broadcast --slow --private-key $PRIVATE_KEY
 *   forge script script/WireLZPeers.s.sol --sig "run(string,address)" \
 *     testTqGOLD-L2.json 0x19B7e216A8F8c1cb76e2b181f4f9a5856a87ED3A \
 *     --rpc-url https://forno.celo.org --sender 0xA072... --broadcast --slow --private-key $PRIVATE_KEY
 */
contract WireLZPeers is Script {

    using stdJson for string;

    string constant CONFIG_ROOT = "./deployment-config/";

    function run(string memory configFile, address tellerAddr) external {
        string memory cfg = vm.readFile(string.concat(CONFIG_ROOT, configFile));

        uint32 peerEid = uint32(cfg.readUint(".teller.peerEid"));
        uint64 maxGas = uint64(cfg.readUint(".teller.maxGasForPeer"));
        uint64 minGas = uint64(cfg.readUint(".teller.minGasForPeer"));
        require(peerEid != 0, "WireLZPeers: peerEid == 0 (set it in the config)");
        require(tellerAddr.code.length != 0, "WireLZPeers: no teller code at address");
        require(maxGas != 0, "WireLZPeers: maxGasForPeer == 0");

        MultiChainLayerZeroTellerWithMultiAssetSupport teller =
            MultiChainLayerZeroTellerWithMultiAssetSupport(tellerAddr);

        // Same teller address on the peer chain (deterministic CREATE3), left-padded to bytes32.
        bytes32 peer = bytes32(uint256(uint160(tellerAddr)));
        require(
            peer < 0x0000000000000000000000010000000000000000000000000000000000000000,
            "WireLZPeers: peer not left-padded"
        );

        vm.startBroadcast();
        teller.setPeer(peerEid, peer);
        teller.addChain(peerEid, true, true, tellerAddr, maxGas, minGas);
        vm.stopBroadcast();

        // Post-checks
        require(teller.peers(peerEid) == peer, "WireLZPeers: peer not set");
        (bool allowFrom, bool allowTo, address target,,) = teller.selectorToChains(peerEid);
        require(allowFrom && allowTo && target == tellerAddr, "WireLZPeers: chain not added");

        console2.log("Wired teller:", tellerAddr);
        console2.log("  peerEid:", peerEid);
        console2.log("  maxGasForPeer:", maxGas);
    }

}
