// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test } from "@forge-std/Test.sol";

/**
 * @notice Fork harness for the vmUSD integration tests, gated on `LIVE_DEPLOY_READ_FILE_NAME`.
 * @dev    These suites deploy the whole vault stack against a mainnet fork, so they need an RPC and a
 *         config file name. A bare `forge test` (the `pre-push` hook, CI) has neither, and `.env` points
 *         `L1_RPC_URL` at a public endpoint that is not always up — so without this guard the suites fail
 *         the hook for reasons unrelated to the code under test.
 *
 *         Mirrors the `ForkStart` pattern already used by `XautCrossChainWiring.t.sol`: create the fork
 *         only when the live env is present, otherwise stub CreateX so `BaseScript`'s constructor-time
 *         presence check passes, and let each `setUp` call `vm.skip(true)` before CreateX is ever used.
 *
 *         To actually run them:
 *           LIVE_DEPLOY_READ_FILE_NAME=vmUSD.json \
 *             forge test --mp test/VmUsd*.t.sol --fork-url $L1_RPC_URL
 */
abstract contract VmUsdForkBase is Test {

    address internal constant CANONICAL_CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /**
     * @dev Last block BEFORE the vmUSD mainnet deploy (first deploy tx landed in 26292873). Only needed if
     *      you want to replay the PRODUCTION config (`vmUSD.json`, entropy `vmUSD1`): its CREATE3 salts are
     *      consumed on mainnet, so against latest state every `deployCreate3` reverts
     *      `FailedContractCreation`. Pass `FORK_BLOCK=26292872` for that — but note a historical block makes
     *      these archive requests, which free public RPCs reject.
     *
     *      By default the suites run at LATEST against `vmUSD-test.json`, whose entropy is unused, so they
     *      need no archive access and keep working as mainnet moves on.
     */
    uint256 internal constant PRE_DEPLOY_BLOCK = 26_292_872;

    /// @dev True when the live-deploy env is present, i.e. these suites should actually run.
    bool internal liveEnvSet;

    constructor() {
        // The fork must start before BaseScript's constructor, which reads CreateX from the chain.
        liveEnvSet = bytes(vm.envOr("LIVE_DEPLOY_READ_FILE_NAME", string(""))).length > 0;
        if (liveEnvSet) {
            _startFork();
        } else {
            vm.etch(vm.envOr("CREATEX", CANONICAL_CREATEX), hex"00");
        }
    }

    /// @dev Creates the fork at latest, or at `FORK_BLOCK` if set. Always creates its own fork rather than
    ///      relying on `--fork-url`, so the suites behave identically however they are invoked.
    function _startFork() internal {
        string memory url = vm.envString("L1_RPC_URL");
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        vm.selectFork(pin == 0 ? vm.createFork(url) : vm.createFork(url, pin));
    }

    /// @dev Call at the top of `setUp`. Returns the config file name, or skips the suite.
    function _liveFileOrSkip() internal returns (string memory file) {
        if (!liveEnvSet) {
            vm.skip(true);
            return "";
        }
        // The fork selected in the constructor does not carry into `setUp` — same foundry quirk noted in
        // LiveDeploy.t.sol (foundry-rs/foundry#5471). Without this, `block.chainid` is still 31337 and the
        // per-chain config lookup reads deployment-config/chains/31337.json.
        _startFork();
        return vm.envString("LIVE_DEPLOY_READ_FILE_NAME");
    }

}
