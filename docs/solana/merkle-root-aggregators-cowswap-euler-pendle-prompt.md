# Prompt: wire aggregators (Kyber/Odos) + CowSwap + Euler + Pendle limit-orders into the merkle-root generator

You are working in the **merkle-root generator repo** for a BoringVault system (Veda/Se7enSeas "BoringVault +
ManagerWithMerkleVerification" architecture, Theoriq fork). New decoder/sanitizers were added in the contracts
repo and folded into `nextgen/FullDecoderAndSanitizer.sol`. Add address-book entries + leaf-generation helpers
+ tests for: **KyberSwap**, **Odos**, **CowSwap** (module), **Euler v2 (EVK/EVC)**, and **Pendle on-chain
limit orders (vault as taker)**. (Aave V4 and Morpho Midnight are already done — do NOT redo them.)

## How a leaf is built (must match the manager exactly)
```
leaf = keccak256(abi.encodePacked(
    decoderAndSanitizer,    // deployed FullDecoderAndSanitizer address
    target,                 // contract the vault calls
    valueIsNonZero,         // bool: can this call send native ETH? (false for all below)
    selector,               // bytes4 of the target function
    packedArgumentAddresses // abi.encodePacked(...) of sanitized addresses, IN THE DECODER'S ORDER
))
```
`packedArgumentAddresses` MUST equal what the decoder returns for that call (order matters). Struct params
expand to their ABI tuple for the selector; use `src/interfaces/DecoderCustomTypes.sol` and
`src/interfaces/IGPv2.sol` VERBATIM (field order/types are load-bearing). Decoder source is the source of truth.

---

## Task 1 — Address book (mainnet, chainId 1 unless noted)

- KyberSwap MetaAggregationRouterV2: `0x6131B5fae19EA4f9D964eAc0408E4408b66337b5`
- Odos RouterV2: `0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559`
- Euler EVC: `0x0C9a3dD6b8F28529d72d7f9cE918D493519EE383` (eVaults are per-market — pull from Euler's vault list)
- Pendle Router V4: `0x888888888889758F76e7103c6CbF23ABbF58F946`
- CowSwap GPv2 (same on all chains; for the module's constructor, NOT a leaf target): Settlement
  `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`, VaultRelayer `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110`
- **OKX DexRouter: DO NOT add / DO NOT generate leaves.** Its router parses an optional commission blob
  appended after the ABI args (read via `calldatasize()`), invisible to a selector-matched decoder → a rogue
  strategist could append it to skim funds. Excluded by design.

---

## Task 2 — KyberSwap + Odos (aggregators)

Model (like 1inch): the leaf pins the call/approve targets, src/dst tokens, and every receiver — most
importantly the **dst/output receiver, which the root MUST pin to the BoringVault**. The inner route blob
(`targetData`/`executorData`/`pathDefinition`) is NOT decoded; it's bounded by the router delivering
`minReturn`/`outputMin` to the pinned receiver. Also add an ERC20 `approve(address,uint256)` leaf on each
srcToken with the router (or Kyber `approveTarget`) as the pinned spender.

### KyberSwap (target = MetaAggregationRouterV2). Reverts if a permit is attached (pin permit-free swaps).
| Action | signature | packedArgumentAddresses |
|---|---|---|
| swap | `swap((...KyberSwapExecutionParams...))` | `callTarget, approveTarget, desc.srcToken, desc.dstToken, desc.dstReceiver, [srcReceivers...], [feeReceivers...]` |
| swapSimpleMode | `swapSimpleMode(address,(...KyberSwapDescriptionV2...),bytes,bytes)` | `caller, desc.srcToken, desc.dstToken, desc.dstReceiver, [srcReceivers...], [feeReceivers...]` |

`srcReceivers[]` then `feeReceivers[]` are appended with NO length delimiter — generate them in that exact
order. Pin `dstReceiver = boringVault`.

### Odos (target = OdosRouterV2)
| Action | signature | packedArgumentAddresses |
|---|---|---|
| swap | `swap((...OdosSwapTokenInfo...),bytes,address,uint32)` | `tokenInfo.inputToken, tokenInfo.inputReceiver, tokenInfo.outputToken, tokenInfo.outputReceiver, executor` |
| swapMulti | `swapMulti((...OdosInputTokenInfo...)[],(...OdosOutputTokenInfo...)[],uint256,bytes,address,uint32)` | `[for each input: tokenAddress, receiver], [for each output: tokenAddress, receiver], executor` |

Pin `outputReceiver` / every output `receiver` = boringVault. **Do NOT use `swapCompact()`/`swapMultiCompact()`**
— their custom non-ABI calldata can't be sanitized by a selector-matched decoder; route through `swap`/`swapMulti`.

Struct layouts: `KyberSwapExecutionParams`, `KyberSwapDescriptionV2`, `OdosSwapTokenInfo`,
`OdosInputTokenInfo`, `OdosOutputTokenInfo` — from `DecoderCustomTypes.sol` verbatim.

---

## Task 3 — CowSwap (on-chain limit orders via the module)

CowSwap needs a stateful **`CowSwapOrderModule`** deployed per vault (a pure decoder can't gate the opaque
`setPreSignature(bytes uid)`). The vault calls the MODULE; the module enforces order integrity/receiver/uid
binding and pre-signs. **Leaf `target` = the deployed CowSwapOrderModule address** (not GPv2 settlement).

Structs: `CowSwapLimitParams { address tokenIn; address tokenOut; uint256 amountIn; uint256 minAmountOut; uint32 deadline; }`;
`GPv2Order.Data { address sellToken; address buyToken; address receiver; uint256 sellAmount; uint256 buyAmount; uint32 validTo; bytes32 appData; uint256 feeAmount; bytes32 kind; bool partiallyFillable; bytes32 sellTokenBalance; bytes32 buyTokenBalance; }`.

| Action | signature (tuple-expanded) | packedArgumentAddresses |
|---|---|---|
| createLimitOrder | `createLimitOrder((address,address,uint256,uint256,uint32),(address,address,address,uint256,uint256,uint32,bytes32,uint256,bytes32,bool,bytes32,bytes32),bytes)` | `params.tokenIn, params.tokenOut` |
| setCowswapApproval | `setCowswapApproval(address,uint256)` | `token` |
| pullAssets | `pullAssets(address,uint256)` | `token` |
| invalidateOrder | `invalidateOrder(bytes)` | (empty) |
| setAllowedToken | `setAllowedToken(address,bool)` | `token` (admin — owner-gated on the module) |

Also add an ERC20 `transfer(address,uint256)` leaf on each sell token with recipient = the module (the vault
pushes the sell token to the module before creating the order; sanitized by the Base decoder). Price
(`minAmountOut`) is strategist-set (integrity-only, like 1inch minReturn) — pin tokens, not price.

---

## Task 4 — Euler v2 (EVK/EVC)

Two target types. EVC (`0x0C9a3dD6b8F28529d72d7f9cE918D493519EE383`) for collateral/controller mgmt + `batch`;
a specific **eVault** as `target` for borrow/repay/pullDebt/disableController(). The decoder FORCES
account/receiver/owner == boringVault (reverts otherwise), so those leaves pin nothing extra.

EVC target:
| Action | signature | packed |
|---|---|---|
| enableCollateral | `enableCollateral(address,address)` | `vault` (the collateral eVault) |
| disableCollateral | `disableCollateral(address,address)` | `vault` |
| enableController | `enableController(address,address)` | `vault` (the controller eVault) |
| disableController(account) | `disableController(address)` | (empty) |
| batch | `batch((address,address,uint256,bytes)[])` | per item, concatenated: `item.targetContract, item.value (uint256, 32 bytes), <sub-call packed>` |

eVault target (per market):
| borrow | `borrow(uint256,address)` | (empty) |
| repay | `repay(uint256,address)` | (empty) |
| repayWithShares | `repayWithShares(uint256,address)` | (empty) |
| pullDebt | `pullDebt(uint256,address)` | `from` |
| disableController() | `disableController()` | (empty) |

`batch` sub-call packing (must match `_sanitizeEulerCall`) — for each `BatchItem{targetContract,
onBehalfOfAccount(==vault), value, data}`, after `targetContract` + `value` append the sub-call's packed
addresses by selector: enable/disableCollateral & enableController → `vault`; disableController(address) →
empty; deposit/mint/borrow/repay/repayWithShares → empty; withdraw/redeem → empty; pullDebt → `from`;
disableController() → empty. Direct (non-batch) eVault ERC-4626 `deposit/mint/withdraw/redeem` are handled by
the **ERC4626** decoder (target = eVault) — generate those with the ERC4626 leaf helpers.

Euler v2 selectors: enableCollateral `0xd44fee5a`, disableCollateral `0xe920e8e0`, enableController
`0xc368516c`, disableController(address) `0xf4fc3570`, deposit `0x6e553f65`, mint `0x94bf804d`, withdraw
`0xb460af94`, redeem `0xba087652`, borrow `0x4b3fd148`, repay `0xacb70815`, repayWithShares `0xa9c8eb7e`,
pullDebt `0xaebde56b`, disableController() `0x869e50c7`.

---

## Task 5 — Pendle on-chain limit orders (vault as TAKER)

Pendle Router V4 `target = 0x888888888889758F76e7103c6CbF23ABbF58F946`. Four functions now SANITIZE an
attached on-chain limit order (previously reverted). Aggregator swaps are still forbidden. Base pins unchanged;
when a `LimitOrderData` is attached you APPEND the limit-order addresses:

| Function | base packed | + limit-order packed |
|---|---|---|
| swapExactPtForToken | `receiver, market, output.tokenOut` | `_limitOrderAddresses(limit)` |
| swapExactTokenForPt | `receiver, market, input.tokenIn` | `_limitOrderAddresses(limit)` |
| addLiquiditySingleToken | `receiver, market, input.tokenIn` | `_limitOrderAddresses(limit)` |
| removeLiquiditySingleToken | `receiver, market, output.tokenOut` | `_limitOrderAddresses(limit)` |

`_limitOrderAddresses(limit)`: if `limit.limitRouter == address(0)` → empty (a plain swap leaf is unchanged).
Else `abi.encodePacked(limit.limitRouter)`, then for EACH fill in `limit.normalFills[]` and THEN each in
`limit.flashFills[]`: `order.token, order.YT, order.maker, order.receiver` (in that order). Taker path: pin the
Pendle limit-order router + every maker order's token/YT/maker/receiver you intend to fill (get the maker
orders + LOB router from the Pendle limit-order API / the orders the vault will take). `LimitOrderData` /
`Order` / `FillOrderParams` / `TokenInput` / `TokenOutput` / `ApproxParams` tuples: `DecoderCustomTypes.sol`
verbatim.

---

## Task 6 — Build + test a root

1. Add per-protocol leaf generators (mirror the existing per-protocol functions; each returns a leaf hash for
   the (target, selector, packedAddresses) above). Pin every receiver/dstReceiver/outputReceiver to the
   BoringVault.
2. Build a tree with: the aggregator swaps (approves + Kyber/Odos with dstReceiver=vault), the CowSwap module
   flow (transfer→createLimitOrder→pullAssets), Euler (enableCollateral/enableController on EVC + borrow/repay
   on an eVault, and one `batch`), and one Pendle swap WITH a limit order. Emit the root.
3. **Fork tests** (deploy FullDecoderAndSanitizer + BoringVault + ManagerWithMerkleVerification + RolesAuthority;
   `setManageRoot(strategist, root)`):
   - Aggregators: execute a real Kyber and Odos swap via `manageVaultWithMerkleVerification`, assert the vault
     receives the output token (dstReceiver pinned to vault).
   - CowSwap: transfer sell token to module → createLimitOrder (module pre-signs) → assert relayer allowance ==
     sellAmount and the order is pre-signed; pullAssets back.
   - Euler: enableCollateral/enableController on the EVC, supply/borrow on an eVault, repay, disableController.
   - Pendle: a swapExactTokenForPt (or swapExactPtForToken) carrying a real limit order; assert it fills.
   - Gate each fork test on its RPC env var and skip when unset. If any protocol reverts `NotActivated`, re-run
     with `--evm-version cancun` (some of these use transient storage and the repo may pin a pre-Cancun EVM).
4. For every generated leaf assert `leaf == keccak256(abi.encodePacked(decoder, target, false, selector, packed))`
   AND that the decoder's returned bytes for the exact calldata equal your `packed` — this catches any
   pack-order / selector drift (especially the dynamic parts: Kyber/Odos receiver arrays, Euler `batch`, and
   Pendle `_limitOrderAddresses`).

## Reference (contracts repo — source of truth for pack order + selectors)
`src/base/DecodersAndSanitizers/Protocols/KyberSwapDecoderAndSanitizer.sol`, `.../OdosDecoderAndSanitizer.sol`,
`.../CowSwapDecoderAndSanitizer.sol`, `.../EulerDecoderAndSanitizer.sol`, `.../PendleRouterDecoderAndSanitizer.sol`;
`src/interfaces/DecoderCustomTypes.sol`, `src/interfaces/IGPv2.sol`; the CowSwap module
`src/helper/CowSwapOrderModule.sol`; combined in `.../nextgen/FullDecoderAndSanitizer.sol`. The
FullDecoderAndSanitizer is UNAUDITED and not yet deployed — deploy fresh (record its address) before any
production root.
