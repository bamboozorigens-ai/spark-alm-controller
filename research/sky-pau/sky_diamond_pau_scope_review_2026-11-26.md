# Sky Diamond PAU: scoped attack-surface review

Date: 2026-11-26
Review target: `sky-ecosystem/diamond-pau`, Immunefi scope entry pinned to `cbf71b2ac840ca9288eb867d3dd354e08089e1d7`
Status: no new exploitable finding confirmed; the documented sibling-Controller reentrancy condition is reproduced locally, but only with an explicitly privileged callback in the unit simulation.

## Scope and target

The current Immunefi scope page names `src/PAUFactory.sol` at the pinned revision as `L2_PAU_Factory`. The program accepts only listed impacts, requires deployed-code relevance for smart-contract reports, and excludes impacts requiring access to privileged addresses without additional privilege modifications.

At the pinned revision, `PAUFactory` exposes permissionless deployment methods. They accept caller-supplied admin addresses and constructor references, then deploy fresh `AccessControls`, `Controller`, `ALMProxy`, `ALMProxyFreezable`, or `RateLimits` instances. This is not by itself a takeover path: the caller controls only the newly created instances. A newly created Controller does not gain `CONTROLLER` privileges on an existing funded ALMProxy or RateLimits contract unless their admins separately grant them. No unauthorized movement of existing funds was established.

## Higher-value lead: sibling-Controller reentrancy

The target revision's own `docs/ARCHITECTURE.md` describes a topology where multiple Controllers can use one ALMProxy. Each facet's `nonReentrant` guard runs in its Controller's delegated storage, while the shared ALMProxy holds no shared guard. The documentation warns that a callback into a sibling Controller can alter shared proxy balances during an in-flight operation, affecting balance-delta, slippage, ownership, or pending-request accounting. It also says loss remains bounded by configured rate limits and slippage, while a per-operation cap could be circumvented by repetition.

This is an explicit project-documented risk at the scope-pinned revision, not a novel finding.

## Read-only deployment check

The official `spark-address-registry` at revision `28a6ef4eccb404313ae2b111f8ef04f4e2018183` lists the Arbitrum legacy `ALM_CONTROLLER`, the PAU `PAU_CONTROLLER`, and one shared `ALM_PROXY`. Read-only RPC calls on 2026-11-26 and a local Arbitrum fork at block 527831451 confirmed:

- `PAU_CONTROLLER.proxy()` returns the listed `ALM_PROXY`.
- The shared Arbitrum ALMProxy reports `hasRole(CONTROLLER, legacy ALM_CONTROLLER) == true` and `hasRole(CONTROLLER, PAU_CONTROLLER) == true`.
- The PAU `AccessControls` reports exactly one `ALLOCATOR_ROLE` member: the deployed `AdministeredAgent` contract, which has two configured actors.

The fork test made only view calls and sent no state-changing transactions.

## Controlled local test results

A unit harness using the project's actual `Controller`, `Facet`, and `AccessControls` code deployed two local Controllers pointed at one mock custody address:

- Cross-Controller reentry succeeded when the callback contract was explicitly granted `ALLOCATOR_ROLE` in the sibling AccessControls.
- The same callback failed when it had no allocator role.
- Reentry into the same Controller was rejected by its `nonReentrant` guard.

Result: 3/3 local unit tests passed. This proves the guard is per Controller and the sibling role gate remains effective. It does not reproduce a deployed callback route, a token or asset loss, a bypass of the deployed AdministeredAgent actor controls, or a qualifying economic impact. The test-only role grant is a privilege change and cannot support a bounty claim by itself.

## Next validation gate

A bounty-grade claim would still require a local fork reproduction using an actual wired deployed operation and a callback that is reachable without changing the deployed roles or relying on a privileged address. The test must measure an accepted in-scope loss against the live rate limits and configuration. If the only path requires an already-authorized actor, or merely demonstrates accounting drift without qualifying loss, close the lead as non-reportable.

Only read-only RPC queries were performed against deployed state. All state-changing simulations ran in local unit-test state. No mainnet or public-testnet transaction was sent. No external protocol was called. No exploit claim or severity is asserted in this note.
