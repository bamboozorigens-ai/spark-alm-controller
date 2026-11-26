// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 397: compare actual Spark LP withdrawals with/without a preceding
// public market price disturbance. All operations are LOCAL-FORK ONLY.
import {console2} from "forge-std/console2.sol";
import {SparkForkLPAdversarialBase397} from "./SparkForkLPAdversarialBase397.sol";

contract SparkForkLPFrontPriceSkew397 is SparkForkLPAdversarialBase397 {
    function testBaselineRealPositionWithdrawal() public {
        (uint256 baseRL,uint256 baseUS)=_baselineWithRevert();
        console2.log("Baseline RLUSD withdrawn",baseRL);
        console2.log("Baseline USDS withdrawn",baseUS);
        console2.log("Baseline total at assumed nominal 1:1",baseRL+baseUS);
        console2.log("Residual NFT valuation not included in this test.");
    }

    function testPublicFrontRunAltersZeroMinimumExitSettlement() public {
        (uint256 baseRL,uint256 baseUS)=_baselineWithRevert();
        uint256[3] memory sizes=[uint256(250_000),1_000_000,5_000_000];
        uint256 passes;
        uint256 changed;
        uint256 initialLiquidity=ILP397PositionManager(POSITION_MANAGER).getPositionLiquidity(NFT);

        for(uint256 direction=0;direction<2;direction++){
            bool frontWithUSDS=direction==1;
            for(uint256 i=0;i<sizes.length;i++){
                uint128 amount=uint128(sizes[i]*1e18);
                uint256 snap=vm.snapshotState();
                try this.runFrontAndWithdraw(amount,frontWithUSDS,0,0)
                    returns(uint256 rl,uint256 us,int24 beforeTick,int24 afterTick)
                {
                    passes++;
                    int256 nominalDelta=int256(rl+us)-int256(baseRL+baseUS);
                    console2.log("Front token is USDS",frontWithUSDS);
                    console2.log("Front amount tokens",sizes[i]);
                    console2.log("Baseline total withdrawn",baseRL+baseUS);
                    console2.log("Perturbed total withdrawn",rl+us);
                    console2.log("Pool tick before/after trade");
                    console2.logInt(int256(beforeTick));
                    console2.logInt(int256(afterTick));
                    console2.log("Delta RLUSD from baseline");
                    console2.logInt(int256(rl)-int256(baseRL));
                    console2.log("Delta USDS from baseline");
                    console2.logInt(int256(us)-int256(baseUS));
                    console2.log("Nominal withdrawal change, not protocol PnL");
                    console2.logInt(nominalDelta);
                    if(rl!=baseRL||us!=baseUS)changed++;
                    assertEq(
                        uint256(ILP397PositionManager(POSITION_MANAGER).getPositionLiquidity(NFT))
                            + uint256(withdrawLiq),
                        initialLiquidity,
                        "FINDING: LP liquidity burn mismatch"
                    );
                } catch Error(string memory reason){
                    console2.log("INCONCLUSIVE front+withdraw",reason);
                } catch(bytes memory reason){
                    console2.log("INCONCLUSIVE low-level front+withdraw revert bytes",reason.length);
                }
                vm.revertToState(snap);
            }
        }
        console2.log("Executable front-run perturbation scenarios",passes);
        console2.log("Scenarios with changed LP token composition",changed);
        assertGt(passes,0,"INCONCLUSIVE: no tested perturbation executed");
        assertGt(changed,0,"INCONCLUSIVE: no measured position settlement change");
        console2.log("READING: altered withdrawal tokens are not by themselves verified loss.");
    }
}
