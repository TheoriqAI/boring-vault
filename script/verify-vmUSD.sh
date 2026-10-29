#!/usr/bin/env bash
#
# Verify the vmUSD contracts on Etherscan (V2 API, chain 1).
#
# WHY this exists: every contract is deployed by CreateX via CREATE3, so the broadcast transaction targets
# CreateX, not the contract. `forge script --verify` frequently misses factory-deployed contracts, and the
# constructor args are NOT recoverable from the tx in an obvious way. This script re-encodes them exactly as
# the deploy scripts did.
#
# IMPORTANT: constructor args capture the state at DEPLOY time — owner is the DEPLOYER (0xA072…), not the
# final owner (0xCB06…). Ownership is transferred afterwards by steps 11/13, which does not change the
# constructor args.
#
# Usage:
#   ./script/verify-vmUSD.sh                      # reads deployment-config/out-vmUSD.json
#   ./script/verify-vmUSD.sh path/to/out.json
#   ONLY=WithdrawQueue ./script/verify-vmUSD.sh    # verify a single contract
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-./deployment-config/out-vmUSD.json}"
[ -f "$OUT" ] || { echo "!! no address file at $OUT (pass one as \$1)"; exit 1; }

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a
: "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY in .env}"
ETH_RPC="${ETH_RPC:-${L1_RPC_URL:-}}"
[ -n "$ETH_RPC" ] || { echo "!! set ETH_RPC (or L1_RPC_URL)"; exit 1; }

DEPLOYER="${DEPLOYER:-0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631}"   # == protocolAdmin at deploy time
BASE=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48                      # USDC
BALANCER=0xBA12222222228d8Ba445958a75a0704d566BF2C8
LZ_ENDPOINT=0x1a44076050125825900e736c501f859c50fE728c
UNIV3_NFPM=0xC36442b4a4522E871399CD717aBDD847Ab11FE88
DECIMALS=6
START_RATE=1000000          # 10 ** 6, the accountant's starting exchange rate
RATE_UPPER=10004
RATE_LOWER=10000
MIN_DELAY=3600
MGMT_FEE=0
PERF_FEE=0
VAULT_NAME="vmUSD"
VAULT_SYMBOL="vmUSD"
QUEUE_NAME="VaultMason USD Vault Withdraw Queue"
QUEUE_SYMBOL="vmUSDQ"
MIN_ORDER=1000000

j () { jq -r ".$1" "$OUT"; }
BORING_VAULT=$(j boringVault)
HOOK=$(j freezeListBeforeTransferHook)
MANAGER=$(j manager)
ACCOUNTANT=$(j accountant)
TELLER=$(j teller)
ROLES=$(j rolesAuthority)
QUEUE=$(j withdrawQueue)
DECODER=$(j genericDecoderAndSanitizer)
# The fee module is not in out.json — read it off the queue.
FEE_MODULE=$(cast call "$QUEUE" "feeModule()(address)" --rpc-url "$ETH_RPC")

echo "deployer/ctor-owner: $DEPLOYER"
echo "fee module (from chain): $FEE_MODULE"
echo

verify () {
  local name="$1" addr="$2" path="$3" args="$4"
  if [ -n "${ONLY:-}" ] && [ "${ONLY}" != "$name" ]; then return 0; fi
  [ "$addr" != "null" ] && [ -n "$addr" ] || { echo "-- skip $name (no address)"; return 0; }
  echo "== verifying $name  $addr"
  # shellcheck disable=SC2086
  forge verify-contract "$addr" "$path" \
    --chain-id 1 --watch --constructor-args "$args" || echo "!! $name FAILED — see notes at the bottom"
  echo
}

verify BoringVault "$BORING_VAULT" "src/base/BoringVault.sol:BoringVault" \
  "$(cast abi-encode 'c(address,string,string,uint8)' "$DEPLOYER" "$VAULT_NAME" "$VAULT_SYMBOL" $DECIMALS)"

verify FreezeListBeforeTransferHook "$HOOK" \
  "src/helper/FreezeListBeforeTransferHook.sol:FreezeListBeforeTransferHook" \
  "$(cast abi-encode 'c(address)' "$DEPLOYER")"

# NOTE 04_Deploy appends a stray 4th word (`18`) after the 3 real constructor args. The constructor ignores
# trailing data, but the on-chain arg blob is 4 words. If Etherscan rejects the 3-arg encoding below, retry
# with the 4-arg form: cast abi-encode 'c(address,address,address,uint8)' ... 18
verify ManagerWithMerkleVerification "$MANAGER" \
  "src/base/Roles/ManagerWithMerkleVerification.sol:ManagerWithMerkleVerification" \
  "$(cast abi-encode 'c(address,address,address)' "$DEPLOYER" "$BORING_VAULT" "$BALANCER")"

verify AccountantWithRateProviders "$ACCOUNTANT" \
  "src/base/Roles/AccountantWithRateProviders.sol:AccountantWithRateProviders" \
  "$(cast abi-encode 'c(address,address,address,uint96,address,uint16,uint16,uint32,uint16,uint16)' \
      "$DEPLOYER" "$BORING_VAULT" "$DEPLOYER" $START_RATE "$BASE" \
      $RATE_UPPER $RATE_LOWER $MIN_DELAY $MGMT_FEE $PERF_FEE)"

verify Teller "$TELLER" \
  "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol:MultiChainLayerZeroTellerWithMultiAssetSupport" \
  "$(cast abi-encode 'c(address,address,address,address)' "$DEPLOYER" "$BORING_VAULT" "$ACCOUNTANT" "$LZ_ENDPOINT")"

verify RolesAuthority "$ROLES" \
  "lib/solmate/src/auth/authorities/RolesAuthority.sol:RolesAuthority" \
  "$(cast abi-encode 'c(address,address)' "$DEPLOYER" 0x0000000000000000000000000000000000000000)"

verify WithdrawQueueAssetSpecificFeeModule "$FEE_MODULE" \
  "src/helper/WithdrawQueueAssetSpecificFeeModule.sol:WithdrawQueueAssetSpecificFeeModule" \
  "$(cast abi-encode 'c(address,address)' "$DEPLOYER" "$ACCOUNTANT")"

verify WithdrawQueue "$QUEUE" "src/base/Roles/WithdrawQueue.sol:WithdrawQueue" \
  "$(cast abi-encode 'c(string,string,address,address,address,uint256,address,address)' \
      "$QUEUE_NAME" "$QUEUE_SYMBOL" "$DEPLOYER" "$TELLER" "$FEE_MODULE" $MIN_ORDER "$DEPLOYER" "$DEPLOYER")"

verify GenericDecoderAndSanitizer "$DECODER" \
  "src/base/DecodersAndSanitizers/GenericDecoderAndSanitizer.sol:GenericDecoderAndSanitizer" \
  "$(cast abi-encode 'c(address,address)' "$BORING_VAULT" "$UNIV3_NFPM")"

cat <<'NOTES'
If any contract failed:
  * "Already Verified"      -> fine, nothing to do.
  * bytecode mismatch       -> check optimizer settings match foundry.toml, and that you are on the exact
                              commit that was deployed (`git rev-parse HEAD`). Metadata hash differences are
                              the usual cause; try --compiler-version to pin the exact solc.
  * constructor args        -> the args above are DEPLOY-time (owner = the deployer, not the final owner).
                              For the manager, retry with the stray 4th word (see the note in this script).
  * Retry one at a time with:  ONLY=WithdrawQueue ./script/verify-vmUSD.sh
NOTES
