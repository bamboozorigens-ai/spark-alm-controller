# Sky Lockstake review — multi-urn liquidation probe

Date: 2026-11-26  
Repository: `sky-ecosystem/lockstake`  
Reviewed revision: `e389dc1`  
Status: exploratory local-fork probes; no reportable vulnerability confirmed.

## Scope and limits

This probe examines whether liquidating one Lockstake urn can corrupt the vote delegation or farm stake of a second urn when both urns use the same delegate and farm. It runs only in a local Foundry fork. It does not send transactions to Ethereum or alter the upstream GitHub repository.

The fixture deploys the repository's Lockstake contracts and mock SKY, USDS, vote delegate, farm and oracle contracts locally, while forking the live Vat, Spotter, Dog and Jug configuration. Therefore this is useful for testing the integration/callback accounting path, but it is not a reproduction against the exact deployed Lockstake engine address and production tokens.

## Test scenario

The local test opens two urns for one owner, locks 100 SKY in each, assigns both to the same vote delegate and farm, then borrows against the second urn. It drops the local oracle price, updates the forked Spotter, and calls `Dog.bark` for only the second urn. It then funds a synthetic buyer with Vat DAI and completes the auction through `Clipper.take`. Assertions check that the first urn keeps its 100 SKY delegation and farm balance while the liquidated urn is detached, auctioned and has its auction counter cleared.

Test: [`test/audit/LockstakeMultiUrnFork.t.sol`](../test/audit/LockstakeMultiUrnFork.t.sol)

## Results

- The targeted multi-urn liquidation and auction completion test passed: `1 passed, 0 failed`.
- The full test contract passed after the auction-lifecycle extension: `8 passed, 0 failed` (seven inherited invariants with 100 fuzz calls each, plus the multi-urn auction test).
- The official capped OSM wrapper suite was also run against current fork state: nine behavior/auth tests passed; `testUpdateOsm` failed its first precondition because it expects `LOCKSTAKE_ORACLE` not to exist. The current chainlog already has that key populated, so this is a stale fixture assumption, not a failure in the wrapper behavior. No state was changed outside the fork.
- Separately, the upstream invariant suite had previously passed 7/7 at 600 calls per invariant.
- No cross-urn loss or accounting inconsistency was observed in this path.

The result is evidence against this specific hypothesis under the fixture assumptions. It is not proof that all Lockstake paths are safe.

## Source and prior-art checks

- `LockstakeEngine.onKick` computes the liquidated urn's pre-confiscation collateral and clears only that urn's delegate and farm assignment before burning the confiscated lssky.
- The README documents `open(index)` as protection against multicall creating an unintended urn.
- The current repository history includes prior changes for the migrator's old-ilk debt-ceiling check and a `fee < WAD` validation; these areas need to be treated as known, already-addressed history rather than fresh findings without new evidence.
- The checked-in Cantina update report classifies migration potentially moving a user closer to liquidation as informational; the README documents that governance parameters and the SKY oracle can differ from MKR. Re-discovering that behavior would not be a novel bounty finding.
- The latest checked-in ChainSecurity report records zero critical/high/medium findings. It lists low-severity initialization validation gaps for `rate` and `urnImplementation` as acknowledged, plus a corrected temporary debt-line issue. These are prior art, not new discoveries.
- The new capped OSM wrapper explicitly returns `min(OSM price, cap)`. Its README warns that lowering the cap can lower liquidation/reset prices and recommends caution when liquidations are enabled. This is an intended governance-controlled behavior documented as a risk, not a permissionless bypass in the code reviewed.
- A current, read-only Chainlog lookup confirmed `LOCKSTAKE_ENGINE` is populated, and the wrapper suite's revert precondition confirms `LOCKSTAKE_ORACLE` is already populated on the forked latest state. The repository's wrapper deployment/update tests assume the pre-migration state, so that one integration test cannot be reused unchanged at head.
- GitHub code search found no direct multi-urn liquidation finding in this repository. The search was limited and does not establish that no private or unpublished report exists.

## Next experiments

1. Extend the local scenario through auction `take` and `redo`/`yank`/`onRemove`, asserting the surviving urn's balances and the liquidated urn's final debt, collateral and auction counter.
2. Repeat with distinct delegates, distinct farms, a shared farm with reward claims, partial liquidation, full liquidation, and multiple sequential auctions.
3. Review deployed engine/clipper bytecode and chainlog addresses against the exact source revision before treating any source-level result as production-relevant.
4. Continue to the debt migration path only after pinning the deployed engine, migrator and flash module versions; exercise zero-debt, accrued-debt, full debt-ceiling, liquidation-boundary, and migration-to-existing-urn cases using local state changes only.

The upstream `test/LockstakeMigrator.t.sol` suite could not run in this environment: it pins block `22517470`, while the available public RPC rejects required historical account reads with HTTP 403 (`Archive requests require a personal token`). This is a test-environment limitation, not a contract failure. The local fork harness also depends on a public RPC for latest-state reads.

## Submission threshold

There is no security finding to submit from this probe. A bounty submission should wait for a reproducible, in-scope defect in a deployed version, with a PoC showing measurable unauthorized loss or another program-listed impact and separating victim loss from attacker gain and execution cost. Do not describe hypothetical network-wide extraction as an achieved or demonstrated impact.
