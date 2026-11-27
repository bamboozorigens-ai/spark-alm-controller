# Sky PAU — transfer and settlement route review (2026-11-27)

## Summary

This continuation reviewed CCTP, LayerZero, Centrifuge, OTC, PSM/PSM3, ERC-4626, ERC-7540, and NFAT transfer/settlement paths in the local `sky-diamond-pau` checkout.

No new public, permissionless route to move proxy assets or bypass role/rate-limit checks was established. The review found one **configuration-dependent OTC exposure property** that merits operational confirmation, but it is not demonstrated here as a bounty-eligible vulnerability or a public exploit.

## OTC recharge / cumulative exposure

`OTCFacet.send` requires `ALLOCATOR_ROLE`, an onboarded exchange/buffer, an available per-(asset, exchange) send rate limit, and `getIsSwapReady(exchange)`. `getIsSwapReady` permits a new send after:

```
normalizedClaimed + elapsedSeconds * normalizedRate
    >= normalizedSent * maxSlippage / 1e18
```

A sufficiently high configured recharge rate can therefore make the next send ready after time has elapsed even when the prior exchange has not returned all—or any—of the prior transfer. A successful next send overwrites the per-exchange `normalizedSent`, `sentTimestamp`, and `normalizedClaimed` state. If the external send rate limit also recharges, cumulative outstanding funds can exceed one individual send-limit cap over repeated cycles.

This is a **trusted-counterparty / allocator / configuration risk**, not an unauthorized entry point: an ordinary external account cannot invoke `send`, and the route remains gated by configured rate-limit keys. Whether production settings make the cumulative exposure material must be checked against the live controller configuration and operational runbook. The design documentation describes recharge as intentional recovery from under-returns, so this note does not classify the behavior as a source-code exploit without evidence that deployed parameters violate the intended exposure model.

## Other routes reviewed

- **LayerZero:** `transfer` is allocator-only, requires a configured recipient and derived rate limit. The source itself warns that the integration was deployed without full integration tests and says to keep its rate limit at zero until the dependencies are live and tested. No bypass was found in the reviewed path.
- **CCTP:** allocator-only; checks aggregate and per-destination rate limits, configured recipient/domain, and fee-cap bounds before burning USDC.
- **Centrifuge:** cross-chain share transfer is allocator-only and consumes a per-token / destination / spoke rate limit. The code trusts the spoke to transfer the requested amount; this is a dependency/configuration assumption, not shown to be attacker-controlled from a public call.
- **ERC-4626:** deposit and redemption paths measure actual share/asset balance deltas and enforce slippage/maximum-share bounds; rate limits use measured deltas.
- **ERC-7540:** request and claim functions are allocator-only. Request paths consume rate limits; claim paths require configured claim keys and settle pending positions.
- **PSM / PSM3:** allocator-only. PSM uses fixed known assets; PSM3 withdrawal measures actual received assets. PSM3 deposit uses nominal amount, so fee-on-transfer behavior would need to be considered if such a token were ever approved/configured.
- **NFAT Prime:** subscribe/withdraw/collect paths measure proxy balance changes when consuming rate limits.
- **OTC buffer:** the existing operational docs require unlimited buffer allowance for the proxy; finite allowance can let a small donation push the balance over the allowance and make a claim revert. This is documented as an operational deployment requirement, not a newly discovered issue.

## Validation

- Local integration suite: `forge test --match-path test/integration/facets/OTCFacet.t.sol -vv` — **16 passed, 0 failed**. These tests cover admin authorization, reentrancy, configuration validation, and rate-limit-key derivation; they are not an economic-loss proof.
- Attempted fork regressions for `test_isOTCSwapReady` and `test_e2e_swapUSDSToUSDT`. Compilation stopped before execution because this checkout's `ForkTestBase.t.sol` calls `getChain("mainnet").createSelectFork(...)`, which is unsupported by the installed Foundry/forge-std version. No source or test files were changed to work around that incompatibility.
- Existing mainnet-fork tests already exercise partial OTC return followed by time recharge. They do not demonstrate a permissionless drain.

## Next verification required

1. Read current live Sky controller settings for each active OTC exchange: `maxSlippage`, `normalizedRate`, send-rate `maxAmount`/slope, claim-rate limits, and the authorized allocator automation cadence.
2. Establish whether the intended risk budget is one-send exposure or rolling cumulative exposure. If it is one-send exposure, add an absolute outstanding cap or preserve outstanding amount across recharge cycles rather than resetting it on a new send.
3. Confirm whether LayerZero rate-limit keys remain disabled in every active deployment.
4. Confirm the exact deployed facet bytecode/source before treating any source-level lead as bounty eligible.

No transactions were broadcast; all review activity was read-only or local test execution.
