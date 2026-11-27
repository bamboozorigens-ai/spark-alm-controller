# Maple impairment deposit — controlled economic assessment (2026-11-27)

## Executive result

A local Foundry simulation confirms a **known accounting/operational risk** in the PAU `ERC4626Facet` path: a configured allocator deposit can be priced against gross ERC-4626 assets even while Maple impairment lowers the pool's exit-value accounting. Fresh shares can therefore inherit a pro-rata portion of losses already present when they enter.

This is not a demonstrated permissionless exploit, attacker profit, or confirmed live loss. The fixture is a local mock of the impairment split documented by Sky and Maple; it is not Maple bytecode. The Sky PAU operational requirements already disclose this behavior. No production code, live state, or transaction was changed.

## Controlled reproduction

Run in the `diamond-pau` checkout:

```sh
forge test --match-path test/audit/MapleImpairmentDepositSimulation.t.sol -vv
```

Latest result: **3 passed, 0 failed**.

The tests show:

1. A deposit succeeds at the gross exchange rate and meets `minSharesOut`, while the same shares have lower impaired exit value.
2. A zero deposit rate limit reverts before assets move.
3. An external unauthorized account cannot call `ALMProxy.doCall` directly to bypass the facet and its configured controls.

### Reproduced example

The mock begins with gross assets `A = 1,000,000 USDC`, existing unrealized losses `L = 200,000 USDC`, and a new deposit `D = 100,000 USDC`. The deposit receives 100,000 gross-priced shares. At the mock's post-deposit impaired exit accounting, those shares represent about 81,818.181818 USDC: a modeled impairment allocation of **18,181.818182 USDC** to the new deposit. Existing shares receive the corresponding relief, subject to one micro-unit of integer rounding.

## Economic model and bounds

Assumptions: shares are priced at the gross asset value; an existing impairment `L` is excluded from exit assets; the new deposit `D` is the only change; no fees, yield, recovery, slippage, exchange-rate drift, or other deposits/withdrawals occur. Then:

- New cohort ownership fraction: `D / (A + D)`.
- New cohort exit value: `D * (A + D - L) / (A + D)`.
- Impairment allocated to new cohort: `D * L / (A + D)`.

Illustrative scenario with `A = $1,000,000,000` (hypothetical, **not a verified live balance**):

| New deposit D | 1% impairment ($10m) | 5% impairment ($50m) | 10% impairment ($100m) | 20% impairment ($200m) |
|---:|---:|---:|---:|---:|
| $1m | $9,990 | $49,950 | $99,900 | $199,800 |
| $15m | $148,522 | $742,574 | $1,485,149 | $2,970,297 |
| $50m | $476,190 | $2,380,952 | $4,761,905 | $9,523,810 |

Values are rounded to nearest dollar. These numbers describe value transferred through impairment allocation to fresh depositors under the assumptions above. They are **not automatically protocol-wide net losses**: existing holders' modeled claim rises by the same amount, and whether anyone realizes the change depends on redemptions, recoveries, and subsequent pool accounting. The transfer is capped below `D`; for a fixed `A`, it approaches `D` as `L` approaches `A` and `D` is small relative to `A`.

Repeated deposits with total cohort amount `D_total` have the same simplified bound `D_total * L / (A + D_total)`, if `L` and `A` remain fixed. Real deployments change those quantities, and per-transaction rate limits, governance updates, pool rules, and time are material.

## Code and access-control observations

- `src/facets/erc4626/ERC4626Facet.sol` checks the deposit rate limit, approves the underlying, calls the vault, measures shares received, enforces `minSharesOut`, and checks the configured maximum exchange rate. It does not query Maple `unrealizedLosses()` or independently compare impaired exit value.
- `docs/OPERATIONAL_REQUIREMENTS.md` already describes the impairment hazard and says governance should disable/configure Maple deposit limits when losses are posted.
- The local test uses the actual PAU facet and controller/proxy test harness but substitutes a synthetic impaired vault. It validates PAU routing and arithmetic against that model; it does not validate Maple implementation semantics or a live deployment.
- The bypass attempt in the fixture fails: the proxy rejects a direct unauthorized `doCall`, and zero configured deposit capacity blocks the allocator path. A separate privilege-escalation bug would be needed to turn this into an unprivileged theft path; none was demonstrated.

## Live exposure and bounty eligibility

Current production `unrealizedLosses()`, exact PAU deployment, Maple pool address, allocator authorization, rate-limit values, exchange-rate guard, and deposited amount were not verified on-chain. Historical governance proposals and older controller settings are not proof of the current Diamond PAU configuration. Consequently this report assigns **no confirmed live dollar exposure**.

The public Sky Immunefi page currently lists $10,000,000 as the maximum bounty and requires a proof of concept. Its scope accepts impacts such as protocol insolvency and direct theft, while excluding best-practice recommendations, privileged-address attacks absent a privilege change, and attacks requiring malicious governance approval. This controlled result is already disclosed in Sky's repository documentation and does not establish a new in-scope attack path; it should not be represented as an eligible critical bounty submission without additional distinct, attacker-reachable evidence.

## Mitigation

1. At the ERC-4626 integration boundary, reject Maple deposits while `unrealizedLosses() > 0`, or use an explicit maximum-loss policy validated against the pool's exit-value method.
2. Add an independent minimum exit-value / minimum received-value condition, not just a gross exchange-rate ceiling.
3. Keep an operational kill switch for deposits and pause them promptly after impairment. Preserve withdrawal and redemption paths where safe.
4. Add tests using the exact supported Maple implementation or verified fork bytecode, including impairment, rounding, recovery, and rate-limit state transitions.
5. Monitor and publish the live pool's impairment, PAU balance, allocator, and deposit key state before estimating actual exposure.

## Sources

- Sky repository `docs/OPERATIONAL_REQUIREMENTS.md`, Maple deposits section.
- Sky `src/facets/erc4626/ERC4626Facet.sol`.
- Maple impairment policy: https://docs.maple.finance/legal/syrupusdc-and-syrupusdt-defaults-and-impairments
- Sky Immunefi information: https://immunefi.com/bug-bounty/sky/information/
- Sky Immunefi scope: https://immunefi.com/bug-bounty/sky/scope/
- Sky Immunefi resources / asset pointers: https://immunefi.com/bug-bounty/sky/resources/
