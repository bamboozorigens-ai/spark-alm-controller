// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 385: Identify real mainnet Uniswap V4 routes without guessing pool IDs.
// The two exact poolIds come from test/mainnet-fork/Uniswapv4.t.sol.
// Read-only queries on a LOCAL mainnet fork. No token movement, no broadcast.
//
// Important implementation details:
// - MainnetController.swapUniswapV4 looks up slippage using the *last 20 bytes*
//   of the full poolId (address(uint160(uint256(poolId)))).
// - Rate limits instead use the *full bytes32 poolId*.
// - PoolKey is retrieved from PositionManager.poolKeys(bytes25(poolId)) and
//   validated by recomputing keccak256(abi.encode(key)).
import { Test } from "../../lib/forge-std/src/Test.sol";
import { console2 } from "../../lib/forge-std/src/console2.sol";
import { IRateLimits } from "../../src/interfaces/IRateLimits.sol";
import { RateLimitHelpers } from "../../src/RateLimitHelpers.sol";

interface IControllerV4Inventory {
    function LIMIT_UNISWAP_V4_SWAP() external view returns (bytes32);
    function LIMIT_UNISWAP_V4_DEPOSIT() external view returns (bytes32);
    function LIMIT_UNISWAP_V4_WITHDRAW() external view returns (bytes32);
    function maxSlippages(address poolIdSuffix) external view returns (uint256);
    function uniswapV4TickLimits(bytes32 id)
        external view returns (int24 lower, int24 upper, uint24 maxWidth);
}

interface IPositionManagerV4Inventory {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }
    function poolKeys(bytes25 partialPoolId) external view returns (PoolKey memory key);
}

interface IStateViewV4Inventory {
    function getSlot0(bytes32 poolId) external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

interface IERC20V4Inventory {
    function balanceOf(address account) external view returns (uint256 balance);
    function decimals() external view returns (uint8);
}

contract SparkLiveUniswapV4RouteInventory is Test {
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;

    // Official fork tests: USDC / USDT.
    bytes32 constant USDC_USDT_POOL =
        0x8aa4e11cbdf30eedc92100f4c8a31ff748e201d44712cc8c90d189edaa8e4e47;
    // Official fork tests: USDT / USDS.
    bytes32 constant USDT_USDS_POOL =
        0xb54ece65cc2ddd3eaec0ad18657470fb043097220273d87368a062c7d4e59180;

    IControllerV4Inventory ctrl;
    IPositionManagerV4Inventory manager;
    IStateViewV4Inventory stateView;
    IRateLimits limits;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        ctrl = IControllerV4Inventory(CONTROLLER);
        manager = IPositionManagerV4Inventory(POSITION_MANAGER);
        stateView = IStateViewV4Inventory(STATE_VIEW);
        limits = IRateLimits(LIMITS);
        console2.log("Current mainnet fork block", block.number);
    }

    function _logCurrency(string memory label, address currency) internal view {
        console2.log(label, currency);
        if (currency == address(0)) {
            console2.log("Native ETH currency (no ERC20 token address)");
            return;
        }

        (bool okBalance, bytes memory resultBalance) = currency.staticcall(
            abi.encodeCall(IERC20V4Inventory.balanceOf, (PROXY))
        );
        if (okBalance && resultBalance.length == 32) {
            console2.log("  ALMProxy balance native", abi.decode(resultBalance, (uint256)));
        } else {
            console2.log("  balanceOf failed; not an authorization result");
        }

        (bool okDecimals, bytes memory resultDecimals) = currency.staticcall(
            abi.encodeCall(IERC20V4Inventory.decimals, ())
        );
        if (okDecimals && resultDecimals.length == 32) {
            console2.log("  Token decimals", abi.decode(resultDecimals, (uint8)));
        } else {
            console2.log("  decimals read failed");
        }
    }

    function _logLimit(
        string memory route,
        bytes32 limitRoot,
        bytes32 id
    ) internal view {
        bytes32 rateKey = RateLimitHelpers.makeBytes32Key(limitRoot, id);
        IRateLimits.RateLimitData memory data = limits.getRateLimitData(rateKey);
        uint256 current = limits.getCurrentRateLimit(rateKey);
        console2.log(route);
        console2.log("  configured maximum normalized", data.maxAmount);
        console2.log("  available normalized", current);
        console2.log("  refill per second normalized", data.slope);
        console2.log("  enabled", data.maxAmount > 0);
    }

    function _inspect(bytes32 id, string memory description) internal view {
        console2.log("");
        console2.log("=== FULL POOL-ID INVENTORY ===");
        console2.log(description);
        console2.logBytes32(id);
        address slippageAddress = address(uint160(uint256(id)));
        console2.log("Last-20-byte pool identifier", slippageAddress);
        uint256 slippage = ctrl.maxSlippages(slippageAddress);
        console2.log("Slippage floor (1e18)", slippage);
        console2.log("Slippage configured", slippage > 0);

        _logLimit("UniswapV4 SWAP", ctrl.LIMIT_UNISWAP_V4_SWAP(), id);
        _logLimit("UniswapV4 DEPOSIT", ctrl.LIMIT_UNISWAP_V4_DEPOSIT(), id);
        _logLimit("UniswapV4 WITHDRAW", ctrl.LIMIT_UNISWAP_V4_WITHDRAW(), id);

        (int24 lower, int24 upper, uint24 maxWidth) = ctrl.uniswapV4TickLimits(id);
        console2.log("Position mint tick maxWidth", maxWidth);
        console2.log("Position mint ticks configured", maxWidth > 0);
        // Lower/upper may be negative and console2.log supports signed int256.
        console2.log("Tick lower / upper");
        console2.logInt(int256(lower));
        console2.logInt(int256(upper));

        try manager.poolKeys(bytes25(id)) returns (IPositionManagerV4Inventory.PoolKey memory key) {
            bytes32 recomputed = keccak256(abi.encode(key));
            bool matched = recomputed == id;
            console2.log("PositionManager poolKey matches full ID", matched);
            console2.log("Fee", key.fee);
            console2.log("Tick spacing");
            console2.logInt(int256(key.tickSpacing));
            console2.log("Hooks", key.hooks);
            _logCurrency("currency0", key.currency0);
            _logCurrency("currency1", key.currency1);
            if (!matched) {
                console2.log("ATTENTION: Unregistered/mismatched pool key; do not assume callable swap.");
            }
        } catch {
            console2.log("PositionManager poolKeys read reverted; cannot confirm this pool.");
        }

        try stateView.getSlot0(id) returns (
            uint160 sqrtPriceX96, int24 tick, uint24, uint24
        ) {
            console2.log("Current sqrtPriceX96", uint256(sqrtPriceX96));
            console2.log("Current tick");
            console2.logInt(int256(tick));
        } catch {
            console2.log("StateView slot0 reverted; pool may not be initialized.");
        }

        try stateView.getLiquidity(id) returns (uint128 poolLiquidity) {
            console2.log("Current in-range liquidity", uint256(poolLiquidity));
        } catch {
            console2.log("StateView liquidity read unavailable.");
        }
    }

    function testReadKnownUSDCUSDTUniswapV4Pool() public view {
        _inspect(USDC_USDT_POOL, "USDC/USDT: known official test pool");
    }

    function testReadKnownUSDTUSDSUniswapV4Pool() public view {
        _inspect(USDT_USDS_POOL, "USDT/USDS: known official test pool");
    }
}
