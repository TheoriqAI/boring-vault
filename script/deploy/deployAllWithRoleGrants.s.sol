// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { stdJson as StdJson } from "@forge-std/StdJson.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { console2 } from "@forge-std/console2.sol";

import { DeployAll } from "./deployAll.s.sol";
import { GrantRolesAndFinalizeOwner } from "./single/13_GrantRolesAndFinalizeOwner.s.sol";

string constant ROLE_GRANT_OUTPUT_JSON_PATH = "./deployment-config/out.json";

/**
 * @title DeployAllWithRoleGrants
 * @notice `deployAll` (steps 02 → 12, unchanged) plus step 13: grant the `postDeploy` roles to every
 *         configured operator address and hand ownership of the system to `postDeploy.finalOwner`.
 * @dev    Nothing in the audited deploy path is modified — this contract only inherits `DeployAll` and
 *         appends step 13. The deployer EOA must equal `protocolAdmin`, because step 11 hands every
 *         contract to `protocolAdmin` before step 13 needs owner rights to re-wire roles.
 *
 *         Entrypoints:
 *           - `runWithRoleGrants(string)`    — script/broadcast use; also writes `out.json`
 *           - `runLiveTestWithRoleGrants(string)` — fork-test use; skips all json writing
 */
contract DeployAllWithRoleGrants is DeployAll {

    using StdJson for string;
    using Strings for address;

    /// @notice Full deploy + role grants + final ownership hand-off, writing addresses to `out.json`.
    function runWithRoleGrants(string memory deployFile) public {
        run(deployFile);
        _grant(deployFile);

        // `run()` writes the core addresses; the withdraw queue and its fee module are only known here.
        mainConfig.withdrawQueue.toHexString().write(ROLE_GRANT_OUTPUT_JSON_PATH, ".withdrawQueue");
        console2.log("Withdraw Queue: ", mainConfig.withdrawQueue);

        writeSalts();
    }

    /**
     * @notice Writes every CreateX salt this deployment used to
     *         `deployment-config/out-<nameEntropy>-salts.json`, so a later deployment (another chain, another
     *         deployer) can reuse them verbatim instead of re-deriving them.
     * @dev    The salts are recomputed here with the SAME `makeConfigSalt` the deploy scripts used, so the
     *         file cannot drift from what was actually broadcast. With `sharedSalt: true` the recorded salts
     *         are deployer-independent and any deployer reproduces these addresses on any chain; with
     *         `sharedSalt: false` they are bound to `saltOwner` and only that address can use them.
     */
    function writeSalts() public {
        string[9] memory suffixes = [
            ":BoringVault",
            ":FreezeListBeforeTransferHook",
            ":ManagerWithMerkleVerification",
            ":AccountantWithRateProviders",
            ":MultiChainLayerZeroTellerWithMultiAssetSupport",
            ":RolesAuthority",
            ":WithdrawQueueAssetSpecificFeeModule",
            ":WithdrawQueue",
            ":GenericDecoderAndSanitizer"
        ];

        address saltOwner = mainConfig.sharedSalt ? SHARED_SALT_SENTINEL : broadcaster;
        string memory json = string.concat(
            '{\n  "nameEntropy": "',
            mainConfig.nameEntropy,
            '",\n  "sharedSalt": ',
            mainConfig.sharedSalt ? "true" : "false",
            ',\n  "saltOwner": "',
            saltOwner.toHexString(),
            '",\n  "note": "',
            mainConfig.sharedSalt
                ?
                "Deployer-independent (CreateX SenderBytes.Random): any deployer reproduces these addresses on any chain. Also means anyone who has these salts can claim the addresses -- verify bytecode on every chain."
                : "Deployer-bound (CreateX permissioned deploy protection): only saltOwner can use these salts.",
            '",\n  "salts": {'
        );

        for (uint256 i; i < suffixes.length; ++i) {
            // Strip the leading ':' so the key reads as a plain contract name.
            string memory contractName = _stripLeadingColon(suffixes[i]);
            json = string.concat(
                json,
                i == 0 ? "\n" : ",\n",
                '    "',
                contractName,
                '": { "entropy": "',
                mainConfig.nameEntropy,
                suffixes[i],
                '", "salt": "',
                vm.toString(makeConfigSalt(mainConfig, suffixes[i])),
                '" }'
            );
        }
        json = string.concat(json, "\n  }\n}\n");

        string memory path = string.concat("./deployment-config/out-", mainConfig.nameEntropy, "-salts.json");
        vm.writeFile(path, json);
        console2.log("Salts written to", path);
    }

    function _stripLeadingColon(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length - 1);
        for (uint256 i = 1; i < b.length; ++i) {
            out[i - 1] = b[i];
        }
        return string(out);
    }

    /// @notice Same flow for fork tests: no json output, so it works under `forge test`.
    function runLiveTestWithRoleGrants(string memory deployFile) public {
        runLiveTest(deployFile);
        _grant(deployFile);
    }

    function _grant(string memory deployFile) internal {
        string memory json = vm.readFile(string.concat(CONFIG_PATH_ROOT, deployFile));
        new GrantRolesAndFinalizeOwner().grant(mainConfig, json);
        console2.log("Role grants and final ownership transfer complete");
    }

}
