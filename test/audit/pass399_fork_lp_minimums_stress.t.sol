// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 399: adversarial LP withdrawal min0/min1 under local price skew.
// Compare zero-min withdrawal against baseline-value-protecting minimums.
// NO LIVE TX, no signed orders, fork is discarded after each test.
import {console2} from "forge-std/console2.sol";
import {SparkForkLPAdversarialBase397} from "./SparkForkLPAdversarialBase397.sol";

contract SparkForkLPMinimumStress399 is SparkForkLPAdversarialBase397 {
    function testBaselineLevelMinimumsPreventSkewedSettlements() public {
        (uint256 baseRL,uint256 baseUS)=_baselineWithRevert();
        assertLe(baseRL,type(uint128).max);
        assertLe(baseUS,type(uint128).max);
        uint256[2] memory amounts=[uint256(500_000),2_000_000];
        uint256 pairedScenarios;
        uint256 strictReverts;
        uint256 strictAccepted;

        for(uint256 direction=0;direction<2;direction++){
            bool frontWithUSDS=direction==1;
            for(uint256 i=0;i<amounts.length;i++){
                uint128 volume=uint128(amounts[i]*1e18);
                uint256 snap=vm.snapshotState();
                bool zeroSucceeded;
                uint256 zeroRL;
                uint256 zeroUS;
                try this.runFrontAndWithdraw(volume,frontWithUSDS,0,0)
                    returns(uint256 d0,uint256 d1,int24,int24)
                {
                    zeroSucceeded=true;
                    zeroRL=d0;
                    zeroUS=d1;
                } catch {
                    console2.log("No zero-min baseline at front volume",amounts[i]);
                }
                vm.revertToState(snap);
                if(!zeroSucceeded)continue;
                pairedScenarios++;

                // Execute exactly the same preliminary trade on a fresh snapshot,
                // with min0/min1 pinned to the unmanipulated output amounts.
                snap=vm.snapshotState();
                bool strictSucceeded;
                try this.runFrontAndWithdraw(
                    volume,frontWithUSDS,uint128(baseRL),uint128(baseUS)
                ) returns(uint256,uint256,int24,int24)
                {
                    strictSucceeded=true;
                } catch Error(string memory reason) {
                    console2.log("Strict-min withdrawal reverted",reason);
                } catch(bytes memory reason){
                    console2.log("Strict-min withdrawal revert payload bytes",reason.length);
                }
                vm.revertToState(snap);

                if(strictSucceeded)strictAccepted++;
                else strictReverts++;
                console2.log("Attacker input USDS",frontWithUSDS);
                console2.log("Front tokens",amounts[i]);
                console2.log("Withdraw with zero minimum succeeded",zeroSucceeded);
                console2.log("Withdraw with unperturbed minima succeeded",strictSucceeded);
                console2.log("Zero-min settlement delta in RLUSD");
                console2.logInt(int256(zeroRL)-int256(baseRL));
                console2.log("Zero-min settlement delta in USDS");
                console2.logInt(int256(zeroUS)-int256(baseUS));
            }
        }
        console2.log("Paired manipulated-withdraw scenarios",pairedScenarios);
        console2.log("Strict-min scenarios blocked",strictReverts);
        console2.log("Strict-min scenarios accepted",strictAccepted);
        assertGt(pairedScenarios,0,"INCONCLUSIVE: no matched minimum comparisons");
        console2.log("This tests operator-provided minima; it does NOT prove an oracle or loss.");
        console2.log("Note: both token minima constrain composition, not total LP NAV.");
    }

    function testImpossibleMinimaRevertAndKeepProxyUnchanged() public {
        uint256 beforeRL=_balance(RLUSD,PROXY);
        uint256 beforeUS=_balance(USDS,PROXY);
        uint256 beforeLiquidity=ILP397PositionManager(POSITION_MANAGER)
            .getPositionLiquidity(NFT);
        uint256 beforeAttackerRL=_balance(RLUSD,ATTACKER);
        uint256 beforeAttackerUS=_balance(USDS,ATTACKER);

        vm.prank(RELAYER);
        (bool ok,bytes memory revertData)=CONTROLLER.call(abi.encodeWithSignature(
            "decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128)",
            POOL,NFT,withdrawLiq,type(uint128).max,type(uint128).max
        ));
        assertFalse(ok,"FINDING: impossible two-token minima accepted");
        assertEq(_balance(RLUSD,PROXY),beforeRL);
        assertEq(_balance(USDS,PROXY),beforeUS);
        assertEq(_balance(RLUSD,ATTACKER),beforeAttackerRL);
        assertEq(_balance(USDS,ATTACKER),beforeAttackerUS);
        assertEq(ILP397PositionManager(POSITION_MANAGER).getPositionLiquidity(NFT),
                 beforeLiquidity,"FINDING: LP burned despite revert");
        console2.log("Impossible minima reverted atomically; payload bytes",revertData.length);
    }
}
