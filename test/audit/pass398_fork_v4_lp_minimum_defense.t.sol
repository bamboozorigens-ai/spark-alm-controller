// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 398: check whether per-token minima on a hypothetical real-NFT
// withdrawal prevent unfavorable composition shifts after a public price move.
// Entire sequence is in local Foundry fork, no live transactions.
import "./pass397_fork_v4_lp_mev_portfolio.t.sol";

interface IRate398 {
    function getCurrentRateLimit(bytes32 key) external view returns (uint256);
}
contract SparkForkV4LPMinimumDefense398 is ForkV4ExitHarness397 {
    function _remainingLimit() internal view returns (uint256) {
        bytes32 keyLimit=keccak256(abi.encode(keccak256("LIMIT_UNISWAP_V4_WITHDRAW"),POOL));
        return IRate398(LIMITS).getCurrentRateLimit(keyLimit);
    }

    function testPass398CompareQuotedMinimaUnderPriceManipulation() public {
        console2.log("=== PASSO 398: WITHDRAW MINIMA VERSUS PRICE MOVEMENT ===");
        console2.log("Fork block",block.number);
        console2.log("Minima independently applied to RLUSD and USDS outputs");
        (uint256 quoteRL,uint256 quoteUS,uint256 baselineNav)=_quoteExit(10_000);
        uint256 initialNav=_portfolioAtStart();
        console2.log("Baseline RLUSD quote",quoteRL);
        console2.log("Baseline USDS quote",quoteUS);
        console2.log("Baseline portfolio",baselineNav);
        uint256[3] memory keep=[uint256(0),999_000,999_900]; // PPM: 0%, 99.9%, 99.99%
        uint256[3] memory frontSizes=[uint256(10_000),200_000,1_000_000];
        uint256 ran;
        uint256 blocked;
        uint256 cases;

        for (uint256 d;d<2;++d) {
            bool frontRL=d==0;
            for (uint256 i;i<frontSizes.length;++i) {
                for (uint256 j;j<keep.length;++j) {
                    uint128 minimumRL=uint128(quoteRL*keep[j]/PPM);
                    uint128 minimumUS=uint128(quoteUS*keep[j]/PPM);
                    uint256 snap=vm.snapshotState();
                    uint256 beforeCap=_remainingLimit();
                    uint256 beforeRL=_balance(RLUSD,PROXY);
                    uint256 beforeUS=_balance(USDS,PROXY);

                    try this.attackerExit397(
                        10_000,uint128(frontSizes[i]*1e18),frontRL,minimumRL,minimumUS,true
                    ) returns (
                        int256 pnl,uint256 outputRL,uint256 outputUS,
                        uint256 gasUsed,uint256 portfolio,int24 tick
                    ) {
                        ran++;
                        assertGe(outputRL,uint256(minimumRL),"FINDING: controller below RLUSD amount0Min");
                        assertGe(outputUS,uint256(minimumUS),"FINDING: controller below USDS amount1Min");
                        console2.log("EXECUTED frontRLUSD",frontRL);
                        console2.log("front input whole units",frontSizes[i]);
                        console2.log("minimum PPM",keep[j]);
                        console2.log("Spark portfolio delta vs no-attacker baseline 1e18",
                                     int256(portfolio)-int256(baselineNav));
                        console2.log("Attacker gross pnl18",pnl);
                        console2.log("Approx attacker swap gas",gasUsed);
                        console2.log("Final tick",tick);
                    } catch {
                        blocked++;
                        assertEq(_remainingLimit(),beforeCap,"FINDING: rate-limit mutated on reverted trade");
                        assertEq(_balance(RLUSD,PROXY),beforeRL,"FINDING: RLUSD changed after revert");
                        assertEq(_balance(USDS,PROXY),beforeUS,"FINDING: USDS changed after revert");
                        assertEq(_portfolioAtStart(),initialNav,"FINDING: portfolio changed after revert");
                        console2.log("BLOCKED frontRLUSD",frontRL);
                        console2.log("front input whole units",frontSizes[i]);
                        console2.log("minimum PPM",keep[j]);
                    }
                    cases++;
                    vm.revertToState(snap);
                }
            }
        }
        console2.log("Cases",cases);
        console2.log("Executed",ran);
        console2.log("Blocked/reverted",blocked);
        assertEq(cases,18);
        assertGt(ran,0,"No executable comparison scenarios");
        console2.log("Interpretation: a minOut-bound trade may still change portfolio mark-to-market.");
        console2.log("NO LIVE TRANSACTIONS. NO PRODUCTION FUNDS MOVED.");
    }

    function testPass398ImpossibleBaselineMinimumMustRevertAtomically() public {
        console2.log("=== PASSO 398: STRICT QUOTE + 1 MUST REVERT ===");
        (uint256 quoteRL,uint256 quoteUS,)=_quoteExit(10_000);
        uint256 limitBefore=_remainingLimit();
        uint256 liqBefore=IExitPosition397(POSITION_MANAGER).getPositionLiquidity(EXIT_NFT);
        uint256 beforeRL=_balance(RLUSD,PROXY);
        uint256 beforeUS=_balance(USDS,PROXY);

        vm.prank(RELAYER);
        (bool ok,)=CONTROLLER.call(abi.encodeWithSignature(
            "decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128)",
            POOL,EXIT_NFT,
            uint128(liqBefore*10_000/PPM),
            uint128(quoteRL+1),
            uint128(quoteUS)
        ));
        assertFalse(ok,"FINDING: impossible min accepted without price movement");
        assertEq(_remainingLimit(),limitBefore,"FINDING: strict revert consumed rate limit");
        assertEq(IExitPosition397(POSITION_MANAGER).getPositionLiquidity(EXIT_NFT),liqBefore);
        assertEq(_balance(RLUSD,PROXY),beforeRL);
        assertEq(_balance(USDS,PROXY),beforeUS);
        console2.log("Impossible minimum reverted; NFT, proxy balances and limit unchanged");
    }
}
