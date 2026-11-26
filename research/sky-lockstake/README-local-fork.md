# Local fork reproduction

These notes and tests are for local bug-bounty research only. The test harness was developed against `sky-ecosystem/lockstake` revision `e389dc1`; it does not send transactions to Ethereum.

To reproduce, check out that repository and its submodules, copy `LockstakeMultiUrnFork.t.sol` into `test/audit/`, set `ETH_RPC_URL` to an Ethereum RPC endpoint, and run:

```sh
forge test --match-path 'test/audit/LockstakeMultiUrnFork.t.sol' -vv
```

The fixture locally deploys Lockstake, token and oracle mocks while forking the live Vat/Spotter/Dog/Jug configuration at the selected head block. It is an integration probe, not a production deployment exploit. Pin the fork block and verify the deployed contract bytecode before using any result as production evidence.

The fixed historical-block migrator suite could not run with the available RPC because it denied archive reads with HTTP 403. Do not interpret that infrastructure error as a test result about contract behavior.
