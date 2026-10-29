# vmUSD — VaultMason USD Vault (USDC), Ethereum mainnet only

> **STATUS: LIVE on Ethereum mainnet as of 2026-10-28.** Deployed from `0xA072…3631`, all nine contracts
> verified on Etherscan, ownership held by `0xCB06…a03B`. On-chain state verified against this document —
> see §4e. Total cost 0.00474 ETH over 80 transactions.

A single-chain BoringVault on **Ethereum mainnet** with **USDC** as the base asset, the **audited
`WithdrawQueue`** as the redeem path, and the **LayerZero V2 multichain teller** deployed but with no peer
wired (so it is ready for a second chain later without a redeploy).

> **Operator address book** (addresses + the 5-call round trip, with Etherscan links and copyable
> calldata): https://claude.ai/code/artifact/06b5fcbb-2598-4526-81f2-7ce1e36e5add
> Addresses there are the *predicted* ones — refresh it from `out-vmUSD.json` after broadcast.

Deployed via the existing config-driven pipeline (`deployAll.s.sol`, steps 02 → 12, untouched) plus one new
post-deploy step **13** that grants the operator roles to *both* admin addresses and then hands ownership of
the whole system to the second address.

---

## 1. Parameters

| | |
|---|---|
| Chain | Ethereum mainnet (1) |
| Base asset | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, **6 decimals** (`isPegged: true`) |
| Share token | name **VaultMason USD Vault**, symbol **vmUSD**, 6 decimals |
| `nameEntropy` (CREATE3 salt seed) | `vmUSD1` |
| `sharedSalt` | **`true`** — salts are deployer-independent (see §4c) |
| Teller | `MultiChainLayerZeroTellerWithMultiAssetSupport`, endpoint `0x1a44076050125825900e736c501f859c50fE728c`, `setupLZConfigs: false`, `peerEid: 0` |
| Redeem queue | `src/base/Roles/WithdrawQueue.sol` + `WithdrawQueueAssetSpecificFeeModule` (all fees `0`) |
| Queue minimum order | `1000000` = **1 USDC** |
| Accountant | rate bounds `10000` / `10004` bps, min update delay `3600s`, management + performance fee `0` |
| Freeze hook | a fresh `FreezeListBeforeTransferHook` is deployed (config points the vault at `0x0`) |
| DistributorCodeDepositor | not deployed |
| Deploy-time admin (`protocolAdmin`) | `0xA072f8Bd3847E21C8EdaAf38D7425631a2A63631` ("operator A") |
| **Final owner** | `0xCB068924bb3D2Ebb28BD1BB25b09ec15b0D5a03B` ("operator B") |

> `nameEntropy` drives every CREATE3 address, so changing it changes all addresses. Change it only if you
> want a fresh address set.

### Why `peerEid: 0` / `setupLZConfigs: false`

Mainnet-only for now, so there is no peer to point at. The teller still gets its LayerZero endpoint and the
delegate, but no peer and no ULN config — matching the `PAXGy` precedent. An unconfigured teller cannot be
reached even by a poisoned DVN, because the receive path reverts without a matching chain/peer. See §5 for
how to light it up when a second chain goes live.

---

## 2. Roles — both addresses get everything operational

Steps 07/10 of the stock pipeline grant the single `strategist` / `exchangeRateBot` / `processorAddress` from
the config, plus the protocol admin. Step 13 then grants **every role below to both addresses**:

| Role | # | Reaches | Why both addresses need it |
|---|---|---|---|
| `STRATEGIST_ROLE` | 1 | `manager.manageVaultWithMerkleVerification` | curator |
| `UPDATE_EXCHANGE_RATE_ROLE` | 4 | `accountant.updateExchangeRate` | NAV update |
| `SOLVER_ROLE` | 5 | `teller.bulkWithdraw` | direct redeem of own shares (bypasses the queue) |
| `PAUSER_ROLE` | 6 | `pause()` **and `unpause()`** on teller / accountant / manager | incident response |
| `WITHDRAW_QUEUE_PROCESSOR_ROLE` | 9 | `withdrawQueue.processOrders` | withdrawal processing |
| `FREEZE_MANAGER_ROLE` | 10 | `freezeHook.setFreezeList` | compliance freeze |

Edit `postDeploy.roles` / `postDeploy.additionalRoleUsers` in the JSON to change this. Step 13 **refuses** to
grant roles 2 (`MANAGER_ROLE`), 3 (`TELLER_ROLE`), 7 (`DEPOSITOR_ROLE`) and 8 (`SELF_BURN_ROLE`) to any
address — `MANAGER_ROLE` can call `BoringVault.manage` with arbitrary calldata (i.e. drain the vault) and
`TELLER_ROLE` can mint/burn shares; both belong to contracts only. It also asserts every granted role
actually resolves to a live capability, so a role number with no `setRoleCapability` behind it fails the
deploy instead of silently doing nothing.

### Two deliberate deviations from the stock role table, both config flags

| Flag | Default | Effect |
|---|---|---|
| `postDeploy.grantUnpauseToPauserRole` | **`true`** | Adds `unpause()` on teller/accountant/manager to `PAUSER_ROLE`. Stock 07 gives no role `unpause`, so without this the operators can halt the system but only the owner can restart it. |
| `postDeploy.grantQueueAdminToProcessorRole` | `false` | Would add `forceProcessOrders` / `forceProcess` / `refundOrder` / `refundOrders` to `WITHDRAW_QUEUE_PROCESSOR_ROLE`. Left off — those stay owner-only. |

### What stays owner-only (i.e. operator B / `0xCB06…`)

`accountant.updateDelay` / `updateUpper` / `updateLower` / `updateManagementFee` / `updatePerformanceFee` /
`updatePayoutAddress` / `setRateProviderData` / `resetHighestExchangeRate`; `manager.setManageRoot`;
`teller.addDepositAsset` / `addWithdrawAsset` / `setShareLockPeriod` / `setPeer` / `addChain` /
`setDelegate`; all `WithdrawQueue` setters + `manageERC20` + force/refund; and every
`rolesAuthority.setUserRole` / `setRoleCapability`. Solmate's `Auth` short-circuits for `owner`, so operator
B can call anything; operator A can only do what its six roles allow.

### Ownership after step 13

`boringVault`, `manager`, `accountant`, `teller`, `withdrawQueue`, the withdraw-queue fee module, the freeze
hook and `rolesAuthority` are all owned by `0xCB068924bb3D2Ebb28BD1BB25b09ec15b0D5a03B`. The LayerZero
**delegate** on the endpoint is moved to the same address (it is independent of `Auth` ownership — if left
behind, the old admin would keep endpoint-config rights).

`accountant.payoutAddress` and `withdrawQueue.feeRecipient` remain `0xA072…3631` (step 10 *requires*
`feeRecipient == protocolAdmin` at deploy time). Both fees are `0`, so nothing accrues there; the new owner
can repoint them whenever.

---

## 3. Files

**New**
- `deployment-config/vmUSD.json` — the vault config, incl. the new `postDeploy` section and `sharedSalt`
- `script/deploy/single/13_GrantRolesAndFinalizeOwner.s.sol` — step 13 (role grants + final owner)
- `script/deploy/deployAllWithRoleGrants.s.sol` — `deployAll` + step 13 + the salt export
- `test/VmUsdRolesAndOwnership.t.sol` — mainnet-fork test asserting the final role/owner state
- `test/VmUsdUserFlows.t.sol` — mainnet-fork test of the end-user deposit/redeem paths
- `test/VmUsdSafeRecipient.t.sol` — mainnet-fork test: real Safes depositing and redeeming to themselves
- `test/SharedSalt.t.sol` — mainnet-fork test of the CreateX shared-salt property and its front-run exposure
- `script/deploy-vmUSD.sh` — the driver (test / dry / simulate / broadcast)
- `script/verify-vmUSD.sh` — Etherscan verification with the exact per-contract constructor args

**Generated by a run**
- `deployment-config/out-vmUSD1-salts.json` — the salts, for reuse by other deployers (§4c)
- `deployment-config/out-vmUSD.json` — deployed addresses (broadcast only; `out.json` during dry runs)

**Modified — shared deploy path**

These changes add the `sharedSalt` option. They are **behaviour-preserving when the key is absent**:
`readBoolOr(".sharedSalt", false)` defaults to `false`, which resolves `saltOwner` to the deployer exactly as
before, so every pre-existing config produces byte-identical salts and the same addresses. Regression-checked
by running `LiveDeploy` against `test-1-xaut-L1.json` (which has no `sharedSalt` key) — 6/6 pass.

- `script/Base.s.sol` — added `SHARED_SALT_SENTINEL` and `makeConfigSalt(config, suffix)`; `makeSalt` itself
  is untouched
- `script/ConfigReader.s.sol` — added the optional `sharedSalt` field
- `script/deploy/single/0{2,3,4,5,6,6b,6c,7,9}` + `10`, `12` — each `makeSalt(broadcaster, …)` call swapped for
  `makeConfigSalt(config, …)`
- `deployment-config/out-template.json` — added a `withdrawQueue` key

Not modified: `script/deploy/deployAll.s.sol`, and every contract under `src/`.

`deployment-config/chains/1.json` already had the USDC `isPegged: true` entry — no chain-config change needed.

---

## 4. Running it

The deployer EOA **must** be `0xA072…3631`: step 11 hands every contract to `protocolAdmin`, and step 13 then
needs owner rights to grant roles and transfer ownership. The driver enforces this.

```bash
export ETH_RPC=<mainnet rpc>          # or set L1_RPC_URL in .env

./script/deploy-vmUSD.sh test       # fork tests only
./script/deploy-vmUSD.sh dry        # fork tests + full deploy simulation  (default)
./script/deploy-vmUSD.sh simulate   # deploy simulation only
./script/deploy-vmUSD.sh broadcast  # real deploy; needs SIGNER_ARGS="--ledger" (or --private-key)
```

`LiveDeploy.t.sol`'s `testDepositAndBridge` is excluded by the driver: with `setupLZConfigs: false` there is
no peer, so the bridge path reverts `NoPeer()` by design.

### Dry-run results (mainnet fork, 2026-10-28)

| Suite | Result |
|---|---|
| `LiveDeploy.t.sol` (6 tests, 257 fuzz runs each) | ✅ all pass |
| `VmUsdRolesAndOwnership.t.sol` (9 tests) | ✅ all pass |
| `VmUsdUserFlows.t.sol` (16 tests) | ✅ all pass |
| `VmUsdSafeRecipient.t.sol` (6 tests) | ✅ all pass |
| `SharedSalt.t.sol` (3 tests) | ✅ all pass |
| `deployAllWithRoleGrants` simulation on chain 1 | ✅ complete — ~32.0M gas, ≈0.0115 ETH at 0.36 gwei |

`VmUsdRolesAndOwnership` covers: both operators hold all six roles; both reach the curator / NAV /
`processOrders` / `bulkWithdraw` / pause / unpause / freeze selectors; neither holds `MANAGER_ROLE` or
`TELLER_ROLE` nor can call `BoringVault.manage`; `teller.deposit` + `submitOrder` + `cancelOrder` are public
while `processOrders` is not; all eight contracts owned by `0xCB06…`; authorities still point at the
`RolesAuthority`; a NAV update by non-owner operator A; a full redeem driven by non-owner operator A; and a
role-less stranger rejected on all three paths.

`VmUsdUserFlows` covers the end-user side: approve → deposit → `submitOrder` → `processOrders` full
cycle with balance assertions at every step; partial redeem leaving a remainder; two users in one
`processOrders(2)` batch; redeem priced at the **process-time** rate after a NAV bump; redeem reverting
`VaultInsufficientBalance` while the assets are out in a strategy and succeeding once they return;
head-of-line blocking plus the `forceProcess` escape hatch; redeem blocked while the teller is paused and
resuming after `unpause`; user cancel → shares refunded; a stranger unable to cancel someone else's order;
sub-minimum orders rejected; and an EIP-7702-delegated depositor (see the note below).

---

## 4a. How the redeem actually works

```
user                          WithdrawQueue                     Teller / BoringVault
 │  approve(vault, USDC)
 │  teller.deposit(USDC, amt) ───────────────────────────────▶  vault.enter: USDC in, shares minted
 │  approve(queue, shares)
 │  submitOrder(...)          ──▶ shares escrowed in queue
 │                               ERC721 receipt minted to you
 │                               order appended at latestOrder+1
 │
operator (role 9)
 │  processOrders(n)          ──▶ FIFO from lastProcessedOrder+1
 │                               fee  = feeModule.calculateOfferFees(...)      (0 here)
 │                               rate = accountant.getRateInQuoteSafe(USDC)    ← read NOW, not at submit
 │                               out  = (shares - fee) * rate / 1e6
 │                               require USDC.balanceOf(vault) >= out  ← else revert
 │                               teller.bulkWithdraw(...) ───────────▶  vault.exit: shares burned, USDC → you
```

Answering the direct question: **yes — the assets just need to be sitting in the BoringVault, and then the
processor can run.** Specifics:

- **Liquidity check is a hard balance check on the vault.** `processOrders` reads
  `wantAsset.balanceOf(boringVault)` and reverts `VaultInsufficientBalance(asset, needed, actual)` if it is
  short. Nothing is pulled from a strategy automatically — the curator has to unwind first and get the asset
  back into the vault. No "solver" is bidding here; the queue redeems straight out of vault inventory.
- **The queue is the solver.** It holds `SOLVER_ROLE` (granted in step 10) and calls `teller.bulkWithdraw`,
  which is what burns the escrowed shares and sends the asset out. The operator just triggers the loop.
- **Strictly FIFO, and head-of-line blocking is real.** `processOrders(n)` walks
  `lastProcessedOrder + 1 … + n`; a shortfall on the first order reverts the **whole call**, so nobody behind
  it gets paid. The owner-only `forceProcess(index)` / `forceProcessOrders(indices)` pays a later order out of
  sequence (marking it `PRE_FILLED` so the FIFO loop skips it later). That is the only unblock mechanism —
  flip `grantQueueAdminToProcessorRole` to `true` if you want operator A to have it too.
- **Price is set at process time, not submit time.** The rate is read inside `processOrders`, so a NAV change
  between submit and process changes the payout. Submitting is not a price lock.
- **Shares are escrowed on submit, and the ERC721 receipt is the claim.** `submitOrder` pulls `amountOffer`
  shares from `msg.sender` into the queue and mints the receipt to `receiver`; at process time the payout goes
  to `ownerOf(orderIndex)`, so transferring the receipt transfers the claim.
- **Pauses stop it.** A paused teller reverts `TellerIsPaused`; a paused accountant reverts inside
  `getRateInQuoteSafe`. Neither refunds anything — orders stay pending.
- **Refund paths.** `cancelOrder` (public, order owner only) or `refundOrder`/`refundOrders` (owner) mark the
  order `REFUND`; the shares go back to `refundReceiver` when `processOrders` next reaches that index. If
  `bulkWithdraw` itself reverts, the order is caught and refunded. If the refund transfer also fails (frozen
  receiver), the shares go to `recoveryAddress` = `0xCB06…` for off-chain resolution.
- **Fees are taken in shares**, deducted from `amountOffer` and sent to `feeRecipient` after a successful
  withdraw. Both fees are `0` in this config, so this is a no-op today.
- **Minimum order is 1 USDC of shares** (`minimumOrderSize = 1000000`), enforced at submit.

### The manual 100 USDC round trip — exact calls

Five calls. 1–4 are the depositor, 5 is an operator. **No time pressure**: a pending order has no deadline
and never expires (`testPendingOrderHasNoDeadline` processes one a year later), so a 30-minute window is
ample — the only clock in the system is the accountant's 1h minimum *between rate updates*, which does not
gate deposits or redeems.

Targets below are the CREATE3-predicted addresses for deployer `0xA072…3631` / `nameEntropy = vmUSD1`;
confirm them against `out-vmUSD.json` after broadcast. Replace `0x1111…1111` with your address.

| # | From | Target | Call |
|---|---|---|---|
| 1 | depositor | USDC `0xA0b8…eB48` | `approve(boringVault, 100000000)` |
| 2 | depositor | teller `0xdfa7…ab0f` | `deposit(USDC, 100000000, 0)` → returns 100000000 shares |
| 3 | depositor | boringVault `0x43e1…c2e6` | `approve(withdrawQueue, 100000000)` |
| 4 | depositor | queue `0xa2f9…a902` | `submitOrder((100000000, USDC, you, you, you, (0,0,0x0,0x0,false,0,0x)))` |
| 5 | **operator** | queue `0xa2f9…a902` | `processOrders(1)` |

> ⚠️ Call 1 approves the **BoringVault**, not the teller — `teller.deposit` pulls the asset via
> `vault.enter`. Approving the teller is the most common way to get a failing deposit.
> In call 4, `intendedDepositor` **must** equal `msg.sender` or the queue reverts `InvalidDepositor`.

Encoded payloads (verified byte-for-byte by `testExactMainnetSequenceFor100Usdc`, which executes these raw):

```
# 1  USDC.approve(boringVault, 100e6)
0x095ea7b3
  00000000000000000000000043e1d6430b5b040b338e84405134619f2b96c2e6
  0000000000000000000000000000000000000000000000000000000005f5e100

# 2  teller.deposit(USDC, 100e6, 0)
0x0efe6a8b
  000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48
  0000000000000000000000000000000000000000000000000000000005f5e100
  0000000000000000000000000000000000000000000000000000000000000000

# 3  boringVault.approve(withdrawQueue, 100e6 shares)
0x095ea7b3
  000000000000000000000000a2f9da2aa8ff096cef7ae418a565065cc096a902
  0000000000000000000000000000000000000000000000000000000005f5e100

# 4  withdrawQueue.submitOrder(...)   <- 0x1111…1111 is YOUR address, 3x
0x13bd894c
  0000000000000000000000000000000000000000000000000000000000000020  # tuple offset
  0000000000000000000000000000000000000000000000000000000005f5e100  # amountOffer = 100e6
  000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48  # wantAsset  = USDC
  0000000000000000000000001111111111111111111111111111111111111111  # intendedDepositor = msg.sender
  0000000000000000000000001111111111111111111111111111111111111111  # receiver
  0000000000000000000000001111111111111111111111111111111111111111  # refundReceiver
  00000000000000000000000000000000000000000000000000000000000000c0  # signatureParams offset
  0000000000000000000000000000000000000000000000000000000000000000  # approvalMethod = EIP20_APPROVE
  0000000000000000000000000000000000000000000000000000000000000000  # approvalV
  0000000000000000000000000000000000000000000000000000000000000000  # approvalR
  0000000000000000000000000000000000000000000000000000000000000000  # approvalS
  0000000000000000000000000000000000000000000000000000000000000000  # submitWithSignature = false
  0000000000000000000000000000000000000000000000000000000000000000  # deadline
  00000000000000000000000000000000000000000000000000000000000000e0  # eip2612Signature offset
  0000000000000000000000000000000000000000000000000000000000000000  # eip2612Signature length = 0

# 5  withdrawQueue.processOrders(1)      <- from an operator address, NOT the depositor
0xf1bfdc06
  0000000000000000000000000000000000000000000000000000000000000001
```

Regenerate for a different amount/address with:

```bash
cast calldata "submitOrder((uint256,address,address,address,address,(uint8,uint8,bytes32,bytes32,bool,uint256,bytes)))" \
  "(100000000,0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,$YOU,$YOU,$YOU,(0,0,0x00,0x00,false,0,0x))"
```

### Can one address do submit **and** process in a single transaction?

`submitOrderAndProcess` / `submitOrderAndProcessAll` exist, but **only the owner (`0xCB06…`) can use them**.
Both are `requiresAuth` with no capability granted by step 10, and they reach `processOrders` by *internal
JUMP* — so `requiresAuth` still sees the original caller. Holding role 9 is therefore not enough; you need
owner. Pinned by `testOwnerCanSubmitAndProcessInOneTransaction` and
`testRoleHolderCannotUseTheOneTxCombinedCall`.

| Caller | One-tx `submitOrderAndProcessAll` | Two-call `submitOrder` → `processOrders` |
|---|---|---|
| `0xCB06…a03B` (owner, role 9) | ✅ | ✅ |
| `0xA072…3631` (role 9, not owner) | ❌ | ✅ |
| any user | ❌ | `submitOrder` ✅, `processOrders` ❌ |

If you want the combined call usable from `0xA072…` too, the owner can `setRoleCapability(9, queue,
submitOrderAndProcessAll.selector, true)` — but note that also needs role 9 to cover `processOrders`, which
it already does. Say the word and I'll add it behind the existing
`grantQueueAdminToProcessorRole` flag.

### Public vs role-gated on the user path

`teller.deposit`, `withdrawQueue.submitOrder`, `cancelOrder` and `cancelOrderWithSignature` are **already
public** — no allowlist, no role (step 07 sets the public capability for `deposit` because
`distributorCodeDepositor.deploy` is `false`; step 10 does the same for the queue entrypoints). Asserted in
`testDepositAndQueueEntryArePublic`.

Two things are deliberately *not* public: `processOrders` (role 9) and `teller.depositAndBridge` — 07 leaves
`depositAndBridge` non-public on purpose, and it is unreachable anyway with no LZ peer wired. If you ever
want one-click deposit+bridge for users, that needs an explicit `setPublicCapability` from the owner.

### Who can be a withdraw `receiver`

The receipt is minted with OpenZeppelin `_safeMint`, so a `receiver` **with code** must answer
`onERC721Received` (return `0x150b7a02`) or `submitOrder` reverts `ERC721InvalidReceiver`. Verified against
real mainnet contracts in `VmUsdSafeRecipient.t.sol`:

| Receiver | Works? | Why |
|---|---|---|
| Plain EOA | ✅ | no code, no callback required |
| MPC-signed account (Fireblocks, Turnkey, …) | ✅ | these are plain EOAs on-chain — same as above |
| **Gnosis Safe 1.4.1** (standard deploy) | ✅ | `CompatibilityFallbackHandler` → `TokenCallbackHandler` implements the hook |
| **Gnosis Safe 1.3.0** (standard deploy) | ✅ | same, handler `0xf48f2B2d…Fe5e4` |
| Safe with `fallbackHandler == address(0)` | ❌ | Safe's `fallback()` does `return(0,0)`; no magic value, so the mint reverts |
| EIP-7702 EOA, delegate implements the hook | ✅ | e.g. `0xCB06…a03B` — verified to return `0x150b7a02` |
| EIP-7702 EOA, delegate does NOT | ❌ | hit this by accident with `makeAddr("alice")`/`("bob")`, both live 7702 accounts on mainnet |

In every ❌ case the **deposit still works** — only the queue order fails, and only because of the receipt
NFT. Two fixes: set a fallback handler on the Safe (`setFallbackHandler`), or name a different `receiver`
(`amountOffer` is still pulled from `msg.sender`, and the payout follows whoever owns the receipt).

Safes can therefore deposit and **redeem to themselves** with no special handling — covered by
`testSafe141DepositsAndRedeemsToItself` / `testSafe130DepositsAndRedeemsToItself`, which deploy real Safes
through the canonical mainnet `SafeProxyFactory` rather than a mock.

### The two configured admin addresses, as resolved on mainnet

| Address | On-chain reality | Implications |
|---|---|---|
| `0xA072f8Bd…a63631` (deploy admin, operator A) | **plain EOA**, no code | can sign the deploy broadcast directly, and can be a withdraw receiver |
| `0xCB068924…5a03B` (final owner, operator B) | **EIP-7702-delegated EOA**, delegate `0x63c0c19a…dae32b`, reports `VERSION() = "1.3.0"` and answers `onERC721Received` | fine as owner (it signs as an EOA) and fine as a withdraw receiver |

Asserted in `testConfiguredAdminAddressesCanReceiveTheReceipt`. Worth re-checking `0xCB06…`'s delegation
before broadcast: a 7702 delegation can be changed or revoked by its owner at any time, and if it were
re-pointed at a delegate without the ERC721 hook it would stop being usable as a withdraw receiver (its
owner/role powers would be unaffected).

### Deployed addresses (`nameEntropy = vmUSD1`, `sharedSalt: true`)

**Live on mainnet** and matching the pre-broadcast simulation exactly. Because `sharedSalt` is on, these are
**deployer-independent** — any deployer on any chain with CreateX reproduces them.

| Contract | Address |
|---|---|
| BoringVault | `0x43e1d6430b5b040b338e84405134619f2b96c2e6` |
| FreezeListBeforeTransferHook | `0x48905f681631da14c5c5fd34cf341a6d0f709a92` |
| ManagerWithMerkleVerification | `0xd16c82722171c541f7b605d09cdcba93dd8a8447` |
| AccountantWithRateProviders | `0x826e67108d8f6d404dbedcc7baf9f7e5753299bf` |
| Teller (LZ multichain) | `0xdfa77933f55c70b03fc3720e81192d09001aab0f` |
| RolesAuthority | `0x995d6439610a3fe4fcc7a84f3757ff533828f138` |
| WithdrawQueueAssetSpecificFeeModule | `0x268C7F603765eb689feB1f9bC3a7fF9e2B3F94EB` |
| WithdrawQueue | `0xa2f9da2aa8ff096cef7ae418a565065cc096a902` |
| GenericDecoderAndSanitizer | `0x4c797bbfbfaba445b32394ebf2b56312fb4f195b` |

---

## 4c. Salts — shared across deployers, and stored

`BaseScript.makeConfigSalt(config, suffix)` builds a CreateX salt as:

```
salt = saltOwner (20 bytes) ‖ 0x00 (cross-chain redeploy flag, off) ‖ bytes11(keccak256(entropy))
entropy = "<nameEntropy>:<ContractName>"          e.g. "vmUSD1:WithdrawQueue"
```

`saltOwner` is what `config.sharedSalt` switches, and it changes CreateX's whole behaviour:

| `sharedSalt` | `saltOwner` | CreateX branch | Guarded salt | Who can use it |
|---|---|---|---|---|
| `false` (default, every pre-existing config) | the deployer EOA | `SenderBytes.MsgSender` | `keccak256(msg.sender ‖ salt)` | **that deployer only**; address depends on the deployer |
| **`true` (this vault)** | `SHARED_SALT_SENTINEL` = `0x…5A17` | `SenderBytes.Random` | `keccak256(abi.encode(salt))` — **no `msg.sender`** | **anyone, on any chain**; address depends on the salt alone |

Verified directly against mainnet CreateX in `test/SharedSalt.t.sol`: two different deployers using the same
sentinel salt land on the same address, while two deployer-bound salts do not — and a third deployer using
someone else's bound salt cannot reach that address at all.

**What this buys you.** Previously a second chain required the *same deployer EOA* so CREATE3 would line the
teller up at a matching address (that constraint is why `nXAUT.md` warns about it). With `sharedSalt: true`
any deployer can reproduce the whole address set on any CreateX chain, so the LayerZero "peer = my own
address" wiring no longer depends on who holds the key.

### ⚠️ What it costs

A deployer-independent salt is also a deployer-independent **claim**. The salts become public the moment the
first chain's deploy calldata lands on-chain, after which **anyone can occupy the remaining chains'
addresses with code of their choosing**, and the slot is then burned for you on that chain. CreateX's
permissioned-deploy protection is exactly what the default guards against, and opting in gives it up. Pinned
as a test so it cannot be forgotten: `testSharedSaltSlotIsClaimableByAnyoneAndThenBurned`.

Practical consequences:
- **Deploy the remaining chains promptly**, or accept that the addresses are first-come.
- **Always verify the deployed bytecode** on chains you did not deploy yourself before wiring an LZ peer to
  it. A squatted teller address would otherwise be a peer you trust.
- Set `"sharedSalt": false` (or drop the key) to get the front-run-resistant behaviour back. It changes every
  address.

### Where the salts are stored

`runWithRoleGrants` writes **`deployment-config/out-vmUSD1-salts.json`** at the end of every run (dry-run and
broadcast), recomputed with the same `makeConfigSalt` the deploy itself used — so the file cannot drift from
what was broadcast. It records `nameEntropy`, `sharedSalt`, `saltOwner`, and per contract the entropy string
plus the 32-byte salt. Hand that file to another deployer and they can reproduce these addresses verbatim.

| Contract | Salt |
|---|---|
| BoringVault | `0x0000000000000000000000000000000000005a1700e423a93014093f8b6eb281` |
| FreezeListBeforeTransferHook | `0x0000000000000000000000000000000000005a170058b1c2eda56414a1773285` |
| ManagerWithMerkleVerification | `0x0000000000000000000000000000000000005a170061fa0722384b85f73e148d` |
| AccountantWithRateProviders | `0x0000000000000000000000000000000000005a1700b6c07d6b2b6837ee44f64d` |
| Teller (LZ multichain) | `0x0000000000000000000000000000000000005a1700b87ced186848401b6d5876` |
| RolesAuthority | `0x0000000000000000000000000000000000005a17006afaa32d1eb7e547b00e3d` |
| WithdrawQueueAssetSpecificFeeModule | `0x0000000000000000000000000000000000005a1700f165ba521e01bb94ef2d58` |
| WithdrawQueue | `0x0000000000000000000000000000000000005a17007c062f2d2676c377ff62a5` |
| GenericDecoderAndSanitizer | `0x0000000000000000000000000000000000005a17001f0e9ed4108252e79ad01d` |

Reproduce any of them:
`echo 0x0000000000000000000000000000000000005a1700$(cast keccak 'vmUSD1:WithdrawQueue' | cut -c3-24)`

> ⚠️ A salt is single-use **per chain**. If a broadcast half-fails and you re-run the whole thing, the
> already-deployed contracts revert on their CREATE3 call. Resume from the failed step with the single
> scripts, or bump `nameEntropy` and start clean at a new address set.

## 4d. Etherscan verification

The repo is already configured for **Etherscan V2 multichain** (`foundry.toml` → `[etherscan] mainnet = {
key = "${ETHERSCAN_API_KEY}", chain = 1, url = "https://api.etherscan.io/v2/api" }`), and the
`ETHERSCAN_API_KEY` in `.env` is present and **confirmed working** against the V2 API (probed
`getsourcecode` on mainnet → `status: 1`). So verification is good to go.

`broadcast` passes `--verify`. **Expect some contracts to need a manual pass**: every contract here is
deployed by CreateX via CREATE3, so the broadcast transaction targets CreateX rather than the contract, and
`forge script --verify` often does not pick up factory-created contracts.

For that, use the dedicated script, which re-encodes every constructor-arg blob exactly as the deploy
scripts did:

```bash
./script/verify-vmUSD.sh                      # all contracts, reads out-vmUSD.json
ONLY=WithdrawQueue ./script/verify-vmUSD.sh    # retry just one
```

Two things that trip this up:

- **Constructor args are DEPLOY-time.** Every `Auth` contract was constructed with `owner = 0xA072…3631`
  (the deployer), and ownership moved to `0xCB06…a03B` only afterwards in steps 11/13. Verifying with the
  final owner in the args will fail.
- **`ManagerWithMerkleVerification` has a stray 4th constructor word.** Its constructor takes 3 args
  (`owner, vault, balancerVault`) but `04_Deploy…` appends a 4th (`18`). The constructor ignores trailing
  data so the deployment is correct, but the on-chain arg blob is 4 words. If the 3-arg encoding is
  rejected, retry with `cast abi-encode 'c(address,address,address,uint8)' … 18`.

## 4e. Post-deploy on-chain verification (2026-10-28)

Read back from mainnet after the broadcast. Every line checked against the intended config:

| Check | Result |
|---|---|
| Share token | `VaultMason USD Vault` / `vmUSD` / 6 decimals / supply 0 |
| Owner of vault, teller, queue, accountant, manager, rolesAuthority, hook, fee module | all `0xCB06…a03B` ✅ |
| LayerZero delegate on the endpoint | `0xCB06…a03B` ✅ (moved with the owner) |
| Roles 1/4/5/6/9/10 on `0xA072…3631` and `0xCB06…a03B` | all granted ✅ |
| `canCall` for curator / NAV / processOrders / bulkWithdraw / pause / **unpause** / setFreezeList from non-owner `0xA072…` | all true ✅ |
| `teller.deposit` + `queue.submitOrder` public | true ✅ |
| `queue.processOrders` public | **false** ✅ (role 9 only, as intended) |
| Teller paused / shareLockPeriod | `false` / `0` ✅ |
| USDC deposit + withdraw supported | true / true ✅ |
| Accountant rate / bounds / delay / fees / paused | `1e6` / 10000–10004 / 3600s / 0 / 0 / `false` ✅ |
| Queue offerAsset == BoringVault | ✅ |
| Queue feeRecipient / recoveryAddress / minOrderSize | `0xA072…3631` / `0xA072…3631` / `1000000` ✅ |
| Fee on a 100 vmUSD → USDC order | `0` ✅ |
| `manager.manageRoot(0xA072…)` | `0x00…00` — no strategy wired yet, expected |
| Etherscan verification | all 9 contracts verified ✅ |

Etherscan verification succeeded through `forge script --verify` without a manual pass — the
`script/verify-vmUSD.sh` fallback was not needed, though it remains for future chains.

## 5. Post-deploy (NOT scripted)

1. **Merkle root** — `manager.setManageRoot(strategist, root)` from the owner. Until then the vault takes
   deposits and redemptions but can run no strategy.
2. **Exchange rate** — the accountant starts at 1:1 (`1e6`). Only touch it if that is wrong.
3. **Smoke test on-chain** — approve + `teller.deposit` a small amount, `withdrawQueue.submitOrder`,
   `processOrders(1)` from operator A.
4. **LayerZero, when a second chain goes live.** Set `peerEid` in each chain's config, deploy the second leg
   with the *same deployer EOA* (so CREATE3 gives the teller the same address `T`), then from the owner on
   each chain:
   ```solidity
   teller.setPeer(<peerEid>, bytes32(uint256(uint160(T))));
   teller.addChain(<peerEid>, true, true, T, 100000 /*maxGas*/, 0 /*minGas*/);
   ```
   and pin a ULN/DVN config rather than relying on LayerZero defaults.

### DVNs

`teller.dvnIfNoDefault` in the JSON is pre-populated with the set this repo used on mainnet for
`bkeyUSDG-L1` and `soohoUSDGt-L1` (addresses cross-checked against
`deployment-config/layerzero/dvn-deployments.json`):

| Slot | DVN | Mainnet address |
|---|---|---|
| required | LayerZero Labs | `0x589dedbd617e0cbcb916a9223f4d1300c294236b` |
| optional | Nethermind | `0xa59ba433ac34d2927232918ef5b2eaafcf130ba5` |
| optional | Stargate | `0x8fafae7dd957044088b3d0f67359c327c6200d18` |

`optionalThreshold: 1`, `blockConfirmationsRequiredIfNoDefault: 15` — i.e. LayerZero Labs **plus** one of
Nethermind/Stargate must attest. **These values are inert today** (`setupLZConfigs: false` means nothing is
written to the endpoint); they are recorded so the peer-wiring step in §5.4 has a vetted starting point.
Confirm the pair chain's DVN addresses from `dvn-deployments.json` before you use them.
