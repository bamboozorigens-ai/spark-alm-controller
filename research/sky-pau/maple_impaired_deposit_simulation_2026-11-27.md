# Maple impairment deposit — controlled confirmation (2026-11-27)

## Result

A local Foundry simulation confirms the documented accounting mismatch in the PAU `ERC4626Facet` integration: the facet can accept an ERC-4626 deposit at the vault's gross share price while an impaired vault assigns a lower exit value to the new shares.

This is a **controlled simulation, not a live Maple exploit or bounty finding**. The fixture is an explicit mock implementing the impairment behavior described by Sky and Maple documentation; no production state was changed and no transaction was broadcast.

## Reproduction

Run from the `diamond-pau` checkout:

```sh
forge test --match-path test/audit/MapleImpairmentDepositSimulation.t.sol -vv
```

Result: **1 passed, 0 failed**.

The scenario seeds a mock pool with 1,000,000 USDC-equivalent gross assets, 1,000,000 shares, and 200,000 USDC-equivalent unrealized losses. PAU deposits 100,000 USDC-equivalent. The deposit succeeds at a 1:1 gross exchange rate and satisfies `minSharesOut`. Under the mock's impaired exit-value calculation, the new shares are worth approximately 81,818.181818 USDC-equivalent, a modeled difference of 18,181.818182 USDC-equivalent.

The numerical result depends on the pool's impairment ratio and other assets/shares at the time of deposit. It is not a statement about current live Maple impairment or current Sky balances.

## Code path

- `ERC4626Facet.deposit(token, amount, minSharesOut)` consumes a configured deposit rate limit, approves the underlying asset, calls `deposit`, measures returned shares from the proxy share-balance delta, checks `minSharesOut`, and checks an admin-configured maximum exchange rate using `amount / shares`.
- It does not query Maple's `unrealizedLosses()` or compare gross-priced shares to Maple's impaired exit value.
- The repo's `docs/OPERATIONAL_REQUIREMENTS.md` already describes this risk and says governance should stop/configure Maple deposit limits when losses are posted.
- Maple's public impairment documentation explains that new lenders depositing during impairment have their lending balance affected by the impairment: https://docs.maple.finance/legal/syrupusdc-and-syrupusdt-defaults-and-impairments

## Security and bounty assessment

The interaction requires the authorized `ALLOCATOR_ROLE` and configured rate-limit capacity. This does not expose a public caller path. Sky's published Immunefi exclusions include impacts requiring access to privileged addresses without privilege changes; the source repository also already documents the Maple impairment risk. Treat this as a known operational/configuration hazard unless additional evidence establishes a distinct, in-scope, attacker-reachable bug in deployed code.

No live pool's current `unrealizedLosses()`, PAU deposit rate limit, max-exchange-rate, allocator behavior, or active pool configuration was verified in this simulation. Those must be read from the exact live deployment before estimating actual exposure.

## Mitigation direction

Before any Maple deposit, reject when `unrealizedLosses() > 0` (or enforce a governance-configured maximum loss threshold), and independently verify the expected exit value. Operationally, disable the corresponding deposit rate-limit key immediately when an impairment is observed. Keep withdrawals/redemption routes available.

## Sources

- Sky PAU source documentation, `docs/OPERATIONAL_REQUIREMENTS.md` (Maple deposits).
- Maple impairment policy: https://docs.maple.finance/legal/syrupusdc-and-syrupusdt-defaults-and-impairments
- Sky Immunefi information and scope: https://immunefi.com/bug-bounty/sky/information/ and https://immunefi.com/bug-bounty/sky/scope/
