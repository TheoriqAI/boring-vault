# EpochDepositor

> **DRAFT — NOT AUDITED, NOT WIRED INTO DEPLOY.** Reviewed by an internal adversarial pass (no HIGH
> findings; MED/LOW hardened — see [Security](#security)). Needs a formal audit before production.

An **epoch-batched, [ERC-7540](https://eips.ethereum.org/EIPS/eip-7540)-aligned asynchronous depositor**
for a BoringVault. Instead of minting shares synchronously (as the teller does), deposits accumulate over
an **epoch** and settle together at a **single clearing price**, interval-fund style. It is the deposit-side
counterpart to the `EpochBasketRedeemer` withdrawal pattern.

Contract: [`src/helper/EpochDepositor.sol`](./EpochDepositor.sol) ·
Interfaces: [`IERC7540Deposit`](../../interfaces/IERC7540Deposit.sol),
[`IDepositPolicy`](../../interfaces/IDepositPolicy.sol) ·
Tests: [`test/EpochDepositor.t.sol`](../../../test/EpochDepositor.t.sol),
[`test/EpochDepositorInvariant.t.sol`](../../../test/EpochDepositorInvariant.t.sol)

---

## Lifecycle

```
  ┌── open epoch N ───────────────────────────┐   closeEpoch()          claim / disperse
  │  requestDeposit ──► deposited[N][user] ↑   │   (permissionless,      (per-user or batch)
  │  cancelDeposit  ──► deposited[N][user] ↓   │    after settleTime)
  │  (assets escrowed in the contract)         │        │                     │
  └────────────────────────────────────────────┘        ▼                     ▼
                                             snapshot accountant rate     pro-rata shares
                                             mint WHOLE epoch to pool     from the pool → user
                                             open epoch N+1
```

- **One open epoch at a time.** Requests land in `currentEpoch` until its `settleTime`.
- **Settlement is permissionless** once `settleTime` passes: `closeEpoch()` snapshots
  `accountant.getRateInQuoteSafe(asset)`, mints the whole epoch's shares to the contract via
  `vault.enter`, and opens the next epoch.
- **Claiming pulls a pro-rata slice** of that epoch's minted shares:
  `shares = deposited · sharesMinted / totalAssets` (equal to `deposited · ONE_SHARE / clearingRate`).

## ERC-7540 mapping (`requestId` = epoch id)

| ERC-7540 | EpochDepositor |
|---|---|
| `requestDeposit(assets, controller, owner)` | add `assets` to the current open epoch (escrowed) |
| `pendingDepositRequest(epoch, controller)` | your assets in an unsettled epoch |
| operator "fulfill" | `closeEpoch()` — settles the whole epoch at one price |
| `claimableDepositRequest(epoch, controller)` | your assets in a settled epoch, claimable as shares |
| `deposit(assets, receiver, controller)` / `mint(shares, …)` | claim your sole settled epoch |
| `cancelDepositRequest(epoch, controller)` | full cancel + refund (open epoch only) |
| `setOperator` / `isOperator` | operator approval |
| `asset()` / `share()` | deposit asset / BoringVault share token |

Epoch-native equivalents (`closeEpoch`, `claim(epoch,…)`, `cancelDeposit(amount,…)`, `cancelAll`,
`disperse`, `previewClaim`, `liveEpochs`) are provided alongside the standard surface.

## Requirements this was built to

| # | Requirement | Mechanism |
|---|---|---|
| a | Minimum deposit per epoch; adds/subtracts tracked per mapping | `deposited[epoch][controller]` ± on request/cancel; request must leave total `≥ minDepositPerEpoch` |
| b | Threshold must hold at all times, else full cancel (no dust) | a partial cancel leaving `0 < remaining < min` **reverts**; use `cancelAll` to exit fully |
| c | End of epoch clears at price | `closeEpoch()` snapshots the accountant rate once; whole epoch fills at that NAV |
| d | Epoch time flexible, guarded within 24h of beginning | `retimeCurrentEpoch` frozen within `GUARD_WINDOW` (24h) of settlement; `setEpochDuration` future-only |
| + | Refunds | `cancel` refunds immediately; `refundEpoch()` abandons a stuck settlement and unlocks `refund(epoch,…)` |
| + | Auth gating (predicate proxy) | pluggable `IDepositPolicy` hook, opaque `authData`; zero address = permissionless |
| + | Atomic mint from trusted auth, optional fee | `atomicMint(receiver, assetsIn, minShares)` (`requiresAuth`), optional `atomicFeeBps` → `feeRecipient` |
| + | Claim + open batch dispersal | `claim(epoch,…)`; permissionless `disperse(epoch, controllers[])` |
| + | Async vault interface standards | ERC-7540 deposit subset (table above) |

## Clearing price

The clearing rate is **`accountant.getRateInQuoteSafe(asset)` snapshotted at `closeEpoch`** — the same NAV
the teller uses to price synchronous deposits. Every depositor in an epoch fills at that one rate; there is
no operator discretion over price. A degenerate rate (would mint zero shares) makes `closeEpoch` revert,
leaving the epoch recoverable via `refundEpoch`.

## Roles & deploy wiring

Access uses solmate `requiresAuth` (no hardcoded roles — assign via the vault's `RolesAuthority`):

- **OWNER / admin** → `setMinDepositPerEpoch`, `setEpochDuration`, `retimeCurrentEpoch`, `setDepositPolicy`,
  `setFeeConfig`, `refundEpoch`.
- **ATOMIC-MINTER** (trusted) → `atomicMint`. Recommend a tightly-held role, not public.
- **Public** → `requestDeposit`, `cancel*`, `closeEpoch`, `claim`, `disperse`, `setOperator`
  (subject to the deposit policy).

**Required at deploy:** grant the depositor the BoringVault's **`enter`** capability
(`rolesAuthority.setRoleCapability(MINTER_ROLE, vault, BoringVault.enter.selector, true)` +
`setUserRole(depositor, MINTER_ROLE, true)`) — it mints by calling `vault.enter` directly at settlement and
atomic-mint. Deposit caps / asset-support are **not** re-checked here (single configured asset + accountant
rate only).

## Security

Internal adversarial review found **no HIGH** issues; the pooled-share accounting was verified sound
(`Σ claims ≤ sharesMinted` per epoch — no cross-epoch or atomic-mint drain; dust-only surplus). MED/LOW
items were hardened:

- **Fee-on-transfer / rebasing assets are unsupported.** Requests and atomic-mint credit the *actual
  received* balance (delta) so escrow accounting stays consistent, but settlement mints against the nominal
  amount — a FoT asset would under-collateralize the vault. Use a standard ERC20.
- **Accountant is trusted;** `closeEpoch`/`atomicMint` reject the degenerate zero-shares case (revert →
  recoverable via `refundEpoch`).
- **`retimeCurrentEpoch`** guarantees ≥24h certainty *measured from the retime*; outside the window an
  operator may bring a far-out settlement in to `now + 24h` (never sooner, never into the past).
- **ERC-7540 "gifting"** (crediting `controller ≠ owner`) can bloat a victim's live-epoch set and force
  `AmbiguousClaim` on the `deposit`/`mint` convenience path — the victim is unharmed (keeps the gifted
  assets) and always claims via `claim(epoch,…)`.

These are recorded in the contract's `ASSUMPTIONS / KNOWN LIMITS` NatSpec block.

## Testing

- **Unit** (`EpochDepositor.t.sol`, 15 tests): min-enforcement, dust-cancel revert, pro-rata at unit and
  non-unit rate, ERC-7540 `deposit`/`mint` claim, `disperse`, `atomicMint` (+ fee, + auth), operator, policy
  gate, timing guard, refund, degenerate-rate revert-then-refund, empty-settled-epoch preview, and a
  pro-rata fuzz.
- **Invariant** (`EpochDepositorInvariant.t.sol`, 256 runs × 128k calls, 0 reverts): a handler drives random
  request/cancel/close/claim/disperse/atomicMint/rate sequences; the invariants assert
  **`vault.balanceOf(depositor) ≥ Σ outstanding claimable shares`** and
  **`asset.balanceOf(depositor) ≥ Σ open/refundable deposits`**, plus live-set consistency.
