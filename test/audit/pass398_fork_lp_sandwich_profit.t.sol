// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 398: local-fork, synthetic-capital sandwich profitability study.
// Attacker swaps publicly (front), RELAYER-driven ALMProxy withdraws real LP
// liquidity in the isolated fork, then attacker reverses. Compare matched
// front+back control without victim; never transmit to mainnet.
import {console2} from "forge-std/console2.sol";
import {SparkForkLPAdversarialBase397} from "./SparkForkLPAdversarialBase397.sol";

contract SparkForkLPSandwichProfit398 is SparkForkLPAdversarialBase397 {
    function testSandwichDifferentialVsRoundTripControl() public {
        (uint256 baseRL,uint256 baseUS)=_baselineWithRevert();
        uint256[3] memory amounts=[uint256(250_000),1_000_000,5_000_000];
        uint256 successfulPairs;
        uint256 positiveIncrementalPnL;
        int256 bestBeforeGas;
        bool initialized;

        for(uint256 direction=0;direction<2;direction++){
            bool frontWithUSDS=direction==1;
            for(uint256 i=0;i<amounts.length;i++){
                uint128 front=uint128(amounts[i]*1e18);
                uint256 snap=vm.snapshotState();
                bool controlOk;
                int256 controlPnl;
                try this.runSandwich(front,frontWithUSDS,false)
                    returns(int256 pnl,uint256,uint256,uint256,int24,int24)
                {
                    controlPnl=pnl;
                    controlOk=true;
                } catch Error(string memory reason){
                    console2.log("Control roundtrip reverted",reason);
                } catch {
                    console2.log("Control roundtrip reverted, unclassified");
                }
                vm.revertToState(snap);
                if(!controlOk)continue;

                snap=vm.snapshotState();
                try this.runSandwich(front,frontWithUSDS,true)
                    returns(int256 pnl,uint256 victimRL,uint256 victimUS,
                            uint256 gasTrades,int24 beforeTick,int24 afterTick)
                {
                    successfulPairs++;
                    int256 incremental=pnl-controlPnl;
                    if(!initialized||incremental>bestBeforeGas){
                        bestBeforeGas=incremental;
                        initialized=true;
                    }
                    if(incremental>0)positiveIncrementalPnL++;
                    console2.log("Attacker front input USDS?",frontWithUSDS);
                    console2.log("Front amount tokens",amounts[i]);
                    console2.log("Control roundtrip PnL 1e18 (unit-parity gross)");
                    console2.logInt(controlPnl);
                    console2.log("With LP withdrawal PnL 1e18 (unit-parity gross)");
                    console2.logInt(pnl);
                    console2.log("Incremental PnL 1e18 before gas and pool token prices");
                    console2.logInt(incremental);
                    console2.log("Victim withdrawal nominal settlement delta, not total LP NAV");
                    console2.logInt(int256(victimRL+victimUS)-int256(baseRL+baseUS));
                    console2.log("Two public attacker swaps gas estimate",gasTrades);
                    console2.log("Price tick before / after complete sequence");
                    console2.logInt(int256(beforeTick));
                    console2.logInt(int256(afterTick));
                } catch Error(string memory reason){
                    console2.log("Victim-between-swaps scenario reverted",reason);
                } catch {
                    console2.log("Victim-between-swaps scenario reverted, unclassified");
                }
                vm.revertToState(snap);
            }
        }

        console2.log("Control+victim scenario pairs completed",successfulPairs);
        console2.log("Pairs with positive incremental PnL, before gas",positiveIncrementalPnL);
        console2.log("Best measured incremental PnL (1e18)");
        console2.logInt(bestBeforeGas);
        assertGt(successfulPairs,0,"INCONCLUSIVE: no complete, matched sandwich/control");
        console2.log("Positive simulation PnL is NOT a proven mainnet vulnerability.");
        console2.log("Residual LP value, execution ordering, gas, token prices not fully reconciled.");
    }
}
