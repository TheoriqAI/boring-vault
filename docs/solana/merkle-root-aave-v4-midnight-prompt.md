# Prompt: wire Aave V4 + Morpho Midnight into the merkle-root generator

You are working in the **merkle-root generator repo** for a BoringVault system (the Veda/Se7enSeas
"BoringVault + ManagerWithMerkleVerification" architecture, Theoriq fork). Two new decoder/sanitizers were
added in the contracts repo and folded into `nextgen/FullDecoderAndSanitizer.sol`:
**Aave V4 (Hub-and-Spoke)** and **Morpho Midnight**. Your job is to (1) add the needed addresses to the
address book, (2) add leaf-generation helpers for every action of both protocols, and (3) build + test a
merkle root that authorizes real Aave V4 and Midnight actions.

## How a leaf is built (must match the manager exactly)
```
leaf = keccak256(abi.encodePacked(
    decoderAndSanitizer,   // address of the deployed FullDecoderAndSanitizer
    target,                // contract the vault calls (a Spoke, or the Midnight core)
    valueIsNonZero,        // bool: can this call send native ETH? (false for all below)
    selector,              // bytes4 of the target function
    packedArgumentAddresses// abi.encodePacked(...) of the sanitized addresses, IN THE DECODER'S ORDER
))
```
`packedArgumentAddresses` MUST exactly match what the decoder returns (order matters). The decoder source is
the source of truth — see `src/base/DecodersAndSanitizers/Protocols/AaveV4DecoderAndSanitizer.sol` and
`.../MorphoMidnightDecoderAndSanitizer.sol` in the contracts repo. The pack orders are reproduced below.

---

## Task 1 — Address book

### Aave V4 — Ethereum mainnet (chainId 1)
Source: `bgd-labs/aave-address-book` → `src/AaveV4Ethereum.sol` (RE-VERIFY byte-for-byte before production).
Users/vault call the **Spokes**; the Hub is internal and needs no leaves (add Hubs for reference only).

Hubs:
- CORE_HUB   `0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9`
- PLUS_HUB   `0x06002e9c4412CB7814a791eA3666D905871E536A`
- PRIME_HUB  `0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931`
- PAXOS_HUB  `0x62d63197660c080236193CA60b70E49A08E90368`

Spokes:
- MAIN_SPOKE              `0x94e7A5dCbE816e498b89aB752661904E2F56c485`
- BLUECHIP_SPOKE          `0x973a023A77420ba610f06b3858aD991Df6d85A08`
- FOREX_SPOKE             `0xD8B93635b8C6d0fF98CbE90b5988E3F2d1Cd9da1`
- GOLD_SPOKE             `0x65407b940966954b23dfA3caA5C0702bB42984DC`
- USDG_PENDLE_SPOKE       `0x956d8e0A89cfa3744428C4641b5a53B56167a7f9`
- ETHENA_ECOSYSTEM_SPOKE  `0xba1B3D55D249692b669A164024A838309B7508AF`
- ETHENA_CORRELATED_SPOKE `0x58131E79531caB1d52301228d1f7b842F26B9649`
- TREASURY_SPOKE          `0xB9B0b8616f6Bf6841972a52058132BE08d723155`
- LOMBARD_BTC_SPOKE       `0x7EC68b5695e803e98a21a9A05d744F28b0a7753D`
- ETHERFI_ESPOKE          `0xbF10BDfE177dE0336aFD7fcCF80A904E15386219`
- KELP_ESPOKE             `0x3131FE68C4722e726fe6B2819ED68e514395B9a4`
- LIDO_ESPOKE             `0xe1900480ac69f0B296841Cd01cC37546d92F35Cd`

Assets (mainnet): USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` · EURC `0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c` · USDG `0xe343167631d89B6Ffc58B88d6b7fB0228795491D` (all 6 decimals).

### Morpho Midnight — Base mainnet (chainId 8453)  ← ADD THIS to the address book
Midnight is **Base-only** (not on mainnet). Basescan-verified core ("Morpho: Midnight", solc 0.8.34):
- MIDNIGHT_CORE (Base) `0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A`
- USDC (Base)          `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- cbBTC (Base)         `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`
The `target` for every Midnight leaf is the single MIDNIGHT_CORE address.

---

## Task 2 — Aave V4 Spoke leaf generators

**CRITICAL:** in Aave V4 a reserve is a `uint256 reserveId` (Spoke-local index), NOT an asset address. A leaf
CANNOT pin the market/asset (reserveId isn't an address) — only the address arg is pinned. Constrain the
market by (a) which **Spoke `target`** the leaf allows and (b) generating leaves only for the reserveIds you
intend. Discover reserveIds ON-CHAIN (they can change / repeat per hub):
```solidity
uint256 n = ISpoke(spoke).getReserveCount();
for (uint256 id; id < n; id++) if (ISpoke(spoke).getReserve(id).underlying == asset) { /* reserveId = id */ }
```
`getReserve(uint256) returns (Reserve{address underlying; address hub; uint16 assetId; uint8 decimals; uint24 collateralRisk; uint8 flags; uint32 dynamicConfigKey})`. On MAIN_SPOKE at block ~25.6M: USDC=reserveId 7, EURC=9, USDG=11 (discover, don't hardcode).

Generate one leaf per (spoke, action) with this signature + pinned address (verbatim from ISpoke.sol):
| Action | selector signature | packedArgumentAddresses |
|---|---|---|
| supply | `supply(uint256,uint256,address)` | `abi.encodePacked(onBehalfOf)` |
| withdraw | `withdraw(uint256,uint256,address)` | `abi.encodePacked(onBehalfOf)` |
| borrow | `borrow(uint256,uint256,address)` | `abi.encodePacked(onBehalfOf)` |
| repay | `repay(uint256,uint256,address)` | `abi.encodePacked(onBehalfOf)` |
| setUsingAsCollateral | `setUsingAsCollateral(uint256,bool,address)` | `abi.encodePacked(onBehalfOf)` |
| liquidationCall | `liquidationCall(uint256,uint256,address,uint256,bool)` | `abi.encodePacked(user)` |
| setUserPositionManager | `setUserPositionManager(address,bool)` | `abi.encodePacked(positionManager)` |
| permitReserve | `permitReserve(uint256,address,uint256,uint256,uint8,bytes32,bytes32)` | `abi.encodePacked(onBehalfOf)` |

For the vault to hold positions, pin `onBehalfOf = user = boringVault` in every leaf. Also add the ERC20
`approve(address,uint256)` leaf on each asset with the Spoke as the pinned spender (needed before supply/repay).
Borrow sequence: approve → supply → setUsingAsCollateral(true) → borrow (health-checked); repay → withdraw.

---

## Task 3 — Morpho Midnight leaf generators (target = MIDNIGHT_CORE on Base)

Midnight identifies a market by the full `Market` struct passed by value. The decoder pins all market
addresses via `_marketAddresses(market)`:
```
_marketAddresses(m) = abi.encodePacked(
    m.midnight, m.loanToken, m.enterGate, m.liquidatorGate,
    // then, for each collateral i in m.collateralParams:
    m.collateralParams[i].token, m.collateralParams[i].oracle
)
```
Struct layouts (VERBATIM from morpho-org/midnight `IMidnight.sol` — field order/types are load-bearing for
the selector):
```solidity
struct CollateralParams { address token; uint256 lltv; uint256 liquidationCursor; address oracle; }
struct Market { uint256 chainId; address midnight; address loanToken; CollateralParams[] collateralParams;
                uint256 maturity; uint256 rcfThreshold; address enterGate; address liquidatorGate; }
struct Offer  { Market market; bool buy; address maker; uint256 start; uint256 expiry; uint256 tick;
                bytes32 group; address callback; bytes callbackData; address receiverIfMakerIsSeller;
                address ratifier; bool reduceOnly; uint128 maxUnits; uint128 maxAssets; uint256 continuousFeeCap; }
```
Leaf per action (selector = keccak of the tuple-expanded signature; compute from the struct types):
| Action | signature (tuple-expanded for structs) | packedArgumentAddresses |
|---|---|---|
| take | `take((...Offer...),bytes,uint256,address,address,address,bytes)` | `_marketAddresses(offer.market), offer.maker, offer.callback, offer.receiverIfMakerIsSeller, offer.ratifier, taker, receiverIfTakerIsSeller, takerCallback` |
| withdraw | `withdraw((...Market...),uint256,address,address)` | `_marketAddresses(m), onBehalf, receiver` |
| repay | `repay((...Market...),uint256,address,address,bytes)` | `_marketAddresses(m), onBehalf, callback` |
| supplyCollateral | `supplyCollateral((...Market...),uint256,uint256,address)` | `_marketAddresses(m), onBehalf` |
| withdrawCollateral | `withdrawCollateral((...Market...),uint256,uint256,address,address)` | `_marketAddresses(m), onBehalf, receiver` |
| liquidate | `liquidate((...Market...),uint256,uint256,uint256,address,bool,address,address,bytes)` | `_marketAddresses(m), borrower, receiver, callback` |
| setIsAuthorized | `setIsAuthorized(address,bool,address)` | `authorized, onBehalf` |
| setConsumed | `setConsumed(bytes32,uint128,address)` | `onBehalf` |
| touchMarket | `touchMarket((...Market...))` | `_marketAddresses(m)` |
| updatePosition | `updatePosition((...Market...),address)` | `_marketAddresses(m), user` |

Market tuple = `(uint256,address,address,(address,uint256,uint256,address)[],uint256,uint256,address,address)`.
Offer tuple = `((...Market...),bool,address,uint256,uint256,uint256,bytes32,address,bytes,address,address,bool,uint128,uint128,uint256)`.

NOTES / GUARDRAILS to encode:
- **`multicall(bytes[])` and `flashLoan(...)` are NOT decoded** — do not create leaves for them (multicall's
  nested calls bypass per-action pinning; flash loans go through the manager's native `midnightFlashLoan`).
- **Callbacks:** `take`/`repay`/`liquidate` carry a `callback` address that Midnight calls mid-action; the
  leaf pins the callback address but callback DATA is NOT sanitizable — only pin callback = `address(0)` (no
  callback) unless you fully trust a specific callback target.
- **`take` needs a maker-signed EIP-712 `Offer`** (the counterparty). For lending/borrowing you must supply a
  real signed offer; there is no way to synthesize one on a fork. Collateral flows
  (`supplyCollateral`/`withdrawCollateral`) are ungated and work solo.

Verified live cbBTC/USDC market to test against (market_id `0x168e31250e0008b50d2255a5ab85e0265acd6c12e4f9a1336134b36a65a47937`, cryptographically verified via `IdLib.toId`):
```
chainId 8453 · midnight 0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A · loanToken 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (USDC)
collateralParams[0] = { token 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf (cbBTC), lltv 860000000000000000, liquidationCursor 300000000000000000, oracle 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9 }
maturity 1785510000 · rcfThreshold 3000000000 · enterGate 0x0 · liquidatorGate 0x0
```
Enumerate all live markets from the REST API: `GET https://api.morpho.org/v0/midnight/markets` (fields:
`chain_id, market_id, loan_token, maturity, rcf_threshold, enter_gate, liquidator_gate, collaterals[]{token,lltv,liquidation_cursor,oracle}`).

---

## Task 4 — Build + test a root

1. Add per-protocol leaf generators (mirror the existing per-protocol functions in the generator; each returns
   a `ManageLeaf`/leaf hash for the (target, selector, packedAddresses) above).
2. Build a tree that includes: the ERC20 approves + the Aave V4 actions on MAIN_SPOKE for USDC(id7)/EURC(id9)/
   USDG(id11), and the Midnight `supplyCollateral`/`withdrawCollateral` on the cbBTC/USDC market. Emit the root.
3. **Fork tests** proving the root authorizes real calls end-to-end:
   - Deploy `FullDecoderAndSanitizer` (constructor: boringVault, uniswapV3NonFungiblePositionManager) on the
     fork; deploy BoringVault + ManagerWithMerkleVerification + RolesAuthority; `setManageRoot(strategist, root)`.
   - Aave V4 (mainnet fork): via `manageVaultWithMerkleVerification`, run
     approve → supply(USDC id7) → setUsingAsCollateral(id7,true) → borrow(EURC id9) → repay → withdraw. Assert
     the vault's EURC/USDG balances and Spoke debt change. Discover reserveIds on-chain (do not hardcode).
   - Midnight (Base fork): supplyCollateral → withdrawCollateral(cbBTC/USDC market). `take` only if you have a
     real signed offer.
   - **Both protocols use transient storage (Cancun).** Run fork tests with `--evm-version cancun` (if the
     repo pins a pre-Cancun EVM the Spoke/core revert `NotActivated`). Gate fork tests on the RPC env var and
     skip when unset so CI stays green.
4. For each generated leaf, assert `leaf == keccak256(abi.encodePacked(decoder, target, false, selector, packedAddresses))` and that a `manage` call with the exact calldata verifies against it (i.e. the decoder's
   returned bytes equal your `packedAddresses`). This catches any pack-order / selector drift.

---

## Task 5 — CowSwap (on-chain limit orders via the module)

CowSwap needs a stateful **`CowSwapOrderModule`** (deployed per vault) — a pure decoder can't gate
`setPreSignature(bytes uid)` (uid is opaque). The vault calls the MODULE; the module enforces order
integrity/receiver/uid-binding and pre-signs. So the leaf **`target` = the deployed CowSwapOrderModule
address** (NOT the GPv2 settlement). GPv2 infra (same on all chains, for the module's constructor, not for
leaves): Settlement `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`, VaultRelayer
`0xC92E8bdf79f0507f65a392b0ab4667716BFE0110`.

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
(`minAmountOut`) is strategist-set (integrity-only, like 1inch minReturn) — pin the tokens, not the price.

---

## Task 6 — Euler v2 (EVK/EVC)

Two target types. EVC (mainnet `0x0C9a3dD6b8F28529d72d7f9cE918D493519EE383`) for collateral/controller mgmt +
`batch`; a specific **eVault** address as `target` for borrow/repay/pullDebt/disableController(). The decoder
FORCES account/receiver/owner == boringVault (reverts otherwise), so those leaves pin nothing extra.

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

`batch` sub-call packing (must match `_sanitizeEulerCall`) — for each `BatchItem{targetContract, onBehalfOfAccount(==vault), value, data}`, after `targetContract` + `value` append the sub-call's packed
addresses by its selector: enable/disableCollateral & enableController → `vault`; disableController(address) →
empty; deposit/mint/borrow/repay/repayWithShares → empty; withdraw/redeem → empty; pullDebt → `from`;
disableController() → empty. Direct (non-batch) eVault ERC-4626 `deposit/mint/withdraw/redeem` are handled by
the **ERC4626** decoder (target = eVault) — generate those with the ERC4626 leaf helpers.

---

## Task 7 — Pendle on-chain limit orders (vault as TAKER)

Pendle Router V4 `target = 0x888888888889758F76e7103c6CbF23ABbF58F946`. These four functions now SANITIZE an
attached on-chain limit order (previously reverted). Aggregator swaps are still forbidden. Base pins are
unchanged; when a `LimitOrderData` is attached you must APPEND the limit-order addresses:

| Function | base packed | + limit-order packed |
|---|---|---|
| swapExactPtForToken | `receiver, market, output.tokenOut` | `_limitOrderAddresses(limit)` |
| swapExactTokenForPt | `receiver, market, input.tokenIn` | `_limitOrderAddresses(limit)` |
| addLiquiditySingleToken | `receiver, market, input.tokenIn` | `_limitOrderAddresses(limit)` |
| removeLiquiditySingleToken | `receiver, market, output.tokenOut` | `_limitOrderAddresses(limit)` |

`_limitOrderAddresses(limit)`: if `limit.limitRouter == address(0)` → empty (plain swap leaf unchanged). Else:
`abi.encodePacked(limit.limitRouter)`, then for EACH fill in `limit.normalFills[]` and THEN each in
`limit.flashFills[]`: `order.token, order.YT, order.maker, order.receiver` (in that order). This is the taker
path — pin the Pendle limit-order router plus every maker order's token/YT/maker/receiver you intend to fill
(obtain the maker orders + LOB router from the Pendle limit-order API / the orders the vault will take).

`LimitOrderData`/`Order`/`FillOrderParams`/`TokenInput`/`TokenOutput`/`ApproxParams` tuple layouts: use
`src/interfaces/DecoderCustomTypes.sol` verbatim (field order is load-bearing for the selector).

---

## Reference
- Decoders (source of truth for pack order + selectors): `src/base/DecodersAndSanitizers/Protocols/AaveV4DecoderAndSanitizer.sol`, `.../MorphoMidnightDecoderAndSanitizer.sol`, `.../CowSwapDecoderAndSanitizer.sol`, `.../EulerDecoderAndSanitizer.sol`, `.../PendleRouterDecoderAndSanitizer.sol` (+ `src/interfaces/DecoderCustomTypes.sol` and `src/interfaces/IGPv2.sol`), combined in `.../nextgen/FullDecoderAndSanitizer.sol`. The CowSwap module: `src/helper/CowSwapOrderModule.sol`.
- Aave V4 address manifest already in the contracts repo: `deployments/aave-v4-ethereum.json`.
- Working fork integration examples to mirror: `test/AaveV4Integration.t.sol`, `test/MorphoMidnightIntegration.t.sol`.
- The FullDecoderAndSanitizer is UNAUDITED and not yet deployed — deploy it (record its address) before any
  production root; use a fresh deploy in tests.
