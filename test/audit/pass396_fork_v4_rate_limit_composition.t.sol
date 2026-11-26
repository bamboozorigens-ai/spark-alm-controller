// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 396: stateful adversarial rate-limit composition and cross-pool isolation
// with real Spark token balances, solely on an isolated local mainnet fork.
// No live transactions, signing, or remote value movement.
import {Test} from "../../lib/forge-std/src/Test.sol";
import {console2} from "../../lib/forge-std/src/console2.sol";

interface IController396 {
    function RELAYER() external view returns (bytes32);
    function hasRole(bytes32,address) external view returns (bool);
    function LIMIT_UNISWAP_V4_SWAP() external view returns (bytes32);
    function swapUniswapV4(bytes32,address,uint128,uint128) external;
}
interface IRateLimits396 {
    function getCurrentRateLimit(bytes32) external view returns (uint256);
}
interface IToken396 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address,address) external view returns (uint256);
}
contract SparkForkV4RateLimitComposition396 is Test {
    address constant CONTROLLER=0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY=0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant LIMITS=0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant RELAYER=0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ATTACKER=address(0x396396);
    address constant RLUSD=0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant PYUSD=address(bytes20(hex"6c3ea9036406852006290770bedfcaba0e23a0e8"));
    address constant USDS=0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    bytes32 constant RLUSD_USDS_POOL=
        0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f;
    bytes32 constant PYUSD_USDS_POOL=
        0xe63e32b2ae40601662f760d6bf5d771057324fbd97784fe1d3717069f7b75d45;

    IController396 controller;
    bytes32 root;
    uint256 constant FIVE_MILLION=5_000_000e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        controller=IController396(CONTROLLER);
        assertTrue(controller.hasRole(controller.RELAYER(),RELAYER),"Relayer unavailable");
        assertFalse(controller.hasRole(controller.RELAYER(),ATTACKER),"Attacker already RELAYER");
        root=controller.LIMIT_UNISWAP_V4_SWAP();
        assertEq(_cap(RLUSD_USDS_POOL),FIVE_MILLION,"RLUSD pool rate cap changed");
        assertEq(_cap(PYUSD_USDS_POOL),FIVE_MILLION,"PYUSD pool rate cap changed");
        assertGe(IToken396(RLUSD).balanceOf(PROXY),FIVE_MILLION,"Insufficient RLUSD");
        assertGe(IToken396(PYUSD).balanceOf(PROXY),5_000_000e6,"Insufficient PYUSD");
        console2.log("PASSO 396 live fork block",block.number);
    }

    function _cap(bytes32 pool) internal view returns (uint256) {
        return IRateLimits396(LIMITS).getCurrentRateLimit(keccak256(abi.encode(root,pool)));
    }

    function _swap(bytes32 pool,address tokenIn,uint128 amount,uint128 minimum) internal
        returns (bool success,bytes memory reason)
    {
        vm.prank(RELAYER);
        (success,reason)=CONTROLLER.call(abi.encodeWithSignature(
            "swapUniswapV4(bytes32,address,uint128,uint128)",
            pool,tokenIn,amount,minimum
        ));
    }

    function _strictSwap(bytes32 pool,address tokenIn,uint128 amount,uint128 minimum) internal {
        (bool ok,bytes memory reason)=_swap(pool,tokenIn,amount,minimum);
        if (!ok) {
            console2.log("Expected executable authorized swap rejected; bytes",reason.length);
            revert("INCONCLUSIVE_SWAP_NOT_EXECUTABLE_AT_SNAPSHOT");
        }
    }

    function testSequentialSwapsConsumeCombinedRLUSDCapExactly() public {
        uint256 beforeRL=IToken396(RLUSD).balanceOf(PROXY);
        uint256 beforeUS=IToken396(USDS).balanceOf(PROXY);
        uint256 outsiderUS=IToken396(USDS).balanceOf(ATTACKER);
        assertEq(_cap(RLUSD_USDS_POOL),FIVE_MILLION);

        _strictSwap(RLUSD_USDS_POOL,RLUSD,uint128(2_000_000e18),uint128(1_998_000e18));
        assertEq(_cap(RLUSD_USDS_POOL),3_000_000e18,"FINDING: bad limit after first swap");

        _strictSwap(RLUSD_USDS_POOL,RLUSD,uint128(2_000_000e18),uint128(1_998_000e18));
        assertEq(_cap(RLUSD_USDS_POOL),1_000_000e18,"FINDING: limit not conserved");

        _strictSwap(RLUSD_USDS_POOL,RLUSD,uint128(1_000_000e18),uint128(999_000e18));
        assertEq(_cap(RLUSD_USDS_POOL),0,"FINDING: capacity regenerated inside same block");
        assertEq(beforeRL-IToken396(RLUSD).balanceOf(PROXY),FIVE_MILLION,
                 "FINDING: input debit != rate limit consumption");
        assertGe(IToken396(USDS).balanceOf(PROXY)-beforeUS,4_995_000e18,
                 "FINDING: cumulative output below promised minimum");
        assertEq(IToken396(USDS).balanceOf(ATTACKER),outsiderUS,
                 "FINDING: outside attacker received USDS");
        assertEq(IToken396(RLUSD).allowance(PROXY,PERMIT2),0,
                 "FINDING: leftover RLUSD Permit2 allowance after swaps");

        uint256 prevRL=IToken396(RLUSD).balanceOf(PROXY);
        uint256 prevUS=IToken396(USDS).balanceOf(PROXY);
        (bool ok,bytes memory reason)=_swap(
            RLUSD_USDS_POOL,RLUSD,uint128(1e18),uint128(999e15)
        );
        assertFalse(ok,"FINDING: zero-cap swap accepted");
        bytes memory expected=abi.encodeWithSignature(
            "Error(string)","RateLimits/rate-limit-exceeded"
        );
        assertEq(keccak256(reason),keccak256(expected),"Unexpected zero-cap error");
        assertEq(_cap(RLUSD_USDS_POOL),0);
        assertEq(IToken396(RLUSD).balanceOf(PROXY),prevRL);
        assertEq(IToken396(USDS).balanceOf(PROXY),prevUS);
        console2.log("Consecutive 5M RLUSD swaps used full limit, sixth swap rejected");
    }

    function testTwoDifferentPoolsDoNotShareSameRateLimitBucket() public {
        uint256 initialRL=IToken396(RLUSD).balanceOf(PROXY);
        uint256 initialPY=IToken396(PYUSD).balanceOf(PROXY);
        uint256 initialUS=IToken396(USDS).balanceOf(PROXY);
        uint256 outside=IToken396(USDS).balanceOf(ATTACKER);
        uint256 rlusdCap=_cap(RLUSD_USDS_POOL);
        uint256 pyusdCap=_cap(PYUSD_USDS_POOL);

        _strictSwap(RLUSD_USDS_POOL,RLUSD,uint128(1_000_000e18),uint128(999_000e18));
        assertEq(rlusdCap-_cap(RLUSD_USDS_POOL),1_000_000e18);
        assertEq(_cap(PYUSD_USDS_POOL),pyusdCap,
                 "FINDING: RLUSD route illegally affected PYUSD bucket");

        _strictSwap(PYUSD_USDS_POOL,PYUSD,uint128(1_000_000e6),uint128(999_000e18));
        assertEq(pyusdCap-_cap(PYUSD_USDS_POOL),1_000_000e18);
        assertEq(rlusdCap-_cap(RLUSD_USDS_POOL),1_000_000e18);
        assertEq(initialRL-IToken396(RLUSD).balanceOf(PROXY),1_000_000e18);
        assertEq(initialPY-IToken396(PYUSD).balanceOf(PROXY),1_000_000e6);
        assertGe(IToken396(USDS).balanceOf(PROXY)-initialUS,1_998_000e18);
        assertEq(IToken396(USDS).balanceOf(ATTACKER),outside);
        console2.log("Separate RLUSD/PYUSD rate buckets respected");
    }

    function testWrongTokenCannotConsumeAnotherPoolLimit() public {
        uint256 beforeRL=IToken396(RLUSD).balanceOf(PROXY);
        uint256 beforePY=IToken396(PYUSD).balanceOf(PROXY);
        uint256 beforeUS=IToken396(USDS).balanceOf(PROXY);
        uint256 capacity=_cap(PYUSD_USDS_POOL);

        (bool ok,bytes memory reason)=_swap(
            PYUSD_USDS_POOL,RLUSD,uint128(1_000e18),uint128(999e18)
        );
        assertFalse(ok,"FINDING: V4 pool accepted token not in its PoolKey");
        bytes memory expected=abi.encodeWithSignature("Error(string)","MC/invalid-tokenIn");
        assertEq(keccak256(reason),keccak256(expected),"Unexpected invalid input revert");
        assertEq(_cap(PYUSD_USDS_POOL),capacity);
        assertEq(IToken396(RLUSD).balanceOf(PROXY),beforeRL);
        assertEq(IToken396(PYUSD).balanceOf(PROXY),beforePY);
        assertEq(IToken396(USDS).balanceOf(PROXY),beforeUS);
        console2.log("Cross-pool input substitution blocked atomically");
    }
}
