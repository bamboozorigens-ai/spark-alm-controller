# Controlled attack-path follow-up — Sky PAU (2026-11-27)

## Outcome

Across seven controlled Foundry suites, **29 tests passed**. One positive economic-loss scenario was reproduced: a configured, allocator-authorized peer can cause the local receiving PAU proxy to overpay when its incoming token charges a transfer fee. The peer's fee recipient captures the difference in the synthetic-token scenario.

No permissionless external attacker path to profit or drain Sky/customer funds was established. All fork state changes were local Forge state; no transaction was broadcast. Tests that impersonate admins, allocators, or protocol addresses do so only with `vm.prank` inside the local fork.

## Test results

| Surface | Result | What the test establishes |
|---|---:|---|
| Maple impairment deposit | 3 passed | New deposit can inherit impairment in a synthetic pool model; zero limit blocks; direct unauthorized proxy call fails. Known operational risk, not attacker profit. |
| SwapAsset counterparty | 4 passed | Synthetic fee-on-transfer asset yields 10% local shortfall for configured allocator peer; unknown peer cannot initiate, complete, or set/consume its own limits. |
| weETH public claim | 1 passed | Outsider can call a public claim for a request NFT owned by the module, but receives zero ETH; a later legitimate request sweeps the stranded ETH to the proxy. |
| Arbitrum topology | 2 passed | Two controllers share one ALM proxy; fork read shows a single allocator-role member, the AdministeredAgent. This is topology evidence, not proof of a bypass. |
| Emergency spells | 3 passed | Outsider scheduling attempts for three emergency spells revert as unauthorized. |
| Sibling-controller reentrancy | 3 passed | Same-controller reentry is blocked; cross-controller callback succeeds only when callback has allocator role on the sibling controller; unprivileged callback fails. |
| Uniswap V4 authorization | 13 passed | Outsider relay cannot reach allocator actions, move proxy assets, invoke proxy delegate/value calls, self-promote, or change facet/role configuration; direct reentry checks also reverted. |

The SwapAsset suite used a local mainnet fork at block `26,493,050`; Uniswap V4 used the public endpoint's latest fork block `26,503,186`; the weETH and emergency-spell suites used the public endpoint's current fork state during execution; the Arbitrum suite was read-only. The source checkout's older fork test base needed temporary compatibility edits for the SwapAsset suite and was restored after the run. The controller/facet under test was deployed locally; the fork supplied external chain dependencies. This is not verification that the live deployment has the tested peer/token/limits.

## Deployment status of SwapAsset

Sky's November 23 Atlas edit describes adding Swap Asset Facet functions to Diamond PAU documentation **ahead of approval on the Beacon in a future Executive Vote**, and adding the Spark Diamond PAU to the Ethereum PAS **to be configured in a future Executive Vote**. This public governance trail suggests the tested Spark Diamond PAU route was still preparatory in that proposal; it does not establish the state of every PAU or replace a current on-chain read.

## Only positive loss scenario

In the fee-token test, the local victim proxy paid 100 USDS and received 90 tokens; the synthetic token credited the other 10 tokens to the configured peer's fee recipient. At the test's assumed 1:1 value, the shortfall and peer-side capture were 10 USDS-equivalent.

The scenario requires all of the following:

- A counterparty proxy and controller already configured for this swap tuple.
- An allocator-authorized caller on that peer.
- Administrator-configured rate-limit capacity on both sides.
- A synthetic transfer-fee token accepted as an incoming asset.

The token conflicts with Sky's documented standard-token integration requirement. The current test does not show an outsider bypass, current live token acceptance, or actual funds exposed. It is therefore a defensive code-path finding / onboarding hazard, not a confirmed bounty-eligible critical exploit. Sky's bounty scope excludes certain privileged-address and malicious-governance-dependent impacts.

## Code-level mitigation

`SwapAssetFacet.completeSwap` should measure the receiving proxy's input-token balance before and after `transferFrom` and revert unless the actual balance increase equals the expected amount. Keep the peer/asset-pair allowlist and limits narrow, and enforce token behavior requirements during onboarding. This protects the receiving side even if a fee token is mistakenly configured.

## Remaining evidence needed for a live exposure estimate

A state read at a specified current block must enumerate active PAU controllers, their shared proxies, configured swap completion keys, corresponding peers/assets, rate-limit capacities, and actual balances. Without those facts, scaling the synthetic 10% result into a Sky/customer exposure number would be speculative.

## Related reports and test files

- Maple economics: `research/sky-pau/maple_impaired_deposit_simulation_2026-11-27.md`
- Fee-token scenario: `research/sky-pau/swap_asset_fee_token_peer_loss_2026-11-27.md`
- Test sources: `research/sky-pau/MapleImpairmentDepositSimulation.t.sol`, `research/sky-pau/SwapAssetCompleteAuthorizationFork.t.sol`
- Other local tests: `test/audit/WEETH_PublicClaimAttack.t.sol`, `test/audit/ArbitrumTopologyFork.t.sol`, `test/audit/EmergencySpellPermissionlessScheduleFork.t.sol`, and `test/audit/SiblingControllerReentrancy.t.sol`
