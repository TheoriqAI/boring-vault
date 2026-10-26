# Prompt: build a full SVM (Solana) port of the BoringVault system, with bridges, deploy, tests, and a Solana audit agent

## Who you are / mandate
You are a senior Solana protocol engineer + security lead. Build a **new repository** that ports the EVM
"BoringVault" vault architecture (Veda/Se7enSeas → Theoriq fork) to **Solana (SVM)** with **first-class,
faithful reproduction of every manager, teller, accountant, roles/authority, and the decoder/sanitizer
merkle-gating model** — plus **cross-chain bridging (Circle CCTP + one canonical SVM↔EVM bridge)**, deploy
scripts, an exhaustive test suite, and a built-in **Solana security-audit agent** that adversarially reviews
everything you produce. Do not hand-wave the hard parts: the account-model translation of "gated arbitrary
`manage()`" is the crux and the main risk — solve it explicitly and prove it with tests.

Reference (read first): the EVM system is BoringVault (ERC20 shares + holds assets + `manage(target,
calldata, value)` gated by a RolesAuthority) · ManagerWithMerkleVerification (a per-strategist merkle tree
authorizes exactly which (decoder, target, valueNonZero, selector, packedSensitiveAddresses) tuples the vault
may call; the manager staticcalls a per-protocol "decoder/sanitizer" that extracts the security-critical
addresses from calldata, and the leaf pins them) · TellerWithMultiAssetSupport (deposit/withdraw, share-lock,
refunds) · AccountantWithRateProviders (oracle-bounded, rate-limited share price) · WithdrawQueue / AtomicQueue
· FreezeListBeforeTransferHook (transfer blocklist) · the experimental ManagerWithMerkleAndTokenBalanceVerification
(brackets a merkle batch with token-balance-delta checks + flash loans + a burn-only exit). Assume you can be
given the EVM source for exact semantics.

## Target stack (justify any deviation)
- **Anchor (Rust)** for all programs (auditability + IDL). Use native Rust / Pinocchio ONLY for a compute- or
  size-critical hot path, and only with justification.
- **SPL Token-2022** for the vault **share mint** (use the **Transfer Hook** extension to reproduce
  `FreezeListBeforeTransferHook` / bl- and allow-lists; consider the permanent-delegate / default-account-state
  extensions for freeze parity). Support both SPL-Token and Token-2022 assets on the deposit side.
- **Address Lookup Tables (ALTs)** + **versioned transactions** everywhere — you will need them (see constraints).
- Tests: **LiteSVM / Mollusk** for fast unit tests, **`solana-test-validator --clone` and/or `surfpool`
  (mainnet-fork-style)** for integration tests against *real cloned mainnet programs & accounts*, and
  **Anchor + TypeScript (bankrun)** for e2e. There is no EVM-style fork; clone the actual mainnet program IDs +
  state and drive real CPIs.
- Deploy: Anchor + `solana program deploy`, upgrade authority held by a **Squads v4 multisig**; per-cluster
  (localnet/devnet/mainnet-beta) config; buffer + deploy + verify (verifiable builds via `solana-verify`).

---

## The crux — translate "gated arbitrary `manage()`" to the account model

On EVM an action is `(target, calldata, value)` and the decoder reads addresses out of calldata. On Solana an
action is `(program_id, accounts: Pubkey[], data: bytes)` and there is no calldata to introspect after the
fact — the caller must supply *every* account. Design the manager so that:

1. A **merkle leaf pins**: `program_id`, the **instruction discriminator** (Anchor: first 8 bytes; native
   programs: their own tag/layout), a set of **position→required-Pubkey** constraints on the accounts vector
   (the Solana analog of "packed sensitive addresses"), and optional **instruction-data field constraints**
   (e.g. a `min_out`, a `receiver`, a `mode` byte). The **decoder/sanitizer per protocol declares which
   account indices and which data fields are security-critical** (must be pinned) — exactly mirroring "which
   calldata addresses to pin" on EVM.
2. The strategist submits the full `accounts[]` + `data`; the manager **verifies the pinned positions/fields
   match the leaf + a merkle proof**, then performs the action via **`invoke_signed`** with the **vault PDA as
   signer**, forwarding the (validated) accounts as `remaining_accounts`.
3. Reproduce the **per-strategist root** (`set_manage_root(strategist, root)`), the pause flag, and the
   invariant checks.

**Hard constraints you MUST design around (call them out, measure them, and document limits):**
- **1232-byte transaction size**: merkle proofs + large account lists blow this fast. Use ALTs aggressively;
  consider committing the proof/accounts to a PDA across instructions, or a "propose+execute" two-step
  (propose writes the intended action to a PDA, execute verifies + CPIs) if a single tx can't hold it.
- **~1.4M compute units** and **CPI depth 4**: multi-hop DeFi routes (e.g. Jupiter) can exceed these; the
  sanitizer for aggregators must pin the *outer* accounts (destination token account/owner, mints) and treat
  the inner route as opaque (bounded by the program's own min-out), analogous to 1inch `minReturn`.
- **Account confusion / "type cosplay"**, **owner & signer checks**, **PDA canonical bump**, **duplicate
  mutable accounts**, **arbitrary-CPI**: these are the account-model analog of address-sanitization bugs — the
  sanitizer and manager MUST enforce them (see Audit section).

**Deliverable gate:** before building all the decoders, build a *spike* proving the core flow end-to-end —
vault PDA holds SPL tokens, manager verifies a merkle leaf, and `invoke_signed` executes ONE real whitelisted
CPI (e.g. an Orca Whirlpool swap) with pinned accounts, on a cloned-mainnet validator. Only expand once the
size/CU budget of that flow is measured and acceptable.

---

## Programs to reproduce (parity with the EVM set)

1. **`vault`** — holds assets (SPL/Token-2022 token accounts owned by a vault PDA), mints/burns the **share
   mint** (Token-2022) via PDA authority, and exposes the gated `manage`/`invoke_signed` entrypoint. Analog of
   BoringVault. Include the **burn-only "exit"** primitive (the only op allowed to reduce share supply — burn
   the vault's own treasury shares; enforce burn-only + exact supply-delta, no asset movement), matching the
   EVM `exitVaultWithMerkleVerification`.
2. **`manager-merkle`** — ManagerWithMerkleVerification: per-strategist root, leaf verification, pause, the
   "supply must not change during management" invariant (except the exit primitive).
3. **`manager-merkle-balance`** — adds token-balance-delta bracketing (snapshot vault token balances before/
   after a batch; require each `min_delta`), plus **flash-loan support**. On Solana there is no Balancer/Morpho
   flash loan; provide a **Solana flash-loan adapter** integrating a real provider (**Kamino** or **Solend/Save
   flash borrow+repay**, which use the Instructions sysvar to enforce same-tx repayment) **OR a clearly-marked
   placeholder** program with the same interface if the user defers it. Document the atomic-tx / Instructions-
   sysvar pattern as the native Solana flash-loan mechanism.
4. **`manager-token-balance`** — the standalone balance-verification manager (parity with
   ManagerWithTokenBalanceVerification).
5. **`manager-simulator`** — dry-run/simulate a batch (parity with ManagerSimulator).
6. **`teller`** — multi-asset deposit/withdraw, share-lock period, permissioned refunds (parity with
   TellerWithMultiAssetSupport). Deposits pull SPL/Token-2022; mint shares at accountant rate.
7. **`accountant`** — oracle-bounded, rate-limited, bounded-deviation share price with a pause-on-violation
   (parity with AccountantWithRateProviders); integrate **Pyth** and/or **Switchboard** as rate providers.
8. **`withdraw-queue` / `atomic-queue`** — async/solver withdrawal queues (parity with WithdrawQueue +
   AtomicQueue/AtomicSolverV3), FIFO processing + solver P2P/redeem modes.
9. **`roles`** — role-based authority (parity with solmate RolesAuthority): a roles PDA mapping (role → target
   program/ix → allowed) and (user → roles bitmap); admin held by the Squads multisig. Enforce `requiresAuth`
   equivalents on every privileged instruction (never hardcode a single authority).
10. **`freeze-hook`** — Token-2022 Transfer Hook program implementing the bl*/allow-list (parity with
    FreezeListBeforeTransferHook), with a FREEZE_MANAGER role.

---

## Decoders / sanitizers (per-protocol account+data validation modules)

Each is a module that, for a given `(program_id, discriminator)`, declares the security-critical account
indices + data fields the leaf must pin, and validates a submitted instruction against a leaf. Cover:

- **Lending**: **Kamino Lend (K-Lend)**, **MarginFi v2**, **Save (Solend)**, **Drift v2** — pin the obligation/
  account owner = vault, the reserve/bank, the destination token account & mint; instructions: deposit/reserve-
  supply, withdraw, borrow, repay, enable-as-collateral equivalents. Note obligations are per-market accounts,
  not a `uint256 reserveId` — pin the reserve/market pubkeys directly (this is *easier* than Aave v4's opaque
  reserveId).
- **DEXes**: **Jupiter v6 aggregator** (treat like 1inch — pin destination token account/owner + in/out mints,
  route opaque, bounded by min-out; reject unexpected account writes), **Orca Whirlpools (CLMM)**, **Raydium
  (AMM v4 / CLMM / CPMM — NOT Anchor, custom layouts)**, **Meteora (DLMM + Dynamic AMM)**, **Phoenix / OpenBook
  v2 (on-chain orderbooks)**.
- **"Prop AMMs" / PMM / RFQ**: **Lifinity** (proactive MM), plus RFQ/PMM-style venues (**Hashflow on Solana /
  DFlow**) if in scope — pin the maker/quoter, taker token accounts, and mints; the quote/signature is the
  integrity boundary.
- **"ERC-4626 equivalent"**: there is **no canonical Solana 4626**. Handle tokenized-vault shares **per
  protocol** — Kamino kTokens, Meteora vault LP, Marginfi, Sanctum LSTs, and aggregators (Voltr/Lulo). Pin the
  vault program, the share mint, and the vault token accounts; document explicitly that there is no standard
  and each vault program needs its own sanitizer. If the user wants a "standard", define a minimal internal
  SPL-vault-share interface but do NOT assume external protocols implement it.
- **Bridges** (below) each get a sanitizer too.

For non-Anchor programs (Raydium, OpenBook, some others) you must hand-decode their instruction layouts — do
NOT assume 8-byte Anchor discriminators. Verify every layout against the deployed program (clone + test).

---

## Cross-chain bridging

- **Circle CCTP (required)** — integrate the Solana **TokenMessengerMinter + MessageTransmitter** programs for
  native USDC burn-and-mint to/from EVM (`deposit_for_burn` on Solana, `receive_message` on the destination).
  Support **CCTP v2** (fast transfers + hooks) if available. Mirror the EVM `CircleDecoderAndSanitizer` intent:
  pin the mint recipient (must map to a controlled EVM/SVM address), the burn token = USDC, and the
  destination domain. Provide the deposit+bridge convenience flow the EVM vault has.
- **One canonical SVM↔EVM bridge (pick, justify; default = the one giving the vault's SHARE token parity):**
  - **LayerZero OFT on Solana** (Endpoint V2 + OFT program) — *recommended for parity*: the EVM share token is
    a LayerZero OFT (the EVM vault already bridges shares via LZ), so making the SVM share mint an OFT gives a
    unified omnichain share. Pin the OFT program, peer, and the SPL/receiver.
  - **Wormhole NTT (Native Token Transfers)** — the most "canonical" Solana↔EVM path for native tokens; use if
    LZ OFT parity isn't required. Pin the NTT manager, transceiver, and recipient.
  Provide the sanitizer + deploy wiring for the chosen bridge; leave the other as a documented adapter stub.

Include an on-chain **deposit-and-bridge** convenience flow (deposit → mint shares → bridge shares to EVM) and
its reverse, matching the EVM system's cross-chain deposit UX.

---

## Deploy scripts
- Anchor `Anchor.toml` with localnet/devnet/mainnet-beta profiles; a scripted, ordered deploy (buffers → deploy
  → set upgrade authority to Squads → init PDAs: roles, accountant rate providers, teller assets, vault share
  mint + transfer hook, manager roots) — the analog of the EVM `01_…`→`12_…` deploy sequence.
- **Verifiable builds** (`solana-verify`), IDL publish, and a machine-readable **address manifest** per cluster
  (program IDs + PDAs + share mint + bridge peers) for other repos to consume (analog of `deployments/*.json`).
- Upgrade-authority + admin all routed through the **Squads multisig**; no single-key authority in production.
- A merkle-root generator (off-chain, TS) + a manifest of each protocol's pinned account indices/data fields,
  and a script to `set_manage_root` per strategist.

## Tests (must be exhaustive, like the EVM repo)
- **Unit** (LiteSVM/Mollusk): every program instruction, every access-control path, PDA/bump/owner/signer
  checks, the merkle leaf verification, the balance-delta bracket, the burn-only-exit invariants.
- **Property/fuzz**: leaf verification, share↔asset math (accountant), supply-delta exactness, no-asset-move on
  exit. Use `cargo fuzz` / proptest for the Rust math + a TS fuzzer for instruction encodings.
- **Integration on cloned mainnet** (`solana-test-validator --clone` or `surfpool`): real end-to-end flows
  through each live protocol — e.g. Kamino deposit→borrow→repay→withdraw, an Orca/Raydium/Jupiter swap, a
  Lifinity swap, a CCTP `deposit_for_burn`, and a share bridge — driven through the vault+manager+merkle root,
  asserting real token-account balance changes AND that each generated leaf matches the sanitizer's
  expected pinned accounts/data (cross-check, to catch layout drift).
- **Compute-budget + tx-size assertions**: assert each gated action fits in CU + 1232 bytes (with ALTs); log
  and fail loudly if a flow requires the two-step propose/execute fallback.
- Gate cloned-mainnet tests on an RPC env var; skip cleanly when unset so CI stays green.

## Audit agent (Solana security expert) — REQUIRED, run adversarially throughout
Stand up (or act as) a dedicated **Solana-audit sub-agent** that reviews every program before it's considered
done, focused on **catastrophic loss / privilege escalation / fund drain**, with concrete exploit call-
sequences (not generic advice). Its checklist MUST include the Solana-specific classes:
- Missing **signer** checks; missing **owner** checks (account owned by expected program); **account-type
  confusion / "cosplay"** (deserializing an attacker account as the wrong type); missing `has_one`/constraint
  links (vault↔share-mint↔authority).
- **PDA** issues: non-canonical bump, unchecked seeds, PDA substitution; **duplicate mutable accounts**;
  **remaining_accounts** smuggling (the strategist passing extra writable accounts the sanitizer didn't pin —
  the #1 risk of this whole design).
- **Arbitrary CPI** (target program not pinned), **CPI to a look-alike program**, **re-init / close-then-
  revive** attacks, **rent/lamport draining**, **sysvar spoofing** (Clock/Instructions), **Token-2022 transfer-
  hook** abuse, **integer overflow** in accountant/teller math, **oracle** staleness/confidence bounds
  (Pyth/Switchboard), and the **merkle**: preimage/second-preimage on the leaf encoding, cross-strategist root
  confusion, replay across clusters (bind chain/cluster id).
- The **bridge** sanitizers: mint-recipient spoofing, wrong destination domain, unverified attestation/peer.
For each program: enumerate actors + a threat model, walk backward from every value-moving CPI/`invoke_signed`
and every mint/burn, and either produce a concrete exploit or an explicit "confirmed sound because…". Re-run
after fixes. Treat the "remaining_accounts / unpinned writable account" surface as the primary drain vector and
prove it closed.

## Milestones (stop and report at each; get sign-off before scaling)
1. **Design doc + core spike**: the account-model merkle-CPI design, the size/CU budget analysis, and a working
   single-CPI gated `manage` on cloned mainnet (Orca swap). Include the propose/execute fallback decision.
2. Core programs (vault, roles, manager-merkle, teller, accountant, freeze-hook) + unit tests + first audit pass.
3. Manager variants (balance-delta + flash-loan adapter/placeholder, token-balance, simulator, burn-only exit),
   withdraw/atomic queues + tests + audit.
4. Decoder/sanitizer modules: lending (Kamino/MarginFi/Save/Drift), DEXes (Jupiter/Orca/Raydium/Meteora/
   Phoenix), prop-AMM (Lifinity/RFQ), vault-share set — each with cloned-mainnet integration tests + audit.
5. Bridges (CCTP + chosen canonical bridge) + deposit-and-bridge flows + tests + audit.
6. Deploy scripts, verifiable builds, address manifest, merkle-root generator + docs; final full-system audit.

## Deliverables
A complete Anchor workspace (`programs/*`, `tests/*`, `migrations`/deploy scripts, `scripts/*`, `app`/TS SDK),
a per-cluster address manifest, the merkle-root generator + per-protocol pinned-field manifest, full test suite
(unit+fuzz+cloned-mainnet integration, all green or clearly-gated-skipped), a design doc covering the account-
model translation + constraints, and an audit report per program with the threat models and confirmed-sound /
fixed findings.

## Ground rules
- Do NOT invent program IDs, discriminators, or account layouts — **clone the real mainnet programs and verify
  every layout against them** (especially non-Anchor: Raydium, OpenBook, CCTP, Wormhole/LZ). If you can't
  verify a layout, mark it TODO and gate it, don't guess.
- Prefer the smallest trusted surface: pin the vault as owner/authority/recipient wherever the protocol allows;
  treat opaque route/quote blobs as bounded only by the target program's own min-out/slippage guard, and pin
  everything around them.
- Everything privileged is role-gated (never a hardcoded key) and admin-controlled by the Squads multisig.
- Flag every place where Solana semantics diverge from the EVM original (flash loans, no canonical 4626,
  reserveId→pubkey, tx-size limits, transfer hooks) with a short rationale, so a reviewer familiar with the EVM
  repo can follow the mapping.
