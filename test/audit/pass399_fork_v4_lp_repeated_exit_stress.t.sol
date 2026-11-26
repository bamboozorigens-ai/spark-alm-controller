// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 399: stress two consecutive withdrawals of the same REAL Spark V4
// position under external price movement, on an isolated local fork only.
// The only synthetic capital is assigned to ATTACKER, never to Spark.
import "./pass397_fork_v4_lp_mev_portfolio.t.sol";

contract SparkForkV4RepeatedLPExit399 is ForkV4ExitHarness397 {
    function baselineDouble399(uint256 fractionPPM)
        external returns (uint256 totalRL, uint256 totalUS, uint256 portfolio)
    {
        require(msg.sender==address(this),"self only");
        (uint256 r0,uint256 u0)=_withdrawPosition(fractionPPM,0,0);
        (uint256 r1,uint256 u1)=_withdrawPosition(fractionPPM,0,0);
        totalRL=r0+r1;
        totalUS=u0+u1;
        portfolio=_totalNominal(_getExposure());
    }

    function adversarialDouble399(
        uint256 fractionPPM,uint128 frontAmount,bool withRL
    ) external returns (
        int256 pnl18,uint256 receivedRL,uint256 receivedUS,
        uint256 gasUnits,uint256 portfolio,uint256 remainingLiq
    ) {
        require(msg.sender==address(this),"self only");
        uint256 attackerRLBefore=_balance(RLUSD,ATTACKER);
        uint256 attackerUSBefore=_balance(USDS,ATTACKER);
        address tokenIn=withRL?RLUSD:USDS;
        address tokenOut=withRL?USDS:RLUSD;

        uint256 g=gasleft();
        uint256 frontOut=_swapPublic(tokenIn,frontAmount);
        gasUnits=g-gasleft();

        (uint256 a,uint256 b)=_withdrawPosition(fractionPPM,0,0);
        (uint256 c,uint256 d)=_withdrawPosition(fractionPPM,0,0);
        receivedRL=a+c;
        receivedUS=b+d;

        require(frontOut<=type(uint128).max,"front output overflow");
        g=gasleft();
        _swapPublic(tokenOut,uint128(frontOut));
        gasUnits+=g-gasleft();

        pnl18=(int256(_balance(RLUSD,ATTACKER))-int256(attackerRLBefore))
             +(int256(_balance(USDS,ATTACKER))-int256(attackerUSBefore));
        portfolio=_totalNominal(_getExposure());
        remainingLiq=IExitPosition397(POSITION_MANAGER).getPositionLiquidity(EXIT_NFT);
    }

    function testPass399TwoConsecutiveLPExitsUnderAdversarialPrice() public {
        console2.log("=== PASSO 399: DOUBLE LP EXIT / PRICE STRESS / REAL NFT ===");
        console2.log("Fork block",block.number);
        console2.log("Only local simulation, no mainnet broadcast");
        uint256 initialNav=_portfolioAtStart();
        uint256 initialRL=_balance(RLUSD,PROXY);
        uint256 initialUS=_balance(USDS,PROXY);
        uint256 initialLiq=IExitPosition397(POSITION_MANAGER).getPositionLiquidity(EXIT_NFT);
        uint256[3] memory fractions=[uint256(10_000),100_000,250_000];
        uint256[2] memory fronts=[uint256(200_000),1_000_000];
        uint256 completed;
        uint256 reverted;
        uint256 candidates;

        for (uint256 f;f<fractions.length;++f) {
            uint256 fraction=fractions[f];
            uint256 snap=vm.snapshotState();
            (uint256 baselineRL,uint256 baselineUS,uint256 baselineNav)=this.baselineDouble399(fraction);
            vm.revertToState(snap);
            console2.log("Fraction withdrawn per call PPM",fraction);
            console2.log("Baseline double-exit RLUSD",baselineRL);
            console2.log("Baseline double-exit USDS",baselineUS);
            console2.log("Baseline double-exit portfolio nominal",baselineNav);

            for (uint256 dir;dir<2;++dir) {
                bool withRL=dir==0;
                for (uint256 i;i<fronts.length;++i) {
                    uint128 amount=uint128(fronts[i]*1e18);
                    snap=vm.snapshotState();

                    int256 controlPnl;
                    bool controlOK;
                    try this.attackerExit397(fraction,amount,withRL,0,0,false)
                        returns (int256 pnl,uint256,uint256,uint256,uint256,int24)
                    {
                        controlPnl=pnl;
                        controlOK=true;
                    } catch {}
                    vm.revertToState(snap);

                    snap=vm.snapshotState();
                    try this.adversarialDouble399(fraction,amount,withRL)
                        returns (
                            int256 pnl,uint256 gotRL,uint256 gotUS,
                            uint256 usedGas,uint256 afterNav,uint256 remaining
                        )
                    {
                        completed++;
                        int256 navDelta=int256(afterNav)-int256(baselineNav);
                        console2.log("frontRLUSD",withRL);
                        console2.log("front amount whole tokens",fronts[i]);
                        console2.log("Attacker gross pnl18",pnl);
                        console2.log("Control without victim gross pnl18",controlPnl);
                        console2.log("Control executed",controlOK);
                        console2.log("Spark received RLUSD",gotRL);
                        console2.log("Spark received USDS",gotUS);
                        console2.log("Spark full-portfolio difference vs baseline 1e18",navDelta);
                        console2.log("NFT liquidity remaining",remaining);
                        console2.log("Attacker swaps gas units",usedGas);
                        if (pnl>0 && navDelta<0 && controlOK && controlPnl<=0) {
                            candidates++;
                            console2.log("CANDIDATE: attacker gross benefit and modeled Spark decline");
                        }
                        assertLt(remaining,initialLiq,"FINDING: neither withdrawal reduced liquidity");
                        assertGt(remaining,0,"FINDING: unexpected NFT complete exit");
                    } catch Error(string memory reason) {
                        reverted++;
                        assertEq(_portfolioAtStart(),initialNav,"FINDING: portfolio altered despite revert");
                        assertEq(_balance(RLUSD,PROXY),initialRL,"FINDING: RLUSD changed despite revert");
                        assertEq(_balance(USDS,PROXY),initialUS,"FINDING: USDS changed despite revert");
                        assertEq(IExitPosition397(POSITION_MANAGER).getPositionLiquidity(EXIT_NFT),
                                 initialLiq,"FINDING: position changed despite revert");
                        console2.log("Double-exit scenario reverted:",reason);
                    } catch {
                        reverted++;
                        assertEq(_portfolioAtStart(),initialNav,"FINDING: portfolio altered despite revert");
                        assertEq(IExitPosition397(POSITION_MANAGER).getPositionLiquidity(EXIT_NFT),
                                 initialLiq,"FINDING: position changed despite revert");
                        console2.log("Double-exit scenario reverted (opaque)");
                    }
                    vm.revertToState(snap);
                }
            }
        }
        assertEq(completed+reverted,12,"Scenario accounting incomplete");
        assertGt(completed,0,"No executable double-exit scenario");
        console2.log("Completed scenarios",completed);
        console2.log("Reverted scenarios",reverted);
        console2.log("Gross candidates",candidates);
        console2.log("CAVEAT: nominal RLUSD/USDS 1:1 assumption; Spark portfolios outside 3 NFT model excluded.");
        console2.log("CAVEAT: excludes real gas economics, external markets and historical relayer intent.");
        console2.log("FORK ONLY. NO PRODUCTION TRANSACTIONS.");
    }
}
