#!/usr/bin/env bash
#
# Deploy the "vmUSD" vault — Ethereum MAINNET ONLY.
#   base asset   : USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 6 decimals
#   teller       : MultiChainLayerZeroTellerWithMultiAssetSupport (LZ V2 endpoint set, NO peer wired)
#   redeem queue : src/base/Roles/WithdrawQueue.sol (the audited queue) + asset-specific fee module
#   deploy admin : OVERRIDE_PROTOCOL_ADMIN (default 0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631)
#   final owner  : deployment-config/vmUSD.json -> postDeploy.finalOwner
#                  (0xCB068924bb3D2Ebb28BD1BB25b09ec15b0D5a03B)
#   roles        : every role in postDeploy.roles granted to BOTH operator addresses
#
# Usage:
#   ./script/deploy-vmUSD.sh test        # fork tests only  (deploy + role/owner assertions)
#   ./script/deploy-vmUSD.sh dry         # fork tests + full deploy simulation  (DEFAULT)
#   ./script/deploy-vmUSD.sh simulate    # deploy simulation only, no tests
#   ./script/deploy-vmUSD.sh broadcast   # REAL deploy
#   ./script/deploy-vmUSD.sh resume      # RECOVERY: re-send only the txs that did not land
#
# Env:
#   ETH_RPC    required — mainnet RPC / your tunnel to a node (e.g. http://127.0.0.1:8545).
#              Falls back to L1_RPC_URL from .env.
#   SENDER     the deployer EOA. MUST equal OVERRIDE_PROTOCOL_ADMIN: step 11 hands every contract to the
#              protocol admin, and step 13 then needs owner rights to grant roles + hand over ownership.
#   SIGNER_ARGS  OPTIONAL. Leave unset to sign with PRIVATE_KEY from .env (the hot-wallet path; the script
#              checks it controls SENDER first). Set it to override, e.g. SIGNER_ARGS="--ledger".
#
# NOTE this repo's .env overloads L1_RPC_URL/L2_RPC_URL across chains — prefer setting ETH_RPC explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG_FILE="vmUSD.json"

export CREATEX="${CREATEX:-0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed}"
export OVERRIDE_PROTOCOL_ADMIN="${OVERRIDE_PROTOCOL_ADMIN:-0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631}"

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a
ETH_RPC="${ETH_RPC:-${L1_RPC_URL:-}}"
[ -n "$ETH_RPC" ] || { echo "!! set ETH_RPC (or L1_RPC_URL) to a mainnet RPC"; exit 1; }

MODE="${1:-dry}"

SENDER="${SENDER:-$OVERRIDE_PROTOCOL_ADMIN}"
export ETH_FROM="$SENDER"
export L1_RPC_URL="$ETH_RPC"   # the fork tests read L1_RPC_URL
export LIVE_DEPLOY_READ_FILE_NAME="$CONFIG_FILE"

if [ "$(echo "$SENDER" | tr 'A-Z' 'a-z')" != "$(echo "$OVERRIDE_PROTOCOL_ADMIN" | tr 'A-Z' 'a-z')" ]; then
  echo "!! SENDER ($SENDER) must equal OVERRIDE_PROTOCOL_ADMIN ($OVERRIDE_PROTOCOL_ADMIN)."
  echo "!! Step 13 grants roles / transfers ownership as the protocol admin."
  exit 1
fi

CHAIN_ID="$(cast chain-id --rpc-url "$ETH_RPC")"
[ "$CHAIN_ID" = "1" ] || { echo "!! ETH_RPC is chain $CHAIN_ID, expected 1 (Ethereum mainnet)"; exit 1; }

echo "== vmUSD =="
echo "   config      : deployment-config/$CONFIG_FILE"
echo "   chain       : $CHAIN_ID"
echo "   deployer    : $SENDER"
echo "   deploy admin: $OVERRIDE_PROTOCOL_ADMIN"
echo "   final owner : $(jq -r '.postDeploy.finalOwner' "deployment-config/$CONFIG_FILE")"
echo

run_tests () {
  echo "== [1/5] core deploy fork test (LiveDeploy) =="
  # testDepositAndBridge is excluded: setupLZConfigs=false means no LZ peer is wired at deploy, so the
  # bridge path reverts NoPeer() by design. Peers are wired post-deploy by the owner if/when a second
  # chain goes live.
  forge test --mp test/LiveDeploy.t.sol --fork-url "$ETH_RPC" --no-match-test testDepositAndBridge -vv

  echo "== [2/5] roles + ownership fork test =="
  forge test --mp test/VmUsdRolesAndOwnership.t.sol --fork-url "$ETH_RPC" -vv

  echo "== [3/5] end-user deposit/redeem fork test =="
  forge test --mp test/VmUsdUserFlows.t.sol --fork-url "$ETH_RPC" -vv

  echo "== [4/5] Safe-as-recipient fork test =="
  forge test --mp test/VmUsdSafeRecipient.t.sol --fork-url "$ETH_RPC" -vv

  echo "== [5/5] CreateX shared-salt property =="
  forge test --mp test/SharedSalt.t.sol --fork-url "$ETH_RPC" -vv
}

run_deploy () {
  local extra="--sender $SENDER"
  if [ "$MODE" = "broadcast" ] || [ "$MODE" = "resume" ]; then
    # Signer resolution, in order:
    #   1. SIGNER_ARGS if you set it explicitly (e.g. "--ledger", "--keystore path")
    #   2. PRIVATE_KEY from .env (hot wallet) — assembled here so the key never enters your shell history
    # Either way we assert the signer actually controls $SENDER before sending anything: a mismatch would
    # otherwise fail partway through, and the salts are single-use per chain.
    if [ -z "${SIGNER_ARGS:-}" ]; then
      [ -n "${PRIVATE_KEY:-}" ] || {
        echo "!! no signer: set PRIVATE_KEY in .env, or pass SIGNER_ARGS (e.g. --ledger)"; exit 1; }
      local derived
      derived="$(cast wallet address --private-key "$PRIVATE_KEY")"
      if [ "$(echo "$derived" | tr 'A-Z' 'a-z')" != "$(echo "$SENDER" | tr 'A-Z' 'a-z')" ]; then
        echo "!! PRIVATE_KEY controls $derived but SENDER is $SENDER — refusing to broadcast."
        exit 1
      fi
      echo ">> signer: PRIVATE_KEY from .env -> $derived (matches SENDER)"
      SIGNER_ARGS="--private-key $PRIVATE_KEY"
    else
      echo ">> signer: SIGNER_ARGS as provided"
    fi
    extra="$extra --broadcast --slow --verify ${SIGNER_ARGS:-}"
    if [ "$MODE" = "resume" ]; then
      # `--resume` replays the saved sequence in broadcast/deployAllWithRoleGrants.s.sol/1/run-latest.json
      # and sends only the transactions that have no receipt. It does NOT re-simulate the script, which is
      # exactly what we need: a fresh simulation would re-run every CREATE3 call and revert on the salts
      # that already landed.
      #
      # Hard requirement: the deployer's nonce must be UNCHANGED since the failed run. Any unrelated tx
      # from this EOA in between shifts the nonces and resume will fail.
      extra="$extra --resume"
      echo ">> RESUME — re-sending only the transactions that did not land."
      echo "   deployer nonce must be unchanged since the failed run. Current: $(cast nonce "$SENDER" --rpc-url "$ETH_RPC")"
    else
      echo ">> BROADCAST — REAL TRANSACTIONS ON MAINNET."
    fi
  else
    echo ">> SIMULATION ONLY (no --broadcast)."
  fi

  # On resume the script body is not executed, so it writes no json — keep whatever is already there.
  [ "$MODE" = "resume" ] || cp ./deployment-config/out-template.json ./deployment-config/out.json
  # shellcheck disable=SC2086
  forge script script/deploy/deployAllWithRoleGrants.s.sol \
    --sig "runWithRoleGrants(string)" "$CONFIG_FILE" \
    --rpc-url "$ETH_RPC" $extra

  if [ "$MODE" = "broadcast" ]; then
    mv ./deployment-config/out.json ./deployment-config/out-vmUSD.json
    echo "Addresses written to deployment-config/out-vmUSD.json"
  elif [ "$MODE" = "resume" ]; then
    echo "Resume complete. No out.json is produced on resume — read the addresses from"
    echo "  broadcast/deployAllWithRoleGrants.s.sol/1/run-latest.json"
    echo "or recompute them from deployment-config/out-vmUSD1-salts.json."
  fi
}

case "$MODE" in
  test)      run_tests ;;
  simulate)  run_deploy ;;
  dry)       run_tests; run_deploy ;;
  broadcast) run_tests; run_deploy ;;
  resume)    run_deploy ;;   # no tests: we are mid-deploy, chain state no longer matches a clean fork
  *) echo "mode must be: test | dry | simulate | broadcast | resume"; exit 1 ;;
esac

echo
echo "Done ($MODE). Post-deploy items that are NOT scripted:"
echo "  1. accountant.updateExchangeRate — only if the starting 1:1 rate is wrong"
echo "  2. manager.setManageRoot(strategist, root) — required before any strategy can run"
echo "  3. LayerZero peer/DVN wiring — only when a second chain goes live (see deployment-config/vmUSD.md)"
echo "Salts for reuse by other deployers: deployment-config/out-vmUSD1-salts.json"
