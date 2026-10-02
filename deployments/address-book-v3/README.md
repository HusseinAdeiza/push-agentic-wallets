# `address-book-v3`

The deployed addresses for generation **v3.2**, the chain-derived mandate mode, on Push Chain Donut (`42101`).

| File | What it holds |
|---|---|
| `ADDRESSES.md` | Start here. The two addresses an integrator needs, the full table, and what breaks from v2. |
| `push_agw_contracts.json` | The eight contracts this repository deploys, with live checks and constructor arguments. |
| `external_agw_libraries.json` | Dependencies this repository does **not** deploy, each re-measured live. |

## Which address book is current

**This one.** `address-book-v2` is superseded and retained only as history — every address in it belongs to a deployment whose grant ABI no longer exists. `address-book/` (v1) is older still.

There is no migration. v2 mandates are not readable by these contracts and were not intended to be; this is a fresh deployment, not an upgrade.

## Reading the verification fields

Every contract carries `verified` plus the evidence behind it. All eight are verified this generation — including `urpProxyAdmin`, which **v2 could not verify**: that explorer refused inner-`CREATE` contracts, reporting `is_contract: false` for an address the chain agreed held 926 bytes. It accepts them now.

One thing worth knowing if you check the API yourself. Blockscout's **v2** endpoint (`/api/v2/smart-contracts/<addr>`) omits an `is_verified` key for some entries, so a naive `is_verified` read reports false for contracts that are demonstrably verified. The **v1** endpoint is authoritative and is what tooling uses:

```
curl -s "https://donut.push.network/api?module=contract&action=getsourcecode&address=<addr>"
```

All eight return a `ContractName` and full source there. For the two proxies the explorer resolves the EIP-1967 implementation and serves **its** source at the proxy address — which is the useful behaviour, and the reason `urp` shows `ContractName: URP` rather than `TransparentUpgradeableProxy`.

## The one thing that is genuinely different this generation

**The mandate mode is derived, not declared — and the chain that derives it is enforced.**

Previously the kind was supplied twice, once as a `grantMandate` argument and once as a byte inside the policy data, with nothing comparing the two at grant. A disagreement produced a mandate that looked granted, described itself wrongly in its own event, and died at first use.

Now the owner names a chain, once, in the place they were already naming the terms. The wallet reads it to choose which shape rules apply; URP re-derives the same value from the same bytes to choose which rulebook runs. Neither authors it, so they cannot disagree. And for a universal mandate URP asks the asset itself which chain it came from — the same view the gateway reads on every outbound to decide routing — and refuses the grant if the answer differs.

Because the runtime already pins the asset on every request, that single check at grant makes the declared chain true for the mandate's whole life, with no external call added to the validation path.

## Regenerating this book

It is written by hand from live reads, deliberately — the deploy script emits `deployments/42101.json`, which is gitignored and holds addresses only. Every figure here (`runtimeSize`, the `liveChecks`, the dependency measurements) came from `cast` against the deployed chain at the block recorded in each file, not from the build artifacts. A size copied from a local build proves nothing about what is deployed.
