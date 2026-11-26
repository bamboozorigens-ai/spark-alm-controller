// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 383: live RLUSD/USDC Curve swap on LOCAL MAINNET FORK.
// Positive and negative controls. Never broadcasts transactions.
// A passing swap is expected protocol behavior, NOT a vulnerability.
//
// This test requires an RPC capable of servicing fork state reads.
// If that RPC reports "block not found", treat as infrastructure failure.
import { Test } from "../../lib/forge-std/src/Test.sol";
import { console2 } from "../../lib/forge-std/src/console2.sol";

import { IRateLimits } from "../../src/interfaces/IRateLimits.sol";
import { RateLimitHelpers } from "../../src/RateLimitHelpers.sol";

interface ICurveSwapControllerLive {
    function RELAYER() external view returns (bytes32);
    function LIMIT_CURVE_SWAP() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function maxSlippages(address pool) external view returns (uint256);
    function swapCurve(
        address pool,
        uint256 inputIndex,
        uint256 outputIndex,
        uint256 amountIn,
        uint256 minAmountOut
    ) external returns (uint256 amountOut);
}

interface ICurveSwapPoolLive {
    function N_COINS() external view returns (uint256);
    function coins(uint256 index) external view returns (address);
    function stored_rates() external view returns (uint256[] memory);
    function get_dy(uint256 i, uint256 j, uint256 amount) external view returns (uint256);
}

interface IERC20SwapBalancesLive {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address account, address spender) external view returns (uint256);
}

contract SparkLiveRLUSDCurveExecution is Test {
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant RELAYER_SAFE = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant POOL = address(bytes20(hex"d001ae433f254283fece51d4acce8c53263aa186"));
    address constant RLUSD = address(bytes20(hex"8292bb45bf1ee4d140127049757c2e0ff06317ed"));
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNAUTHORIZED = address(0xBEEF);

    uint256 constant ONE_MILLION_RLUSD = 1_000_000e18;
    uint256 constant FIVE_MILLION_RLUSD = 5_000_000e18;

    ICurveSwapControllerLive ctrl;
    ICurveSwapPoolLive pool;
    IRateLimits limits;
    IERC20SwapBalancesLive rlusd;
    IERC20SwapBalancesLive usdc;
    bytes32 swapKey;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        ctrl = ICurveSwapControllerLive(CONTROLLER);
        pool = ICurveSwapPoolLive(POOL);
        limits = IRateLimits(LIMITS);
        rlusd = IERC20SwapBalancesLive(RLUSD);
        usdc = IERC20SwapBalancesLive(USDC);

        assertEq(pool.N_COINS(), 2, "Not the expected two-coin Curve pool");
        assertEq(pool.coins(0), USDC, "Unexpected Curve USDC index");
        assertEq(pool.coins(1), RLUSD, "Unexpected Curve RLUSD index");
        assertEq(ctrl.maxSlippages(POOL), 999_000_000_000_000_000, "Slippage configuration changed");
        assertTrue(ctrl.hasRole(ctrl.RELAYER(), RELAYER_SAFE), "Configured relayer role changed");
        assertFalse(ctrl.hasRole(ctrl.RELAYER(), UNAUTHORIZED), "Test actor unexpectedly authorized");
        swapKey = RateLimitHelpers.makeAddressKey(ctrl.LIMIT_CURVE_SWAP(), POOL);
        assertTrue(limits.hasRole(limits.CONTROLLER(), CONTROLLER), "Controller missing RateLimits role");

        console2.log("Live fork block", block.number);
        console2.log("Curve RLUSD/USDC pool", POOL);
        console2.log("Swap capacity", limits.getCurrentRateLimit(swapKey));
    }

    function _minOut(uint256 amountIn) internal view returns (uint256) {
        uint256[] memory rates = pool.stored_rates();
        assertEq(rates.length, 2, "Unexpected Curve rates");
        return amountIn * rates[1] * ctrl.maxSlippages(POOL) / rates[0] / 1e18;
    }

    function _assertAllowedSwap(uint256 amountIn) internal {
        uint256 minOut = _minOut(amountIn);
        uint256 quotedOut = pool.get_dy(1, 0, amountIn);
        uint256 availableBefore = limits.getCurrentRateLimit(swapKey);
        uint256 rlusdBefore = rlusd.balanceOf(PROXY);
        uint256 usdcBefore = usdc.balanceOf(PROXY);

        assertGe(quotedOut, minOut, "Live pool quote already below required minimum");
        assertGe(availableBefore, amountIn, "Live route capacity insufficient");
        assertGe(rlusdBefore, amountIn, "Live proxy balance insufficient");

        // The authorized relayer is IMPERSONATED ONLY ON THIS LOCAL FORK.
        vm.prank(RELAYER_SAFE);
        uint256 received = ctrl.swapCurve(POOL, 1, 0, amountIn, minOut);

        uint256 rlusdAfter = rlusd.balanceOf(PROXY);
        uint256 usdcAfter = usdc.balanceOf(PROXY);
        uint256 availableAfter = limits.getCurrentRateLimit(swapKey);

        assertEq(rlusdBefore - rlusdAfter, amountIn, "RLUSD spent differs from input");
        assertEq(usdcAfter - usdcBefore, received, "USDC received differs from return value");
        assertGe(received, minOut, "Curve swapped below permitted minOut");
        assertEq(availableBefore - availableAfter, amountIn, "Swap rate limit accounting mismatch");

        console2.log("RLUSD input (18 decimals)", amountIn);
        console2.log("Quote USDC (6 decimals)", quotedOut);
        console2.log("Controller minimum USDC (6 decimals)", minOut);
        console2.log("Received USDC (6 decimals)", received);
        console2.log("Swap rate limit consumed (18 decimals)", availableBefore - availableAfter);
        console2.log("Remaining RLUSD proxy balance", rlusdAfter);
        console2.log("Remaining USDC proxy balance", usdcAfter);
        console2.log("RLUSD allowance to pool after swap", rlusd.allowance(PROXY, POOL));
        console2.log("Expected authorized local-fork swap succeeded");
    }

    function testLiveAllowedOneMillionRLUSDToUSDC() public {
        _assertAllowedSwap(ONE_MILLION_RLUSD);
    }

    function testLiveAllowedFiveMillionRLUSDToUSDC() public {
        _assertAllowedSwap(FIVE_MILLION_RLUSD);
    }

    function testUnprivilegedCallerCannotSwap() public {
        // Precompute the expected role BEFORE expectRevert; otherwise the
        // getter call could consume Foundry's next-call expectation.
        bytes32 role = ctrl.RELAYER();
        bytes memory expected = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            UNAUTHORIZED,
            role
        );
        vm.startPrank(UNAUTHORIZED);
        vm.expectRevert(expected);
        ctrl.swapCurve(POOL, 1, 0, ONE_MILLION_RLUSD, 999_000e6);
        vm.stopPrank();
        console2.log("Unauthorized swap rejected");
    }

    function testRelayerCannotUndercutRequiredMinimum() public {
        uint256 minOut = _minOut(ONE_MILLION_RLUSD);
        uint256 rlBefore = rlusd.balanceOf(PROXY);
        uint256 usdBefore = usdc.balanceOf(PROXY);
        uint256 availableBefore = limits.getCurrentRateLimit(swapKey);
        assertGt(minOut, 0);

        vm.startPrank(RELAYER_SAFE);
        vm.expectRevert(bytes("MC/min-amount-not-met"));
        ctrl.swapCurve(POOL, 1, 0, ONE_MILLION_RLUSD, minOut - 1);
        vm.stopPrank();

        assertEq(rlusd.balanceOf(PROXY), rlBefore);
        assertEq(usdc.balanceOf(PROXY), usdBefore);
        assertEq(limits.getCurrentRateLimit(swapKey), availableBefore);
        console2.log("Relayer-supplied minOut below configured floor rejected");
    }

    function testRelayerCannotExceedLiveRateLimit() public {
        uint256 overLimit = FIVE_MILLION_RLUSD + 1e18;
        uint256 minOut = _minOut(overLimit);
        uint256 availableBefore = limits.getCurrentRateLimit(swapKey);
        assertLt(availableBefore, overLimit, "Live rate capacity changed; cannot test over-limit");
        uint256 rlBefore = rlusd.balanceOf(PROXY);
        uint256 usdBefore = usdc.balanceOf(PROXY);

        vm.startPrank(RELAYER_SAFE);
        vm.expectRevert(bytes("RateLimits/rate-limit-exceeded"));
        ctrl.swapCurve(POOL, 1, 0, overLimit, minOut);
        vm.stopPrank();

        assertEq(rlusd.balanceOf(PROXY), rlBefore);
        assertEq(usdc.balanceOf(PROXY), usdBefore);
        assertEq(limits.getCurrentRateLimit(swapKey), availableBefore);
        console2.log("Swap exceeding configured limit rejected");
    }

    function testCurvePoolRejectsOveroptimisticMinimumOut() public {
        uint256 quoted = pool.get_dy(1, 0, ONE_MILLION_RLUSD);
        uint256 required = _minOut(ONE_MILLION_RLUSD);
        assertGe(quoted, required, "Live quote below base minimum");
        uint256 beforeRL = rlusd.balanceOf(PROXY);
        uint256 beforeUSDC = usdc.balanceOf(PROXY);
        uint256 beforeLimit = limits.getCurrentRateLimit(swapKey);

        // Slightly more than Curve itself quotes for this exact fork state.
        vm.prank(RELAYER_SAFE);
        (bool ok, bytes memory revertData) = CONTROLLER.call(
            abi.encodeCall(
                ICurveSwapControllerLive.swapCurve,
                (POOL, 1, 0, ONE_MILLION_RLUSD, quoted + 1e6)
            )
        );
        console2.log("Overoptimistic Curve swap succeeded", ok);
        console2.log("Revert payload bytes", revertData.length);
        assertFalse(ok, "Unexpected: Curve accepted above-quote minimum");

        assertEq(rlusd.balanceOf(PROXY), beforeRL);
        assertEq(usdc.balanceOf(PROXY), beforeUSDC);
        assertEq(limits.getCurrentRateLimit(swapKey), beforeLimit);
        console2.log("Excessive minOut rejected, balances and limit unchanged");
    }
}
