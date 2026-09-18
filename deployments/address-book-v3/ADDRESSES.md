# Push Agentic Wallet — deployed addresses

**Generation `v3.2` (chain-derived mandate mode)** · Chain ID `42101` · explorer [donut.push.network](https://donut.push.network) · deployed at block `23296330` · commit `67929f2` on `pushAgenticWallet_v3`

## The two addresses you need

| | Address |
|---|---|
| **Factory** — deploy and look up wallets | [`0x2578041963f692f8b51A137A1c7ddc0c84a8226A`](https://donut.push.network/address/0x2578041963f692f8b51A137A1c7ddc0c84a8226A) |
| **URP** — name this as every session's action policy | [`0xeAd99E254ACD64219d057400cdC2A2390bC74372`](https://donut.push.network/address/0xeAd99E254ACD64219d057400cdC2A2390bC74372) |

Both are **proxies**, and both addresses are permanent. Never point an integration at an implementation.

## Everything

| Contract | Address | Size | Verified |
|---|---|---:|:---:|
| `factoryProxy` | `0x2578041963f692f8b51A137A1c7ddc0c84a8226A` | 141 | ✅ |
| `factoryLogic` | `0x517a10C2F2E786CC8271dbD489dFE27dE8F7BE67` | 8,300 | ✅ |
| `walletImplementation` | `0xD7FEF338572f96edBeF89E720f1F0fF1284ec79C` | 12,312 | ✅ |
| `urp` *(proxy)* | `0xeAd99E254ACD64219d057400cdC2A2390bC74372` | 830 | ✅ |
| `urpImplementation` | `0xc95f179D3aDE283E11CF90f3F8E04BFE8534ff4F` | 13,176 | ✅ |
| `urpProxyAdmin` | `0xA634a0cB4F374D89B2cccbdc77300c8Ac3827BF4` | 926 | ✅ |
| `sessionValidator` | `0xF77660838Cebb65BD6357FDe71d19f97CC65E829` | 1,720 | ✅ |
| `sessionEngine` | `0x046B2874Fc9F920ad53A317b3cf9d3d1974466f3` | 22,581 | ✅ |

**All eight verified**, including the `urpProxyAdmin` that v2 could not verify.

## What changed from v2, and what it breaks

**Nobody declares a mandate's kind any more.** The owner names a **chain**; the wallet and URP each derive the kind from it, independently, from the same bytes.

| | v2 | v3.2 |
|---|---|---|
| Grant call | `grantMandate(session, MandateType)` | **`grantMandate(session)`** |
| Policy `initData` | `abi.encode(uint8 mode, bytes body)` | **`abi.encode(string chain, bytes body)`** |
| Body type | `Config` / `NativeConfig` | **`UniversalTerms` / `NativeTerms`** |
| Who decides the kind | the caller, twice, unchecked | **nobody — derived twice, identically** |
| Chain | recorded, never checked | **checked against the asset at grant** |

**Every v2 integration that encodes a grant will break, loudly.** The selector changed, so a v2 payload misses the function rather than failing a check. A v2 `initData` envelope decodes to an empty chain and reverts with a named `EmptyChain()`.

**v2 mandates do not carry over.** Every address is new.

## The chain string

For a **universal** mandate it must be byte-exact what the asset reports:

```
cast call <PRC20> 'SOURCE_CHAIN_NAMESPACE()(string)' --rpc-url <donut>
# USDC.eth -> "eip155:11155111"
```

URP asks the asset the same question at grant and refuses on a mismatch (`ChainMismatch`) or an asset that cannot answer (`InvalidAsset`).

For a **native** mandate it is this chain's own identifier, `"eip155:42101"` — and you can ask the contract rather than hard-coding it:

```
cast call 0xeAd99E254ACD64219d057400cdC2A2390bC74372 'pushChainHash()(bytes32)' --rpc-url <donut>
# -> 0x3d6bc1f1d3fb03065860265a8e93840b586e57075d956cd41b4319d040be87f9 == keccak256("eip155:42101")
```

⚠️ **Near misses are not corrected.** `"EIP155:42101"` hashes to something else, derives the *other* kind, and is refused against the action targets — with a `MandateTypeMismatch` that names the target, not the string. The hash comparison is the whole rule; the contracts deliberately do not parse or normalise.

⚠️ **Not the UEAFactory formula.** `keccak256(abi.encode("eip155","42101"))` is a different value for the same chain and belongs to UEA address prediction. Conflating the two is how the old `destChainHash` field accumulated four conventions.

## Proof it works

A real wallet, deployed through the real factory: [`0x1A02CC8Ed94a160D490D6851401F6F3879c69991`](https://donut.push.network/address/0x1A02CC8Ed94a160D490D6851401F6F3879c69991) (tx [`0x1f98c54b…`](https://donut.push.network/tx/0x1f98c54bb1ac4a51f094251d4eed295820dcbfed8b3336ef4f321b63f7727ad3), block 23,296,566).

`isWallet` ✅ · `ownerOf` ✅ · `clone.urp()` → the proxy ✅ · `accountId()` → `push.agentwallet.1.0.0` ✅

## Admin

Both authorities are the deployer EOA `0xa89523351BE1e2De64937AA9AF61Ae06eAd199C7`, with a 48-hour factory admin delay.

They are **different powers** and for production belong in **different** multisigs: the factory's `DEFAULT_ADMIN_ROLE` can strand counterfactually funded addresses; the URP ProxyAdmin owner can rewrite every gate in the security boundary.
