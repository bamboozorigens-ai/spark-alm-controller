# Sky allocator Swapper dust-balance probe

Date: 2026-11-26  
Repository revision: `sky-ecosystem/dss-allocator` `6e99d87`  
Status: local proof of a role-gated loss path in an illustrative funnel; not a bounty finding at this time.

## Hypothesis

`Swapper.swap` checks `GemLike(dst).balanceOf(address(this)) >= minOut` after its callback, rather than checking the balance increase attributable to that swap. The same function then transfers the entire destination-token balance to the buffer. If destination-token dust is already present and a caller can supply a malicious callee, that callee can retain the source tokens while the old destination balance satisfies `minOut`.

## Local fork proof

Test: [`test/audit/SwapperDustBalanceAttack.t.sol`](../test/audit/SwapperDustBalanceAttack.t.sol)

Setup mirrors the repository's StableSwapper fixture on a local Ethereum fork. The test seeds 990 DAI at the local Swapper, calls the StableSwapper as its configured keeper, and provides a callee that forwards 1,000 USDC to a local attacker address without producing swap output. The old DAI balance satisfies the configured 990 DAI minimum and is forwarded to the buffer.

Result: `1 passed, 0 failed`. The local attacker address receives 1,000 USDC after supplying 990 DAI. At exact $1 parity, the modeled gross difference is $10 per call before execution costs. No real chain state or external funds were changed.

## Reachability and bounty status

This test deliberately impersonates the configured keeper. `StableSwapper.swap` has a `buds` keeper gate, and `Swapper.swap` checks `AllocatorRoles.canCall`; the demonstrated path is therefore not shown to be reachable by an ordinary unprivileged account. The test proves the accounting condition when those gates are satisfied, not a bypass of them.

The repository README also states that the included funnels and automation contracts are illustrative and obsolete, and that specialized funnels are expected in practice. The current Immunefi asset list must be checked for the exact deployed Swapper/StableSwapper addresses and source revision before this code can be treated as an in-scope target. I have not established that these funnel contracts are deployed or listed as in scope.

Accordingly, do not submit this as a critical or permissionless exploit. It is a lead for verifying actual deployed code and keeper reachability. If an in-scope deployment exists and an ordinary caller can supply the malicious callee through a public keeper entry point without privileged access, then it merits a fresh fork test with the exact deployment and its configured thresholds.

## Relevant code path

1. `StableSwapper.swap` accepts `callee` and `data` from the keeper call and invokes `Swapper.swap`.
2. `Swapper.swap` transfers `amt` source tokens from the buffer to `callee`, then invokes `callee.swapCallback`.
3. It checks the absolute destination balance against `minOut`, then transfers the entire destination balance back to the buffer.

## Required next checks

- Resolve the exact asset entry and deployed addresses from the current Immunefi scope and Chainlog.
- Read the deployed `AllocatorRoles` action/user-role mappings and the actual `StableSwapper.buds` mapping at a pinned block.
- Establish whether any public keeper endpoint forwards attacker-controlled `callee`, `data`, or `minOut`.
- Re-run against the deployed bytecode and actual buffer tokens only after all three reachability checks pass.
