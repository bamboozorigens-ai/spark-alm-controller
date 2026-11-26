// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 395: local fork adverse V4 LP exits using a REAL existing Spark NFT.
// Vary minimums, challenge atomic rollback, and inspect actual token custody.
// The only "victim" execution is vm.prank(RELAYER) INSIDE the local fork;
// neither funds nor transactions go to Ethereum mainnet.
import {Test} from "../../lib/forge-std/src/Test.sol";
import {console2} from "../../lib/forge-std/src/console2.sol";

interface IPos395 {
    function ownerOf(uint256) external view returns (address);
    function getPositionLiquidity(uint256) external view returns (uint128);
}
interface ICont395 {
    function RELAYER() external view returns (bytes32);
    function hasRole(bytes32,address) external view returns (bool);
    function LIMIT_UNISWAP_V4_WITHDRAW() external view returns (bytes32);
    function decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128) external;
}
interface IERC20395 {
    function balanceOf(address) external view returns (uint256);
}
interface IRate395 {
    function getCurrentRateLimit(bytes32) external view returns (uint256);
}
contract SparkForkV4LPExitAccounting395 is Test {
    address constant PROXY=0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant CONTROLLER=0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant RELAYER=0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant LIMITS=0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant POSITION_MANAGER=0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant RLUSD=0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant USDS=0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant ATTACKER=address(0x395395);
    bytes32 constant POOL=0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f;
    uint256 constant NFT=385168;

    IPos395 pos;
    ICont395 controller;
    uint128 liquidityBefore;
    uint128 portion;
    bool usable;
    bytes32 withdrawKey;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        pos=IPos395(POSITION_MANAGER);
        controller=ICont395(CONTROLLER);
        assertTrue(controller.hasRole(controller.RELAYER(),RELAYER),"Not the configured RELAYER");
        liquidityBefore=pos.getPositionLiquidity(NFT);
        usable=pos.ownerOf(NFT)==PROXY && liquidityBefore>100;
        if (usable) portion=liquidityBefore/100;
        withdrawKey=keccak256(abi.encode(controller.LIMIT_UNISWAP_V4_WITHDRAW(),POOL));
        console2.log("PASSO 395 live fork block",block.number);
        console2.log("Existing NFT liquidity",uint256(liquidityBefore));
        if (!usable) console2.log("INCONCLUSIVE: known NFT no longer held by ALMProxy");
    }

    function _balances() internal view returns (uint256 rl,uint256 us) {
        return (IERC20395(RLUSD).balanceOf(PROXY),IERC20395(USDS).balanceOf(PROXY));
    }

    function _exit(uint128 q,uint128 min0,uint128 min1) internal returns (bool ok,bytes memory reason) {
        vm.prank(RELAYER);
        (ok,reason)=CONTROLLER.call(abi.encodeWithSignature(
            "decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128)",
            POOL,NFT,q,min0,min1
        ));
    }

    function _assertNoExternalPayout(uint256 rlBefore,uint256 usBefore) internal view {
        assertEq(IERC20395(RLUSD).balanceOf(ATTACKER),rlBefore,
                 "FINDING: outsider received RLUSD");
        assertEq(IERC20395(USDS).balanceOf(ATTACKER),usBefore,
                 "FINDING: outsider received USDS");
    }

    function testZeroMinimumLPExitKeepsFundsInALMProxy() public {
        if (!usable) return;
        (uint256 beforeRL,uint256 beforeUS)=_balances();
        uint256 attackerRL=IERC20395(RLUSD).balanceOf(ATTACKER);
        uint256 attackerUS=IERC20395(USDS).balanceOf(ATTACKER);
        uint256 capBefore=IRate395(LIMITS).getCurrentRateLimit(withdrawKey);

        (bool ok,bytes memory reason)=_exit(portion,0,0);
        if (!ok) {
            console2.log("LP exit failed; revert payload bytes",reason.length);
            revert("INCONCLUSIVE_LP_EXIT_NOT_EXECUTABLE_AT_SNAPSHOT");
        }
        (uint256 afterRL,uint256 afterUS)=_balances();
        uint256 receivedRL=afterRL-beforeRL;
        uint256 receivedUS=afterUS-beforeUS;
        assertGt(receivedRL+receivedUS,0,"FINDING: no assets delivered after liquidity burn");
        assertEq(uint256(liquidityBefore-pos.getPositionLiquidity(NFT)),uint256(portion),
                 "FINDING: unexpected position burn");
        _assertNoExternalPayout(attackerRL,attackerUS);

        uint256 capAfter=IRate395(LIMITS).getCurrentRateLimit(withdrawKey);
        assertLe(capAfter,capBefore,"FINDING: withdrawal cap unexpectedly increased");
        console2.log("Real NFT liquidity removed",uint256(portion));
        console2.log("RLUSD paid into ALMProxy",receivedRL);
        console2.log("USDS paid into ALMProxy",receivedUS);
        console2.log("Outside attacker received 0 tokens");
        console2.log("Withdraw capacity before",capBefore);
        console2.log("Withdraw capacity after",capAfter);
    }

    function testOveroptimisticAmountsRevertAndRollback() public {
        if (!usable) return;
        uint256 beforeLiq=pos.getPositionLiquidity(NFT);
        (uint256 beforeRL,uint256 beforeUS)=_balances();
        uint256 capBefore=IRate395(LIMITS).getCurrentRateLimit(withdrawKey);
        uint256 snapshot=vm.snapshotState();

        (bool baselineOk,)=_exit(portion,0,0);
        if (!baselineOk) revert("INCONCLUSIVE_BASELINE_LP_EXIT_FAILED");
        (uint256 afterRL,uint256 afterUS)=_balances();
        uint256 deltaRL=afterRL-beforeRL;
        uint256 deltaUS=afterUS-beforeUS;
        assertGt(deltaRL+deltaUS,0,"Cannot determine executable baseline");
        assertLt(deltaRL,type(uint128).max,"RLUSD baseline exceeds uint128");
        assertLt(deltaUS,type(uint128).max,"USDS baseline exceeds uint128");
        vm.revertToState(snapshot);

        (bool strictOk,bytes memory strictReason)=_exit(
            portion,uint128(deltaRL+1),uint128(deltaUS)
        );
        console2.log("Overoptimistic minimum LP exit success",strictOk);
        console2.log("Revert payload length",strictReason.length);
        assertFalse(strictOk,"FINDING: exit accepted more than deterministic baseline");
        assertEq(pos.getPositionLiquidity(NFT),beforeLiq,"FINDING: liquidity lost on reverted exit");
        (uint256 finalRL,uint256 finalUS)=_balances();
        assertEq(finalRL,beforeRL,"FINDING: RLUSD custody changed on revert");
        assertEq(finalUS,beforeUS,"FINDING: USDS custody changed on revert");
        assertEq(IRate395(LIMITS).getCurrentRateLimit(withdrawKey),capBefore,
                 "FINDING: withdrawal cap consumed on revert");
        console2.log("Adversarial minimum-out rejected atomically");
    }

    function testCannotWithdrawMoreLiquidityThanNFTContains() public {
        if (!usable) return;
        assertLt(uint256(liquidityBefore),type(uint128).max,"Liquidity unexpected maximum");
        (uint256 beforeRL,uint256 beforeUS)=_balances();
        uint256 beforeCap=IRate395(LIMITS).getCurrentRateLimit(withdrawKey);
        (bool ok,bytes memory reason)=_exit(liquidityBefore+1,0,0);
        assertFalse(ok,"FINDING: removed more liquidity than owned");
        assertEq(pos.getPositionLiquidity(NFT),liquidityBefore);
        (uint256 afterRL,uint256 afterUS)=_balances();
        assertEq(beforeRL,afterRL);
        assertEq(beforeUS,afterUS);
        assertEq(IRate395(LIMITS).getCurrentRateLimit(withdrawKey),beforeCap);
        console2.log("Over-withdrawal rejected; revert payload bytes",reason.length);
    }
}
