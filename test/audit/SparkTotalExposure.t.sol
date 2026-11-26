// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 359: Estimate ECONOMIC exposure, not just swap output, for Spark's
// RLUSD/USDS swap on the pinned live-state fork. Includes Spark-owned Uniswap V4
// NFT position principal amounts at post-trade pool price and accrued LP fees.
// No ETH transaction is ever broadcast. Attacker alone gets synthetic balances.
import "./SparkFundedSwapSandwich.t.sol";
import {FullMath} from "../../lib/uniswap-v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "../../lib/uniswap-v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "../../lib/uniswap-v4-core/src/libraries/TickMath.sol";

interface IExposStateView {
    function getSlot0(bytes32 poolId)
        external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getFeeGrowthInside(bytes32 poolId, int24 tickLower, int24 tickUpper)
        external view returns (uint256 feeGrowth0X128, uint256 feeGrowth1X128);
    function getPositionInfo(bytes32 poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external view returns (uint128 liquidity, uint256 feeGrowth0LastX128, uint256 feeGrowth1LastX128);
}
interface IExposPosm {
    function ownerOf(uint256 id) external view returns (address);
    function getPositionLiquidity(uint256 id) external view returns (uint128 liquidity);
}

contract SparkTotalExposure is SparkFundedSwapSandwich {
    address constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    uint256 constant Q128 = 1 << 128;

    // The free public RPC does not support archive state for arbitrary contracts.
    // Use one FRESH on-chain snapshot instead of an archived block. All scenarios
    // are compared at that exact same fork height via vm.snapshotState().
    function _forkBlockNumber() internal pure override returns (uint256) {
        return 0;
    }

    struct Exposure {
        uint256 proxyRLUSD;
        uint256 proxyUSDS;
        uint256 nftPrincipalRLUSD;
        uint256 nftPrincipalUSDS;
        uint256 nftUncollectedFeesRLUSD;
        uint256 nftUncollectedFeesUSDS;
        int24 tick;
        uint160 sqrtPriceX96;
    }

    function _positionInfo(uint256 i)
        internal pure returns (uint256 tokenId, int24 low, int24 high)
    {
        if (i == 0) return (385168, 0, 10);
        if (i == 1) return (385169, -10, 0);
        return (460903, 9, 10);
    }

    function _principalForPosition(uint160 sqrtPrice, int24 lowerTick, int24 upperTick, uint128 liquidity)
        internal pure returns (uint256 principal0, uint256 principal1)
    {
        uint160 lower = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 upper = TickMath.getSqrtPriceAtTick(upperTick);
        if (sqrtPrice <= lower) {
            principal0 = SqrtPriceMath.getAmount0Delta(lower, upper, liquidity, false);
        } else if (sqrtPrice >= upper) {
            principal1 = SqrtPriceMath.getAmount1Delta(lower, upper, liquidity, false);
        } else {
            principal0 = SqrtPriceMath.getAmount0Delta(sqrtPrice, upper, liquidity, false);
            principal1 = SqrtPriceMath.getAmount1Delta(lower, sqrtPrice, liquidity, false);
        }
    }

    function _getExposure() internal view returns (Exposure memory e) {
        e.proxyRLUSD = _balance(RLUSD, PROXY);
        e.proxyUSDS = _balance(USDS, PROXY);

        IExposStateView viewState = IExposStateView(STATE_VIEW);
        (e.sqrtPriceX96, e.tick,,) = viewState.getSlot0(POOL);

        for (uint256 i; i < 3; ++i) {
            (uint256 id, int24 lo, int24 hi) = _positionInfo(i);
            require(IExposPosm(POSITION_MANAGER).ownerOf(id) == PROXY, "position not Spark owned");

            (uint128 liquidity, uint256 last0, uint256 last1) = viewState.getPositionInfo(
                POOL, POSITION_MANAGER, lo, hi, bytes32(id)
            );
            require(liquidity > 0, "position 0 liquidity");
            require(liquidity == IExposPosm(POSITION_MANAGER).getPositionLiquidity(id), "liquidity mismatch");

            (uint256 amount0, uint256 amount1) = _principalForPosition(
                e.sqrtPriceX96, lo, hi, liquidity
            );
            e.nftPrincipalRLUSD += amount0;
            e.nftPrincipalUSDS += amount1;

            (uint256 feeGrowth0, uint256 feeGrowth1) = viewState.getFeeGrowthInside(POOL, lo, hi);

            // Uniswap fee growth accumulates modulo 2^256.
            uint256 delta0;
            uint256 delta1;
            unchecked {
                delta0 = feeGrowth0 - last0;
                delta1 = feeGrowth1 - last1;
            }

            e.nftUncollectedFeesRLUSD += FullMath.mulDiv(delta0, uint256(liquidity), Q128);
            e.nftUncollectedFeesUSDS += FullMath.mulDiv(delta1, uint256(liquidity), Q128);
        }
    }

    function _totalNominal(Exposure memory e) internal pure returns (uint256) {
        return e.proxyRLUSD + e.proxyUSDS
             + e.nftPrincipalRLUSD + e.nftPrincipalUSDS
             + e.nftUncollectedFeesRLUSD + e.nftUncollectedFeesUSDS;
    }

    function _printExposure(string memory name, Exposure memory e) internal pure {
        console2.log(name);
        console2.log("Pool tick", e.tick);
        console2.log("Spark RLUSD liquid balance (18 decimals)", e.proxyRLUSD);
        console2.log("Spark USDS liquid balance (18 decimals)", e.proxyUSDS);
        console2.log("Spark RLUSD LP principal (18 decimals)", e.nftPrincipalRLUSD);
        console2.log("Spark USDS LP principal (18 decimals)", e.nftPrincipalUSDS);
        console2.log("Spark RLUSD accrued fees (18 decimals)", e.nftUncollectedFeesRLUSD);
        console2.log("Spark USDS accrued fees (18 decimals)", e.nftUncollectedFeesUSDS);
        console2.log("Total Spark nominal 1e18", _totalNominal(e));
    }

    function testTotalSparkEconomicExposure() public {
        console2.log("=== PASSO 359: REAL SPARK INVENTORY + OWNED LP PRINCIPAL + FEES ===");
        console2.log("LATEST block pinned at fork creation", block.number);
        console2.log("Victim swap: 5 million REAL RLUSD (hypothetical RELAYER order)");
        console2.log("Spark is LP in the same RLUSD/USDS pool.");
        console2.log("All holdings valued at 1 RLUSD = 1 USDS = 1 USD.");
        console2.log("NOTE: live snapshot may differ from Passo 355 historical NFT holdings.");

        Exposure memory beforeState = _getExposure();
        _printExposure("INITIAL EXPOSURE", beforeState);

        uint128 victim = 5_000_000e18;
        uint256 baselineSnap = vm.snapshotState();
        uint256 baselineOut = _victimSwap(victim);
        Exposure memory baselineAfter = _getExposure();
        vm.revertToState(baselineSnap);

        console2.log("Baseline victim received USDS (micro)", baselineOut / 1e12);
        _printExposure("BASELINE POST-SWAP", baselineAfter);

        uint256[4] memory fronts = [uint256(10_000), 50_000, 200_000, 1_000_000];
        uint256 wins;
        for (uint256 j; j < fronts.length; ++j) {
            uint128 front = uint128(fronts[j] * 1e18);
            uint256 snap = vm.snapshotState();
            try this.scenario(victim, front, true, true)
                returns (int256 attackerPnlMicro, uint256 victimReceived, uint256 attackerGas)
            {
                Exposure memory attackedAfter = _getExposure();

                int256 directOutputShortfall18 = int256(baselineOut) - int256(victimReceived);
                int256 portfolioDiff18 = int256(_totalNominal(attackedAfter))
                                      - int256(_totalNominal(baselineAfter));
                int256 lpPrincipalDiff18 =
                    int256(attackedAfter.nftPrincipalRLUSD + attackedAfter.nftPrincipalUSDS)
                    - int256(baselineAfter.nftPrincipalRLUSD + baselineAfter.nftPrincipalUSDS);
                int256 lpFeeDiff18 =
                    int256(attackedAfter.nftUncollectedFeesRLUSD + attackedAfter.nftUncollectedFeesUSDS)
                    - int256(baselineAfter.nftUncollectedFeesRLUSD + baselineAfter.nftUncollectedFeesUSDS);

                console2.log("--- Front amount RLUSD", fronts[j]);
                console2.log("Attacker gross PnL microUSD", attackerPnlMicro);
                console2.log("Spark DIRECT swap output shortfall microUSD", directOutputShortfall18 / 1e12);
                console2.log("Spark LP principal change vs baseline microUSD", lpPrincipalDiff18 / 1e12);
                console2.log("Spark LP fees change vs baseline microUSD", lpFeeDiff18 / 1e12);
                console2.log("Spark FULL portfolio difference vs baseline microUSD", portfolioDiff18 / 1e12);
                console2.log("Attacker swap gas estimate", attackerGas);
                console2.log("Pool tick after backrun", attackedAfter.tick);

                if (attackerPnlMicro > 0 && portfolioDiff18 < 0) wins++;
            } catch Error(string memory reason) {
                console2.log("SCENARIO REVERT", reason);
            } catch {
                console2.log("SCENARIO REVERT: opaque");
            }
            vm.revertToState(snap);
        }
        console2.log("Positive attacker gross PnL plus Spark FULL portfolio decrease", wins);
        console2.log("CAUTION: Does not include other Spark addresses, other LPs, gas, external token prices, or an observed real relayer order.");
        console2.log("No deployment, no mainnet broadcast, local fork only.");
    }
}
