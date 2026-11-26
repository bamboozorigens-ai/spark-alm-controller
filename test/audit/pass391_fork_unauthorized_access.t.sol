// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 391: adversarial identity / authorization tests against REAL deployed
// contracts on a LOCAL Ethereum fork. No broadcast, no real approvals/transfers.
// An attacker address without special roles tries public controller and proxy
// entrypoints; any successful access is flagged as a security assertion failure.
import { Test } from "../../lib/forge-std/src/Test.sol";
import { console2 } from "../../lib/forge-std/src/console2.sol";

interface IRole391 {
    function RELAYER() external view returns (bytes32);
    function CONTROLLER() external view returns (bytes32);
    function hasRole(bytes32, address) external view returns (bool);
}
interface IERC20View391 {
    function balanceOf(address) external view returns (uint256);
}
interface IRateView391 {
    function LIMIT_ASSET_TRANSFER() external view returns (bytes32);
}
contract SparkForkUnauthorizedAccess391 is Test {
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant RATE_LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant ATTACKER = address(0xA771AC);
    bytes32 constant V4_POOL =
        0x9035721b23481db3888fd201b9c2b26dbc3af60258bca65e669f2ed98dc8eb4f;
    uint256 constant AMOUNT = 1_000e18;

    bytes32 relayerRole;
    bytes32 proxyControllerRole;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        relayerRole = IRole391(CONTROLLER).RELAYER();
        proxyControllerRole = IRole391(PROXY).CONTROLLER();
        assertFalse(IRole391(CONTROLLER).hasRole(relayerRole, ATTACKER), "Attacker is RELAYER unexpectedly");
        assertFalse(IRole391(PROXY).hasRole(proxyControllerRole, ATTACKER), "Attacker is PROXY CONTROLLER unexpectedly");
        assertGt(IERC20View391(RLUSD).balanceOf(PROXY), AMOUNT, "Insufficient live fork RLUSD");
        console2.log("PASSO 391 fork block", block.number);
        console2.log("Actual ALMProxy RLUSD units", IERC20View391(RLUSD).balanceOf(PROXY));
    }

    function _assertRevertWithRole(address target, bytes memory payload, bytes32 expectedRole) internal {
        uint256 beforeProxyRLUSD = IERC20View391(RLUSD).balanceOf(PROXY);
        uint256 beforeAttackerRLUSD = IERC20View391(RLUSD).balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        (bool ok, bytes memory reason) = target.call(payload);
        assertFalse(ok, "FINDING: unauthorized operation executed");
        bytes memory expected = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)", ATTACKER, expectedRole
        );
        assertEq(keccak256(reason), keccak256(expected), "Unexpected role-revert reason");
        assertEq(IERC20View391(RLUSD).balanceOf(PROXY), beforeProxyRLUSD,
                 "FINDING: ALMProxy RLUSD changed on unauthorized call");
        assertEq(IERC20View391(RLUSD).balanceOf(ATTACKER), beforeAttackerRLUSD,
                 "FINDING: attacker received funds");
    }

    function testAttackerCannotUseProxyGenericCall() public {
        bytes memory tokenTransfer = abi.encodeWithSignature("transfer(address,uint256)", ATTACKER, AMOUNT);
        bytes memory data = abi.encodeWithSignature("doCall(address,bytes)", RLUSD, tokenTransfer);
        _assertRevertWithRole(PROXY, data, proxyControllerRole);
        console2.log("Unauthorized ALMProxy.doCall blocked");
    }

    function testAttackerCannotUseProxyDelegatecall() public {
        bytes memory data = abi.encodeWithSignature("doDelegateCall(address,bytes)", ATTACKER, hex"");
        _assertRevertWithRole(PROXY, data, proxyControllerRole);
        console2.log("Unauthorized ALMProxy.doDelegateCall blocked");
    }

    function testAttackerCannotUseProxyCallWithValue() public {
        bytes memory tokenTransfer = abi.encodeWithSignature("transfer(address,uint256)", ATTACKER, AMOUNT);
        bytes memory data = abi.encodeWithSignature(
            "doCallWithValue(address,bytes,uint256)", RLUSD, tokenTransfer, uint256(0)
        );
        _assertRevertWithRole(PROXY, data, proxyControllerRole);
        console2.log("Unauthorized ALMProxy.doCallWithValue blocked");
    }

    function testAttackerCannotTransferAssetOrSwapCurve() public {
        _assertRevertWithRole(CONTROLLER, abi.encodeWithSignature(
            "transferAsset(address,address,uint256)", RLUSD, ATTACKER, AMOUNT
        ), relayerRole);
        _assertRevertWithRole(CONTROLLER, abi.encodeWithSignature(
            "swapCurve(address,uint256,uint256,uint256,uint256)",
            address(bytes20(hex"d001ae433f254283fece51d4acce8c53263aa186")),
            uint256(1), uint256(0), AMOUNT, uint256(999e6)
        ), relayerRole);
        console2.log("Unauthorized transfer and Curve swap blocked");
    }

    function testAttackerCannotSwapV4OrRedeemERC4626() public {
        _assertRevertWithRole(CONTROLLER, abi.encodeWithSignature(
            "swapUniswapV4(bytes32,address,uint128,uint128)",
            V4_POOL, RLUSD, uint128(1000e18), uint128(999e18)
        ), relayerRole);
        _assertRevertWithRole(CONTROLLER, abi.encodeWithSignature(
            "redeemERC4626(address,uint256,uint256)",
            SUSDS, uint256(1000e18), uint256(0)
        ), relayerRole);
        console2.log("Unauthorized V4 swap and ERC4626 redemption blocked");
    }

    function testAttackerCannotReconfigureRateLimits() public {
        bytes32 arbitraryKey=keccak256(abi.encode("SPARK_AUDIT_UNAUTHORIZED",ATTACKER));
        bytes memory data=abi.encodeWithSignature(
            "setRateLimitData(bytes32,uint256,uint256)", arbitraryKey, type(uint256).max, uint256(0)
        );
        vm.prank(ATTACKER);
        (bool ok,) = RATE_LIMITS.call(data);
        assertFalse(ok, "FINDING: unprivileged actor updated rate limit");
        console2.log("Unauthorized rate-limit configuration blocked");
    }

    function testAttackerCannotCallRateLimitDecrease() public {
        bytes32 key=keccak256(abi.encode(keccak256("LIMIT_UNISWAP_V4_SWAP"),V4_POOL));
        bytes memory data=abi.encodeWithSignature(
            "triggerRateLimitDecrease(bytes32,uint256)", key, uint256(1e18)
        );
        vm.prank(ATTACKER);
        (bool ok,) = RATE_LIMITS.call(data);
        assertFalse(ok, "FINDING: unprivileged actor decreased rate limit");
        console2.log("Unauthorized rate-limit mutation blocked");
    }
}
