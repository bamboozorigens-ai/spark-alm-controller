# Sky Diamond PAU: scoped attack-surface review

Date: 2026-11-26
Review target: `sky-ecosystem/diamond-pau`, Immunefi scope entry pinned to `cbf71b2ac840ca9288eb867d3dd354e08089e1d7`
Status: no new exploitable finding confirmed; one documented architecture risk retained for controlled local-fork validation.

## Scope and target

The current Immunefi scope page names `src/PAUFactory.sol` at the pinned revision as `L2_PAU_Factory`. The program accepts only listed impacts, requires deployed-code relevance for smart-contract reports, and excludes impacts requiring access to privileged addresses without additional privilege modifications.

At the pinned revision, `PAUFactory` exposes permissionless deployment methods. They accept caller-supplied admin addresses and constructor references, then deploy fresh `AccessControls`, `Controller`, `ALMProxy`, `ALMProxyFreezable`, or `RateLimits` instances. This is not by itself a takeover path: the caller controls only the newly created instances. A newly created Controller does not gain `CONTROLLER` privileges on an existing funded ALMProxy or RateLimits contract unless their admins separately grant them. No unauthorized movement of existing funds was established.

## Higher-value lead: sibling-Controller reentrancy

The target revision's own `docs/ARCHITECTURE.md` describes a topology where multiple Controllers can use one ALMProxy. Each facet's `nonReentrant` guard runs in its Controller's delegated storage, while the shared ALMProxy holds no shared guard. The documentation warns that a callback into a sibling Controller can alter shared proxy balances during an in-flight operation, affecting balance-delta, slippage, ownership, or pending-request accounting. It also says loss remains bounded by configured rate limits and slippage, while a per-operation cap could be circumvented by repetition.

This is an explicit project-documented risk at the scope-pinned revision, not a novel finding.

## Read-only deployment check

The official `spark-address-registry` at revision `28a6ef4eccb404313ae2b111f8ef04f4e2018183` lists the Arbitrum legacy `ALM_CONTROLLER`, the PAU `PAU_CONTROLLER`, and one shared `ALM_PROXY`. Read-only RPC calls on 2026-11-26 confirmed:

- `PAU_CONTROLLER.proxy()` returns the listed `ALM_PROXY`.
- The shared Arbitrum ALMProxy reports `hasRole(CONTROLLER, legacy ALM_CONTROLLER) == true` and `hasRole(CONTROLLER, PAU_CONTROLLER) == true`.
- The PAU `AccessControls` reports exactly one `ALLOCATOR_ROLE` member: the deployed `AdministeredAgent` contract.

This confirms the documented shared-Proxy topology exists on Arbitrum. It does not establish an unprivileged callback route. The observed role assignment makes the actual caller/actor boundary the key remaining question: a sibling Controller call from an arbitrary pool or callback will fail unless that caller is authorized by that sibling's `AccessControls`. This is also subject to Immunefi's privileged-address exclusion.

## Controlled validation plan

1. On a local Arbitrum fork pinned to a block, load the exact live PAU and legacy Controller, shared ALMProxy, Beacon, AccessControls, RateLimits, and AdministeredAgent state.
2. Identify a real wired operation with a balance snapshot, slippage check, position-ownership check, or pending-request lifecycle that crosses an external callback.
3. Reproduce only with local mock callback contracts. First verify a random callback caller cannot re-enter the sibling Controller. Then test the documented path while impersonating only the existing local-fork actor/role inside the simulation; record the exact authority required and loss bound.
4. Compare the result to the deployed role and actor configuration. Do not label it permissionless or critical unless a route succeeds without requiring an existing privileged account or governance reconfiguration and causes an accepted in-scope financial impact.
5. Treat it as non-reportable if it requires only a privileged role already assigned as designed, if no exploitable callback exists, or if the measured outcome is only accounting drift without a qualifying loss.

Only read-only RPC queries were performed for the deployment check. No mainnet or public-testnet transaction was sent. No external protocol was called. No exploit claim or severity is asserted in this note.
