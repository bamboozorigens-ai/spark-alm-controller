# SwapAsset fee-token peer loss — controlled fork result (2026-11-27)

## Result

A local mainnet-fork suite reproduced a **conditional loss-transfer scenario** in the `SwapAssetFacet` completion path. If a PAU accepts a configured peer whose incoming asset charges a transfer fee, `completeSwap` can pay the full outgoing amount while receiving less than the nominal incoming amount. The test's synthetic 10% fee token caused a 10 USDS-equivalent shortfall on a 100 USDS swap; its configured peer's fee recipient received the missing 10 tokens.

This is not a permissionless attack. The successful test impersonates an already-authorized allocator at a configured peer, sets test rate-limit entries with the local test admin, and supplies a synthetic fee-on-transfer token. It does not show that any untrusted external caller can drain a live Sky PAU. Sky's operational requirements specify standard ERC-20 tokens, and the bounty scope excludes privileged-address attacks absent a privilege change and attacks requiring malicious governance approval.

## Test execution

File: `test/audit/SwapAssetCompleteAuthorizationFork.t.sol`

Command:

```sh
forge test --match-path test/audit/SwapAssetCompleteAuthorizationFork.t.sol -vv
```

Result: **4 passed, 0 failed** on local fork block `26,493,050`.

The checkout's legacy `ForkTestBase.t.sol` does not compile with the installed Foundry/forge-std API without temporary test-harness compatibility edits. For this run only, the fork selection and duplicate `DssInstance` type imports were adapted in the test base, then the original file was restored. No production source or live state was modified. The selected public RPC can serve this historical block; other endpoints tried were unavailable or lacked the required historical state.

The fork provides external Ethereum state for dependencies; the PAU controllers and facets exercised by `SwapAsset_TestBase` are deployed and configured by the test itself. Thus, this confirms behavior of the checked-out code under a fork-backed harness, not that a currently deployed Sky controller has this peer, token, or rate-limit configuration.

The suite results:

- `test_configuredPeerCanExploitFeeOnTransferInputAndOverdrawLocalProxy`: passed. The local victim controller pays 100 USDS and receives 90 fee tokens; the peer's fee recipient receives 10 tokens.
- `test_nonAllocatorCannotInitiateCounterpartySwap`: passed.
- `test_unknownCounterpartyCannotCompleteSwapOrChangeProxyBalances`: passed.
- `test_unknownCounterpartyCannotInstallOrConsumeItsOwnRateLimit`: passed.

## Relevant code path

`SwapAssetFacet.initiateSwap` checks `ALLOCATOR_ROLE`, verifies that the counterparty controller is recognized by its own proxy, consumes a tuple-specific initiation key, performs the completion call, and measures the initiating proxy's outgoing/incoming balance deltas. The counterparty's `completeSwap` derives the rate-limit key from `msg.sender`, consumes that key, computes the nominal 1:1 amount, then transfers nominal input and output amounts. It does not measure the actual balance delta of the incoming token.

This asymmetry explains the mock result: the initiating peer verifies that it paid 100 fee tokens and received 100 USDS; the target's completion method treats `transferFrom(100)` as 100 received even though the token credits only 90 to the target proxy. A fee-aware balance-delta check would reject that completion and revert the whole atomic route.

## Economic interpretation

For the test's par-valued synthetic token:

| Leg | Nominal | Actual credited/debited |
|---|---:|---:|
| Victim proxy outgoing USDS | 100 | -100 |
| Victim proxy incoming fee token | 100 | +90 |
| Peer fee recipient | 0 | +10 |

The modeled shortfall is 10 USDS-equivalent, while the peer's fee recipient captures 10 fee tokens. This is not an estimate of live exposure: it assumes a 1:1 valuation, a fee token accepted by both sides, a configured peer, available rate-limit capacity, and allocator execution. Larger amounts scale linearly in this simplified mock, but live rate limits and actual token acceptance bound any real route.

## Access boundary and bounty assessment

The three negative tests show that an unknown relay cannot initiate the operation, use an unconfigured completion key, or configure/consume its own limits. The positive path requires a configured counterparty and an authorized allocator. The fee token is synthetic and contradicts the documented standard-token onboarding requirement. Accordingly, this is useful as a defensive integration test and configuration warning, but the current evidence does **not** establish an in-scope permissionless critical vulnerability or a bounty-eligible report.

No production token or current live peer configuration was tested. A live exposure estimate would require verifying each currently configured counterparty, asset pair, rate-limit key, token transfer semantics, and funded proxy balance at the relevant block.

## Remediation

1. In `completeSwap`, measure the target proxy's input-token balance before and after `transferFrom` and require the actual delta to equal the expected amount.
2. Enforce the standard-token policy during onboarding with explicit checks or a token allowlist, not only documentation.
3. Keep completion keys restricted to intentionally approved peer proxy/asset pairs and size their limits to the verified counterparty exposure.
4. Add regression tests for fee-on-transfer, rebasing, false-return, and callback tokens; assert atomic rollback and unchanged proxy balances on mismatch.

## Sources

- Sky `src/facets/swap-asset/SwapAssetFacet.sol`.
- Sky `docs/OPERATIONAL_REQUIREMENTS.md`, Token Requirements and Swap Asset Onboarding.
- Sky Immunefi scope: https://immunefi.com/bug-bounty/sky/scope/
- Controlled test: `test/audit/SwapAssetCompleteAuthorizationFork.t.sol`.
