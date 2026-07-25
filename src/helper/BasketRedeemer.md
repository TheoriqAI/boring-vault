# BasketRedeemer — design & operations (DRAFT)

A standalone, **uniform fixed-weight, all-or-nothing** redeemer for a BoringVault. Every redeemer
receives the *same* asset composition proportional to the shares they redeem (e.g. 30% USDC / 40%
MMF / 30% bond), so splitting shares across addresses (Sybil) gains nothing. A redemption either
fills **every** leg atomically now, or escrows the **whole** redemption as one coupled claim that
settles atomically later or cancels back to 100% shares. See the contract natspec for the full
rationale.

> Status: design sketch. NOT audited, NOT wired into the deployment pipeline. Do not deploy without
> an independent audit and a full Foundry test suite.

## Why this shape (the road we walked)
- **Per-address instant-cash caps are Sybil-bypassable** (free addresses + transferable shares), so a
  "small = instant USDC" tier can always be gamed by fragmenting a large redemption. Only a *global*
  cap is enforceable, and that's just a first-come race. → We removed the instant tier entirely.
- **Uniform slice** makes cash allocation depend only on fixed weights, not address count — Sybil-neutral.
- **All-or-nothing** stops cash-and-run cherry-picking: cash never leaves without the full slice, so
  cancelling a deferred claim returns 100% shares and 0 cash.

## Roles this contract needs
- **SOLVER_ROLE** on the vault's `RolesAuthority` (it calls `teller.bulkWithdraw`, which is `requiresAuth`).
  Without it, `redeem` of a coverable slice reverts *loudly* (by design — no silent partial pay).
- An **owner** (admin Safe) for `setBasket`, `setMinRedeemShares`, `setClaimExpiry`, `redirectClaim`,
  and to authorize keepers for `settleClaim`.

## Locking down the WithdrawQueue so BasketRedeemer is the only front door
`WithdrawQueue.submitOrder` is currently a **public** capability (deploy steps 07/10), so users could
bypass the slice and cherry-pick a single asset directly from the queue. Make it permissioned — a pure
authority change on the existing `RolesAuthority`, **no redeploy**:

```solidity
// as the protocol-admin (owner of RolesAuthority):
// 1. remove the public capability
rolesAuthority.setPublicCapability(withdrawQueue, WithdrawQueue.submitOrder.selector, false);

// 2. gate submitOrder to a new REDEEMER_ROLE (roles 1-10 are used in Constants.sol; use 11)
rolesAuthority.setRoleCapability(REDEEMER_ROLE, withdrawQueue, WithdrawQueue.submitOrder.selector, true);

// 3. grant it only to the BasketRedeemer (and/or the desk multisig)
rolesAuthority.setUserRole(basketRedeemer, REDEEMER_ROLE, true);

// cancelOrder / cancelOrderWithSignature stay PUBLIC so NFT owners can always cancel their own orders.
```

After this:
- Direct users can no longer `submitOrder` (no more single-asset cherry-picking).
- `processOrders` remains gated to `WITHDRAW_QUEUE_PROCESSOR_ROLE` (your keeper) as before.
- Users keep the public `cancelOrder` on any order NFT they own.

Note: in the chosen **standalone** design the BasketRedeemer keeps its *own* coupled-claim escrow and
does not itself call the queue. Permissioning `submitOrder` simply closes the bypass; the queue then
serves as an admin/keeper tool for bespoke or manual redemptions.

## Hardening applied after adversarial review
- **Basket drift → snapshot:** each `Claim` snapshots its `(assets, legShares)` at open; `settleClaim`
  pays the snapshot, so an admin `setBasket` after a claim is opened cannot change what a deferred
  redeemer settles into.
- **Dust → uniform guarantee:** `redeem` rejects (`RedeemTooSmallForSlice`) any amount so small that a
  non-zero-weight leg would round to 0 shares, so a "covered" redeem always delivers the true slice.
- **Dead `deferrable` flag removed**; weight accumulator widened to `uint256`.

## Optional authorization policy (IRedeemPolicy hook)
`BasketRedeemer.policy` is an optional hook (`address(0)` = permissionless). When set, `redeem` and
`settleClaim` call `policy.authorizeRedeem(caller, receiver, shares, authData)`, which reverts to deny;
`cancelClaim` is intentionally ungated (returns shares, not assets). `PredicateRedeemPolicy` is a
reference backend mirroring `DistributorCodeDepositor`'s flag-gated KYT.

Wiring order + operational notes (from adversarial review):
- Deploy the policy, `policy.setRedeemer(basketRedeemer)`, then `basketRedeemer.setPolicy(policy)`.
- `PredicateRedeemPolicy.enabled` defaults **true** (secure-by-default): a set policy enforces unless
  you explicitly `setEnabled(false)`. This avoids the silent fail-open of a set-but-disabled policy.
- When a policy is enabled, **keepers must call the 3-arg `settleClaim(id, minOut, authData)` overload**
  (and be granted that selector) and supply a fresh attestation bound to the claim's receiver — the
  legacy 2-arg overload forwards empty authData and will revert at attestation decode.
- The Predicate policy is pinned to one `redeemer`; two redeemers cannot share one policy instance.

## Config to set at deploy / before prototyping further
- **`minRedeemShares`:** set non-zero (roughly ≥ BPS scaled to weights) so small redeems are rejected
  cleanly rather than reverting per-leg.
- **`claimExpiry`:** set it so abandoned claims can be swept back to their receiver (0 disables the
  sweep). Note: the sweep always pays the *receiver*, so there is no reward for a third-party sweeper.
- **Owner must be a multisig (ideally timelocked):** `redirectClaim` is an unconditional reassign power
  for stuck/frozen receivers.
- **Fees:** none charged here; add a fee module hook if desired (mirror `WithdrawQueueAssetSpecificFeeModule`).
- **Pricing the illiquid leg:** every leg is priced via `accountant.getRateInQuoteSafe`, so the bond
  needs a trusted NAV rate provider (same trust model as the exchange-rate bot) with min/max bounds.
