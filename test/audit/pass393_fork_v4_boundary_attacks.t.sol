// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 393: V4 RELAYER compromise model -- adversarial boundary challenges
// using REAL ALMProxy funds and production governance settings. LOCAL FORK ONLY.
// No mempool, no signing, no broadcasts, no real token transfers.
// These tests prove whether bad parameters can survive controller validation.
import { Test } from "../../lib/forge-std/src/Test.sol";
import { console2 } from "../../lib/forge-std/src/console2.sol";

interface IController393 {
    function RELAYER() external view returns (bytes32);
    function hasRole(bytes32,address) external view returns (bool);
    function LIMIT_UNISWAP_V4_SWAP() external view returns (bytes32);
    function maxSlippages(address) external view returns (uint256);
    function swapUniswapV4(bytes32 poolId,address tokenIn,uint128 amountIn,uint128 amountOutMin) external;
}
interface IERC20393 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address,address) external view returns (uint256);
    function transferFrom(address,address,uint256) external returns (bool);
}
interface IRateLimits393 {
    function getCurrentRateLimit(bytes32) external view returns (uint256);
}
contract SparkForkV4BoundaryAttacks393 is Test {
    address constant CONTROLLER=0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY=0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant RELAYER=0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant LIMITS=0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant RLUSD=0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant PYUSD=0x6c3ea9036406852006290770bedfcaba0e23a0e8;
    address constant USDS=0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ATTACKER=address(0xA771AC);

    bytes32 constant RLUSD_USDS_POOL=
        0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f;
    bytes32 constant PYUSD_USDS_POOL=
        0xe63e32b2ae40601662f760d6bf5d771057324fbd97784fe1d3717069f7b75d45;
    bytes32 constant DISABLED_USDC_USDT_POOL=
        0x8aa4e11cbdf30eedc92100f4c8a31ff748e201d44712cc8c90d189edaa8e4e47;

    IController393 ctrl;
    bytes32 swapRoot;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        ctrl=IController393(CONTROLLER);
        assertTrue(ctrl.hasRole(ctrl.RELAYER(),RELAYER),"Relayer role no longer present");
        assertFalse(ctrl.hasRole(ctrl.RELAYER(),ATTACKER),"Attacker unexpectedly privileged");
        assertGe(IERC20393(RLUSD).balanceOf(PROXY),5_000_001e18,"RLUSD balance changed");
        assertGe(IERC20393(PYUSD).balanceOf(PROXY),5_000_001e6,"PYUSD balance changed");
        swapRoot=ctrl.LIMIT_UNISWAP_V4_SWAP();
        console2.log("PASSO 393 fork block",block.number);
    }

    function _limit(bytes32 pool) internal view returns (uint256) {
        return IRateLimits393(LIMITS).getCurrentRateLimit(keccak256(abi.encode(swapRoot,pool)));
    }

    function _attempt(
        bytes32 pool,address tokenIn,uint128 amountIn,uint128 amountOutMin
    ) internal returns (bool ok,bytes memory data) {
        vm.prank(RELAYER);  // Only the LOCAL fork impersonates the relayer.
        (ok,data)=CONTROLLER.call(
            abi.encodeCall(IController393.swapUniswapV4,(pool,tokenIn,amountIn,amountOutMin))
        );
    }

    function _assertNoTokenLoss(
        uint256 rlusdBefore,uint256 pyusdBefore,uint256 usdsBefore
    ) internal view {
        assertEq(IERC20393(RLUSD).balanceOf(PROXY),rlusdBefore,"FINDING: RLUSD loss");
        assertEq(IERC20393(PYUSD).balanceOf(PROXY),pyusdBefore,"FINDING: PYUSD loss");
        assertEq(IERC20393(USDS).balanceOf(PROXY),usdsBefore,"FINDING: USDS movement");
    }

    function _assertOverCapBlocked(bytes32 pool,address tokenIn,uint128 amountIn) internal {
        uint256 beforeCapacity=_limit(pool);
        assertLt(beforeCapacity,uint256(amountIn)*1e18/(10**IERC20Decimals393(tokenIn).decimals()),
            "Pool capacity changed, not over cap");
        uint256 rlusdBefore=IERC20393(RLUSD).balanceOf(PROXY);
        uint256 pyusdBefore=IERC20393(PYUSD).balanceOf(PROXY);
        uint256 usdsBefore=IERC20393(USDS).balanceOf(PROXY);
        (bool ok,bytes memory revertPayload)=_attempt(pool,tokenIn,amountIn,0);
        assertFalse(ok,"FINDING: V4 swap bypassed rate limit");
        console2.log("Rejected over-cap V4 swap reason bytes",revertPayload.length);
        assertEq(_limit(pool),beforeCapacity,"FINDING: limit consumed by reverted swap");
        _assertNoTokenLoss(rlusdBefore,pyusdBefore,usdsBefore);
    }

    function testCompromisedRelayerCannotExceedRLUSDSwapLimit() public {
        _assertOverCapBlocked(RLUSD_USDS_POOL,RLUSD,uint128(5_000_001e18));
    }

    function testCompromisedRelayerCannotExceedPYUSDSwapLimit() public {
        _assertOverCapBlocked(PYUSD_USDS_POOL,PYUSD,uint128(5_000_001e6));
    }

    function _assertBelowFloorBlocked(bytes32 pool,address tokenIn,uint128 amount) internal {
        uint256 currentFloor=ctrl.maxSlippages(address(uint160(uint256(pool))));
        assertGt(currentFloor,0,"Pool slippage disabled");
        uint256 normalizedIn=uint256(amount)*1e18/(10**IERC20Decimals393(tokenIn).decimals());
        uint256 minOut=(normalizedIn*currentFloor/1e18)-1;
        uint256 rlusdBefore=IERC20393(RLUSD).balanceOf(PROXY);
        uint256 pyusdBefore=IERC20393(PYUSD).balanceOf(PROXY);
        uint256 usdsBefore=IERC20393(USDS).balanceOf(PROXY);
        uint256 beforeCapacity=_limit(pool);
        (bool ok,bytes memory reason)=_attempt(pool,tokenIn,amount,uint128(minOut));
        assertFalse(ok,"FINDING: controller bypassed minimum value floor");
        bytes memory expected=abi.encodeWithSignature(
            "Error(string)","MC/amountOutMin-too-low"
        );
        assertEq(keccak256(reason),keccak256(expected),"Unexpected min-output rejection");
        assertEq(_limit(pool),beforeCapacity,"FINDING: rate limit changed on reverted swap");
        _assertNoTokenLoss(rlusdBefore,pyusdBefore,usdsBefore);
    }

    function testRelayerCannotUndercutRLUSDFloor() public {
        _assertBelowFloorBlocked(RLUSD_USDS_POOL,RLUSD,uint128(1000e18));
    }

    function testRelayerCannotUndercutPYUSDFloor() public {
        _assertBelowFloorBlocked(PYUSD_USDS_POOL,PYUSD,uint128(1000e6));
    }

    function testUnconfiguredPoolRejected() public {
        assertEq(ctrl.maxSlippages(address(uint160(uint256(DISABLED_USDC_USDT_POOL))),0,
                 "Previously disabled test pool is now enabled");
        uint256 before=IERC20393(RLUSD).balanceOf(PROXY);
        (bool success,bytes memory reason)=_attempt(
            DISABLED_USDC_USDT_POOL,RLUSD,uint128(1000e18),0
        );
        assertFalse(success,"FINDING: disabled V4 pool accepted");
        bytes memory expected=abi.encodeWithSignature(
            "Error(string)","MC/max-slippage-not-set"
        );
        assertEq(keccak256(reason),keccak256(expected),"Unexpected disabled-pool revert");
        assertEq(IERC20393(RLUSD).balanceOf(PROXY),before);
        console2.log("Disabled V4 pool rejected");
    }

    function testOutsiderCannotTransferFromProxyDirectly() public {
        uint256 beforeProxy=IERC20393(RLUSD).balanceOf(PROXY);
        uint256 beforeAttacker=IERC20393(RLUSD).balanceOf(ATTACKER);
        assertEq(IERC20393(RLUSD).allowance(PROXY,ATTACKER),0,
                 "Unexpected outside ERC20 allowance; investigate");
        vm.prank(ATTACKER);
        (bool success,bytes memory result)=RLUSD.call(abi.encodeCall(
            IERC20393.transferFrom,(PROXY,ATTACKER,1_000e18)
        ));
        bool returnedTrue=(success&&result.length==32&&abi.decode(result,(bool)));
        assertFalse(returnedTrue,"FINDING: external transferFrom succeeded");
        assertEq(IERC20393(RLUSD).balanceOf(PROXY),beforeProxy);
        assertEq(IERC20393(RLUSD).balanceOf(ATTACKER),beforeAttacker);
        console2.log("Outsider token transferFrom denied");
    }

    function testAuthorizedRelayerSwapKeepsProceedsInProxy() public {
        uint128 amount=uint128(1_000e18);
        uint128 floor=uint128(999e18);
        assertGe(_limit(RLUSD_USDS_POOL),uint256(amount),"Insufficient current V4 rate limit");
        uint256 beforeRLUSD=IERC20393(RLUSD).balanceOf(PROXY);
        uint256 beforeUSDS=IERC20393(USDS).balanceOf(PROXY);
        uint256 beforeAttacker=IERC20393(USDS).balanceOf(ATTACKER);
        uint256 beforeLimit=_limit(RLUSD_USDS_POOL);

        (bool ok,bytes memory reason)=_attempt(RLUSD_USDS_POOL,RLUSD,amount,floor);
        if (!ok) {
            console2.log("Authorized swap on fork rejected; payload length",reason.length);
            revert("FORK_SWAP_NOT_EXECUTABLE_AT_THIS_SNAPSHOT");
        }
        uint256 afterRLUSD=IERC20393(RLUSD).balanceOf(PROXY);
        uint256 afterUSDS=IERC20393(USDS).balanceOf(PROXY);
        uint256 afterLimit=_limit(RLUSD_USDS_POOL);
        assertEq(beforeRLUSD-afterRLUSD,uint256(amount),"FINDING: RLUSD spent mismatch");
        assertGe(afterUSDS-beforeUSDS,uint256(floor),"FINDING: below-floor settlement");
        assertEq(beforeLimit-afterLimit,uint256(amount),"FINDING: rate-limit accounting mismatch");
        assertEq(IERC20393(USDS).balanceOf(ATTACKER),beforeAttacker,
                 "FINDING: outsider received swap proceeds");
        console2.log("Authorized fork swap RLUSD used",uint256(amount));
        console2.log("Authorized fork swap USDS credited",afterUSDS-beforeUSDS);
        console2.log("Unauthorized PnL USDS",IERC20393(USDS).balanceOf(ATTACKER)-beforeAttacker);
    }
}

interface IERC20Decimals393 {
    function decimals() external view returns (uint8);
}
