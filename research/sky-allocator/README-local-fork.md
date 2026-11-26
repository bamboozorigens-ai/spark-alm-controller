# Local-only allocator probe

The Swapper dust-balance test is a local fork proof against source revision `6e99d87`. It impersonates the configured keeper and does not send transactions to Ethereum.

From a checkout of `sky-ecosystem/dss-allocator` at that revision, copy `SwapperDustBalanceAttack.t.sol` into `test/audit/`, set `ETH_RPC_URL`, and run:

```sh
forge test --match-path 'test/audit/SwapperDustBalanceAttack.t.sol' --match-test 'test_keeperCanUsePrefundedOutputBalanceToDrainBufferSource' -vv
```

The proof demonstrates an accounting path only when keeper permissions are satisfied. It does not prove an unprivileged exploit or that the illustrative funnel is deployed/in scope. Resolve both questions before considering any bounty submission.
