# Sky Diamond PAU: scoped attack-surface review

Date: 2026-11-26
Review target: `sky-ecosystem/diamond-pau`, Immunefi scope entry pinned to `cbf71b2ac840ca9288eb867d3dd354e08089e1d7`
Status: no new exploitable finding confirmed; one documented architecture risk retained for controlled local-fork validation.

## Scope and target

The current Immunefi scope page names `src/PAUFactory.sol` at the pinned revision as `L2_PAU_Factory`. The program accepts only listed impacts, requires deployed-code relevance for smart-contract reports, and excludes impacts requiring access to privileged addresses without additional privilege modifications.

At the pinned revision, `PAUFactory` exposes permissionless deployment methods. They accept caller-supplied admin addresses and constructor references, then deploy fresh `AccessControls`, `Controller`, `ALMProxy`, `ALMProxyFreezable`, or `RateLimits` instances. This is not by itself a takeover path: the caller controls only the newly created instances. A newly created Controller does not gain `CONTROLLER` privileges on an existing funded ALMProxy or RateLimits contract unless their admins separately grant them. No unauthorized movement of existing funds was established.

## Higher-value lead: sibling-Controller reentrancy

The target revision's own `docs/ARCHITECTURE.md` describes a topology where multiple Controllers can use one ALMProxy. Each facet's `nonReentrant` guard runs in its Controller's delegated storage, while the shared ALMProxy holds no shared guard. The documentation warns that a callback into a sibling Controller can alter shared proxy balances during an in-flight operation, affecting balance-delta, slippage, ownership, or pending-request accounting. It also says loss remains bounded by configured rate limits and slippage, while a per-operation cap could be circumvented by repetition.

This is an explicit project-documented risk at the scope-pinned revision, not a novel finding. The text alone does not prove a permissionless attack, an exploitable deployed topology, an available callback, or financial loss within an accepted impact. The relevant role checks and deployment wiring must be established before assigning severity.

## Controlled validation plan

1. Resolve whether any in-scope deployed ALMProxy is actually shared by sibling Controllers, and obtain the exact deployed Controller/facet/Beacon and RateLimits configurations at a pinned block.
2. On a local fork only, build two sibling Controller instances against one forked ALMProxy, with mock integrations for deterministic callbacks. Do not call external DEXes or manipulate live systems.
3. Exercise a first operation that snapshots a balance and validates slippage, then use a mock callback to re-enter a second Controller and change that ALMProxy balance before the first operation resumes.
4. Record whether the first operation accepts a false balance delta, whether configured rate-limit accounting is bypassed, which role is required on the callback caller, and the maximum loss bounded by the actual on-chain parameters.
5. Treat the result as non-reportable if it requires only a privileged role already assigned as designed, if the live topology is single-Controller, if the relevant functions are not wired, or if no accepted financial impact is demonstrated.

No mainnet or public-testnet transaction was sent. No external protocol was called. No exploit claim or severity is asserted in this note.
