# BoringVault system — architecture & overview (context for another AI)

This describes the EVM "BoringVault" vault system (Veda / Se7en Seas architecture, as forked/extended by
Theoriq from the Paxos "Nucleus" derivative). Hand this to an agent as background so it understands deposits,
withdrawals, authorization, and curation (strategy execution) before touching the code. It is a *conceptual*
overview — the Solidity is the source of truth; key files are listed at the end.

---

## 1. What it is (one paragraph)

A BoringVault is a **minimal, asset-agnostic vault**: it (a) issues an ERC20 **share token**, (b) **custodies
assets**, and (c) exposes a single privileged primitive — `manage(target, calldata, value)` — that lets an
authorized caller make *arbitrary external calls from the vault's own address*. Everything else (who can
deposit, at what price, which strategies are allowed, how withdrawals settle) is **outsourced to satellite
contracts** so the vault core stays tiny and rarely-upgraded. Safety comes from tightly constraining *who* may
call `manage` and *what* those calls may be — that constraint system (the **Manager + a per-strategist merkle
tree + per-protocol decoder/sanitizers**) is the heart of the design.

---

## 2. Component map

- **BoringVault** — the core. Holds assets, is the ERC20 share token, exposes `enter`/`exit` (mint/burn) and
  `manage` (arbitrary call). Delegates all access control to a RolesAuthority.
- **TellerWithMultiAssetSupport** — the deposit/withdraw front door for users (multi-asset, share-lock,
  refunds, permissioned withdraws).
- **AccountantWithRateProviders** — the price oracle: a safe, rate-limited, bounded share↔asset exchange rate.
- **ManagerWithMerkleVerification** — **curation**: gates `manage` calls against a per-strategist merkle tree
  of allowed actions, using per-protocol **decoder/sanitizers** to pin the security-critical addresses in each
  call's calldata. (Plus variants — see §7.)
- **RolesAuthority** (solmate) — role-based access control for every privileged function across the system.
- **WithdrawQueue / AtomicQueue + AtomicSolverV3** — asynchronous / solver-settled withdrawals.
- **FreezeListBeforeTransferHook** — a transfer bl/allow-list hook on the share token (compliance/freeze).
- **DecodersAndSanitizers** — a library of pure "how to read this protocol's calldata" contracts used by the
  Manager. The combined next-gen one is `nextgen/FullDecoderAndSanitizer.sol`.
- **Cross-chain adapters** — LayerZero OFT (omnichain share token), Circle CCTP (native USDC), Hyperlane
  teller (alt messaging).

Everything is deployed deterministically via **CREATE3 (CreateX)** so the same address can exist on every
chain.

---

## 3. Core value model

- **Shares** = the vault's own ERC20 (18 decimals). Minted on deposit, burned on withdraw.
- **Assets** = whatever SPL/ERC20 tokens the vault is configured to accept (the RWA/stable/etc.), custodied at
  the vault address.
- **Exchange rate** = provided by the Accountant. `assets = shares * rate / 1e(shareDecimals)` and inverse.
  The rate is computed **off-chain** (NAV of the underlying, which may be RWA) and pushed on-chain under
  guardrails (§6) — it is NOT derived from an on-chain AMM.
- **The `manage` primitive**: `BoringVault.manage(address target, bytes data, uint256 value)` performs
  `target.call{value}(data)` **as the vault**. This is how the vault deploys capital into strategies (supply
  to lending, swap on a DEX, LP, bridge, etc.). It is the only way assets move for strategy purposes, and it
  is the thing the Manager gates.
- **`enter` / `exit`**: `enter(to, asset, assetAmount, from, shareAmount)` pulls `assetAmount` of `asset` from
  `from` and mints `shareAmount` shares to `to`. `exit(to, asset, assetAmount, from, shareAmount)` burns
  `shareAmount` from `from` (no allowance check!) and optionally transfers `assetAmount` of `asset` to `to`.
  The Teller/queues drive these; the burn and asset-transfer legs are independent (see the exit note in §7).

---

## 4. Deposits (TellerWithMultiAssetSupport)

1. User calls the Teller to deposit `asset` (must be an allow-listed deposit asset).
2. Teller reads the price from the Accountant, computes shares, and calls `vault.enter` — pulling the asset to
   the vault and minting shares to the user.
3. **Share-lock period**: freshly-minted shares are locked to the depositor for `shareLockPeriod`, which makes
   flash-loan deposit/withdraw arbitrage impossible.
4. **Refunds**: during the lock, a permissioned account can *refund* a deposit (reverse it entirely) — a
   safety valve against mispriced/MEV deposits.
5. Deposits can be paused; assets can be added/removed from the allow-list; each asset can carry a premium/
   discount. There is also a "deposit-and-bridge" convenience flow (deposit, then LayerZero-OFT the shares to
   another chain in one tx).

**Why multi-asset + these controls:** letting users pick their in/out asset is convenient but turns the vault
into a free swap venue for MEV bots; the share-lock + refunds + permissioned withdrawals neutralize that while
keeping the UX.

---

## 5. Withdrawals (three paths)

- **Teller (direct / permissioned)** — the Teller supports permissioned withdraws; not an open instant redeem
  (that would reintroduce MEV).
- **WithdrawQueue** — users submit withdraw orders; a `PROCESSOR`-role account calls `processOrders(count)`
  which settles them **FIFO by count** (nonces are only for signature replay protection on submission, not the
  processing order). There is no hard on-chain minimum wait — the processor's discretion + share-lock provide
  the delay. Collateral is delivered to the withdrawer via the teller's bulk-withdraw path.
- **AtomicQueue + AtomicSolverV3** — solver-settled atomic swaps of shares↔asset. `AtomicQueue.solve(offer,
  want, users, runData, solver)` calls back `IAtomicSolver(solver).finishSolve(...)`. Two modes: **P2P**
  (solver provides `want` from its own inventory — the vault itself can be the solver/market-maker via a
  `manage → AtomicSolverV3.p2pSolve` call) and **REDEEM** (settle at NAV through the teller). This is the
  primitive behind discounted-buyback / secondary-market flows.

---

## 6. Share price (AccountantWithRateProviders)

The Accountant is the manipulation-resistant price source:
- The rate is set **off-chain** and pushed on-chain (because on-chain sources are manipulable and the
  underlying may be RWA with no on-chain price).
- **Rate-limited**: updates can only happen so often.
- **Bound-limited**: a new rate must fall within a bounded deviation of the previous on-chain rate.
- **Pause-on-violation**: if either guard is violated, the Accountant enters a `paused` state that halts
  deposits, withdrawals, and further rate updates until a permissioned account intervenes.
- Per-asset **rate providers** convert between the base rate and each accepted asset (Chainlink/Redstone/
  custom oracles + adapters live under `src/oracles` and `src/helper`).

---

## 7. Curation — how strategies are gated (the heart of the system)

This is what makes the vault safe despite the almighty `manage` primitive.

**ManagerWithMerkleVerification** holds, **per strategist**, a **merkle root** whose leaves enumerate exactly
which calls that strategist may make. A leaf is:
```
leaf = keccak256(abi.encodePacked(
    decoderAndSanitizer,      // which decoder interprets this call
    target,                   // the contract the vault will call
    valueIsNonZero,           // may this call send native ETH?
    selector,                 // the 4-byte function selector on target
    packedArgumentAddresses   // the security-critical addresses in the calldata, in a fixed order
))
```
To act, a strategist calls `manageVaultWithMerkleVerification(proofs[], decoders[], targets[], data[],
values[])`. For each call the Manager:
1. **staticcalls the decoder/sanitizer** — a *pure* contract whose function signatures mirror the target's;
   it decodes the calldata and returns `abi.encodePacked(...)` of just the **sensitive addresses** (e.g. the
   `onBehalfOf`, the `receiver`, the tokens, the pool).
2. **recomputes the leaf** from (decoder, target, valueNonZero, selector, decoderOutput) and **verifies the
   merkle proof** against that strategist's root.
3. If valid, calls `vault.manage(target, data, value)`.

Crucially, **decoders pin addresses, never amounts** — the leaf constrains *what contracts / which
counterparties/receivers* a call may touch (e.g. "you may `supply` to Aave, but only `onBehalfOf` the vault"),
while amounts/prices are bounded by the target protocol's own guards (a DEX `minReturn`, a lending health
factor). This is the same trust model as pinning a 1inch `dstReceiver` and trusting `minReturn`.

**Invariant enforced during management:** the vault's share `totalSupply` MUST remain constant across a manage
batch — the Manager reverts on any mint/burn inside a strategy call. (The only exception is a dedicated
burn-only "exit" primitive on the balance-verification manager — see below.)

**Decoder/sanitizer library** covers, e.g.: Uniswap V3, Curve, Balancer, ERC-4626, Aave V3/V4, Morpho Blue,
Morpho Midnight, Euler v2, KyberSwap, Odos, Pendle (incl. on-chain limit orders), CowSwap (via a stateful
module), LayerZero OFT, Circle CCTP, Nucleus, native wrappers, and more — combined in
`nextgen/FullDecoderAndSanitizer.sol`. OKX is deliberately excluded (its trailing commission blob defeats a
selector-matched decoder). An off-chain **merkle-root generator** builds the tree from per-protocol "which
addresses to pin" specs.

### Manager variants
- **ManagerWithMerkleVerification** — the base (above).
- **ManagerWithMerkleAndTokenBalanceVerification** — brackets a merkle batch with **vault token-balance
  snapshots** and requires each token's net delta ≥ a caller-supplied minimum (anti-bad-execution: slippage /
  MEV / fat-finger, on top of the anti-malice merkle root). Also adds **flash loans** (Balancer + Morpho Blue
  + Morpho "Midnight") and a **burn-only exit** entrypoint: the single operation allowed to *reduce* supply —
  it burns the vault's own treasury shares (a discounted-buyback accretion step), hard-scoped to
  `BoringVault.exit` with `assetAmount == 0` (no asset moves) and an exact supply-delta check. UNAUDITED.
- **ManagerWithTokenBalanceVerification** — the balance-delta bracket without merkle (standalone).
- **ManagerSimulator** — dry-run a batch.

---

## 8. Authorization (RolesAuthority + roles)

All privileged functions across the system are gated by a solmate **RolesAuthority**: it maps
`(role → target contract → function selector → allowed)` and `(user → roles bitmap)`. Contracts call
`requiresAuth`; nothing hardcodes a single key. Typical roles (numbers are **deployment-specific** — these are
one deployment's assignments):
- **STRATEGIST** — may call the Manager's `manageVaultWithMerkleVerification` (curated strategy execution).
- **MANAGER** — the Manager is granted the capability to call `vault.manage`.
- **MANAGER_INTERNAL** — the Manager calling itself (e.g. flash-loan callbacks).
- **ADMIN / owner** — sets merkle roots, config; typically a multisig (e.g. Fordefi/Safe).
- **SOLVER** — held by the queue/solver to settle withdrawals.
- **WITHDRAW_QUEUE_PROCESSOR** — may call `processOrders`.
- **FREEZE_MANAGER** — manages the transfer freeze-list.
- **BORING_VAULT / BALANCER_VAULT** — internal capability roles (self-calls, flash-loan callbacks).

Admin/upgrade authority is expected to be a multisig in production. Ownership transfer uses solmate's
`transferOwnership`.

---

## 9. Transfer restrictions (FreezeListBeforeTransferHook)

The share token can be configured with a `beforeTransferHook` (fires on `transfer`/`transferFrom`, NOT on
`_mint`/`_burn`) implementing a **blocklist/allow-list** so frozen addresses can't move shares. Managed by the
FREEZE_MANAGER role. (For a Solana port this maps to a Token-2022 Transfer Hook.)

---

## 10. Cross-chain

- **LayerZero OFT** — the **share token itself is an omnichain OFT**: shares can be bridged between chains
  (e.g. mainnet ↔ Celo) and remain one unified token. Deposit-and-bridge composes deposit + OFT send.
- **Circle CCTP** — native USDC burn-and-mint across chains (mint recipient is pinned by the CCTP decoder).
- **Hyperlane** — an alternative multichain teller path.

---

## 11. Security model & invariants (what a reviewer must preserve)

- The vault can do anything via `manage`, so **the entire safety surface is: (1) who holds STRATEGIST, and
  (2) what their merkle root permits** — decoders must pin every security-critical address, and the root
  author must pin receivers/onBehalfOf/etc. to the vault. A decoder that misses a sensitive address, or a root
  that leaves one unpinned, is a potential drain.
- **totalSupply is constant during management** (except the dedicated burn-only exit).
- **Deposits/withdrawals are MEV-hardened** via share-lock + refunds + permissioned/queued withdrawals.
- **The Accountant is oracle-bounded, rate-limited, and pauses on violation.**
- **Amounts are bounded by the target protocol's own guards**, not by the decoder (decoders pin addresses
  only) — so a strategy leaf trusts the callee's `minReturn`/health-factor.
- Trust assumptions: the STRATEGIST is semi-trusted (bounded by the root), the ADMIN/owner (root author +
  config) is trusted, the off-chain rate publisher is trusted (bounded by rate/deviation limits).

---

## 12. Key files (source of truth)

- `src/base/BoringVault.sol` — core vault (shares + custody + `enter`/`exit`/`manage`).
- `src/base/Roles/ManagerWithMerkleVerification.sol` — base curation manager.
- `src/base/Roles/ManagerWithMerkleAndTokenBalanceVerification.sol` — delta checks + flash loans + burn-only exit.
- `src/base/Roles/ManagerWithTokenBalanceVerification.sol`, `.../ManagerSimulator.sol` — variants.
- `src/base/Roles/TellerWithMultiAssetSupport.sol` — deposits/withdraws.
- `src/base/Roles/AccountantWithRateProviders.sol` — share price.
- `src/base/Roles/WithdrawQueue.sol`, `src/atomic-queue/AtomicQueue.sol`, `.../AtomicSolverV3.sol` — withdrawals.
- `src/helper/FreezeListBeforeTransferHook.sol` — transfer freeze-list.
- `src/base/DecodersAndSanitizers/**` (esp. `nextgen/FullDecoderAndSanitizer.sol`) — the curation decoders.
- `src/interfaces/DecoderCustomTypes.sol` — shared struct layouts used by decoders.
- RolesAuthority = solmate `auth/authorities/RolesAuthority.sol`.
- Deploy sequence: `script/deploy/single/01…12_*.s.sol`; deterministic via CreateX.
