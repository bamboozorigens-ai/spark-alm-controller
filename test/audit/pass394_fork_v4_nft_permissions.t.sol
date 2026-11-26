// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 394: adversarial access and NFT-pool identity boundaries.
// This is a LOCAL FORK test. Nothing is broadcast. The proxy's real NFT
// ownership/liquidity is read from latest; an artificial local transfer in
// one scenario is rolled back when the test ends.
import {Test} from "../../lib/forge-std/src/Test.sol";
import {console2} from "../../lib/forge-std/src/console2.sol";

interface IPosition394 {
    function ownerOf(uint256 id) external view returns (address);
    function getPositionLiquidity(uint256 id) external view returns (uint128);
    function transferFrom(address from,address to,uint256 id) external;
}
interface IController394 {
    function RELAYER() external view returns (bytes32);
    function hasRole(bytes32,address) external view returns (bool);
    function decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128) external;
    function increaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128) external;
}
interface IToken394 {
    function balanceOf(address) external view returns (uint256);
}
contract SparkForkV4NFTPermissions394 is Test {
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant RELAYER = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant ATTACKER = address(0x394394);
    bytes32 constant POOL =
        0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f;
    bytes32 constant WRONG_POOL =
        0xe63e32b2ae40601662f760d6bf5d771057324fbd97784fe1d3717069f7b75d45;
    uint256 constant NFT = 385168;

    IPosition394 manager;
    IController394 controller;
    bool usable;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        manager=IPosition394(POSITION_MANAGER);
        controller=IController394(CONTROLLER);
        assertTrue(controller.hasRole(controller.RELAYER(),RELAYER),"Production RELAYER not recognized");
        assertFalse(controller.hasRole(controller.RELAYER(),ATTACKER),"Test attacker unexpectedly privileged");
        address owner=manager.ownerOf(NFT);
        uint128 liq=manager.getPositionLiquidity(NFT);
        usable=(owner==PROXY && liq>2);
        console2.log("PASSO 394 fork block",block.number);
        console2.log("NFT owner",owner);
        console2.log("NFT liquidity",uint256(liq));
        if (!usable) console2.log("INCONCLUSIVE: historical NFT not active at current mainnet snapshot");
    }

    function _assertUnchanged(uint128 liqBefore,uint256 token0Before,uint256 token1Before) internal view {
        assertEq(manager.getPositionLiquidity(NFT),liqBefore,"FINDING: liquidity changed");
        assertEq(IToken394(RLUSD).balanceOf(PROXY),token0Before,"FINDING: RLUSD custody changed");
        assertEq(IToken394(USDS).balanceOf(PROXY),token1Before,"FINDING: USDS custody changed");
    }

    function testUnauthorizedNFTTransferFromALMProxy() public {
        if (!usable) return;
        vm.prank(ATTACKER);
        (bool ok,)=POSITION_MANAGER.call(abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",PROXY,ATTACKER,NFT
        ));
        assertFalse(ok,"FINDING: attacker moved Spark NFT");
        assertEq(manager.ownerOf(NFT),PROXY);
        console2.log("External NFT transfer without approval rejected");
    }

    function testUnprivilegedWithdrawalBlockedBeforeSettlement() public {
        if (!usable) return;
        uint128 beforeLiq=manager.getPositionLiquidity(NFT);
        uint256 rl=IToken394(RLUSD).balanceOf(PROXY);
        uint256 us=IToken394(USDS).balanceOf(PROXY);

        vm.prank(ATTACKER);
        (bool ok,bytes memory result)=CONTROLLER.call(abi.encodeWithSignature(
            "decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128)",
            POOL,NFT,uint128(beforeLiq/100),uint128(0),uint128(0)
        ));
        assertFalse(ok,"FINDING: unauthorized NFT withdrawal accepted");
        bytes memory expected=abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            ATTACKER,controller.RELAYER()
        );
        assertEq(keccak256(result),keccak256(expected),"Unexpected authorization revert");
        _assertUnchanged(beforeLiq,rl,us);
        console2.log("Unprivileged LP withdrawal rejected");
    }

    function testRelayerCannotSubstituteAnotherPoolId() public {
        if (!usable) return;
        uint128 beforeLiq=manager.getPositionLiquidity(NFT);
        uint256 rl=IToken394(RLUSD).balanceOf(PROXY);
        uint256 us=IToken394(USDS).balanceOf(PROXY);

        vm.prank(RELAYER);
        (bool ok,bytes memory reason)=CONTROLLER.call(abi.encodeWithSignature(
            "decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128)",
            WRONG_POOL,NFT,uint128(beforeLiq/100),uint128(0),uint128(0)
        ));
        assertFalse(ok,"FINDING: wrong-pool NFT withdrawal accepted");
        bytes memory expected=abi.encodeWithSignature(
            "Error(string)","MC/poolKey-poolId-mismatch"
        );
        assertEq(keccak256(reason),keccak256(expected),"Wrong-pool revert is unexpected");
        _assertUnchanged(beforeLiq,rl,us);
        console2.log("Wrong poolId blocked for existing NFT");
    }

    function testRelayerCannotIncreaseNFTNoLongerOwnedByProxy() public {
        if (!usable) return;
        uint256 rl=IToken394(RLUSD).balanceOf(PROXY);
        uint256 us=IToken394(USDS).balanceOf(PROXY);
        uint128 beforeLiq=manager.getPositionLiquidity(NFT);

        // Only on this fork: proxy transfers its NFT to the test attacker.
        // Subsequent controller call must reject because NFT owner != proxy.
        vm.prank(PROXY);
        manager.transferFrom(PROXY,ATTACKER,NFT);
        assertEq(manager.ownerOf(NFT),ATTACKER,"Local transfer scenario unavailable");

        vm.prank(RELAYER);
        (bool ok,bytes memory reason)=CONTROLLER.call(abi.encodeWithSignature(
            "increaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128)",
            POOL,NFT,uint128(1),uint128(1000e18),uint128(1000e18)
        ));
        assertFalse(ok,"FINDING: relayer increased external NFT using proxy funds");
        bytes memory expected=abi.encodeWithSignature("Error(string)","MC/non-proxy-position");
        assertEq(keccak256(reason),keccak256(expected),"Unexpected foreign-ownership revert");
        assertEq(manager.ownerOf(NFT),ATTACKER);
        _assertUnchanged(beforeLiq,rl,us);
        console2.log("Foreign-owned NFT cannot consume ALMProxy assets");
    }
}
