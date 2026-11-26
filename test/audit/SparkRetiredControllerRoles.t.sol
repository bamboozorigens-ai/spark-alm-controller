// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 375: check whether the retired mainnet controller still holds
// ALMProxy/RateLimits CONTROLLER roles following deployment of V1.11.
// This is READ ONLY on a LOCAL fork. Does NOT send live transactions.
import { Test } from "../../lib/forge-std/src/Test.sol";
import { console2 } from "../../lib/forge-std/src/console2.sol";

interface IAccessRoleView {
    function CONTROLLER() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IHistoricalMainnetController {
    function proxy() external view returns (address);
    function rateLimits() external view returns (address);
    function RELAYER() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract SparkRetiredControllerRoles is Test {
    address constant NEW_CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    // Historical V1_10 controller, seen in 23 Nov 2026 executed swaps.
    address constant OLD_CONTROLLER = address(bytes20(hex"5c46fc65855c0c7465a1ea85eea0b24b601502d3"));
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant RELAYER = 0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;

    IAccessRoleView alm;
    IAccessRoleView limits;
    IHistoricalMainnetController newest;
    IHistoricalMainnetController retired;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        alm = IAccessRoleView(PROXY);
        limits = IAccessRoleView(LIMITS);
        newest = IHistoricalMainnetController(NEW_CONTROLLER);
        retired = IHistoricalMainnetController(OLD_CONTROLLER);
    }

    function testV111ControllerConfigurationMatchesLiveProxyAndLimits() public {
        console2.log("=== PASSO 375: NEW MAINNET CONTROLLER ===");
        console2.log("Fork block", block.number);
        assertEq(newest.proxy(), PROXY, "V1.11 controller references unexpected proxy");
        assertEq(newest.rateLimits(), LIMITS, "V1.11 controller references unexpected limits");
        assertTrue(alm.hasRole(alm.CONTROLLER(), NEW_CONTROLLER),
            "Current controller missing ALMProxy permission");
        assertTrue(limits.hasRole(limits.CONTROLLER(), NEW_CONTROLLER),
            "Current controller missing RateLimits permission");
        console2.log("Active controller authorized in both contracts");
    }

    function testRetiredControllerLacksAllCriticalRoles() public {
        console2.log("=== PASSO 375: RETIRED CONTROLLER REVOCATION ===");
        console2.log("Fork block", block.number);
        console2.log("Retired controller", OLD_CONTROLLER);
        console2.log("Current controller", NEW_CONTROLLER);
        console2.log("Retired historical proxy", retired.proxy());
        console2.log("Retired historical limits", retired.rateLimits());

        // Prove this is the retired controller for the SAME ALM system.
        assertEq(retired.proxy(), PROXY, "Historic controller uses a different proxy");
        assertEq(retired.rateLimits(), LIMITS, "Historic controller uses different limits");

        bool oldCanCallProxy = alm.hasRole(alm.CONTROLLER(), OLD_CONTROLLER);
        bool oldCanDecreaseLimit = limits.hasRole(limits.CONTROLLER(), OLD_CONTROLLER);
        console2.log("OLD controller authorized in ALMProxy", oldCanCallProxy);
        console2.log("OLD controller authorized in RateLimits", oldCanDecreaseLimit);

        // Old controller may retain its own RELAYER ACL and no longer matter
        // if it cannot reach ALMProxy/RateLimits.
        bool oldStillRecognizesRelayer = retired.hasRole(retired.RELAYER(), RELAYER);
        console2.log("OLD controller still recognizes same historical relayer",
            oldStillRecognizesRelayer);

        assertFalse(oldCanCallProxy,
            "SECURITY WARNING: OLD controller STILL HAS ALMProxy privileges");
        assertFalse(oldCanDecreaseLimit,
            "SECURITY WARNING: OLD controller STILL HAS RateLimits privileges");
        console2.log("Retired controller no longer holds critical permissions");
    }

    function testRetiredControllerCannotInvokeProxyEvenAsCaller() public {
        // A local impersonation proves access-control state, not an external attack.
        bytes memory payload = abi.encodeWithSignature(
            "doCall(address,bytes)",
            PROXY,
            abi.encodeWithSignature("CONTROLLER()")
        );
        vm.prank(OLD_CONTROLLER);
        (bool succeeded, bytes memory data) = PROXY.call(payload);
        console2.log("Direct ALMProxy call under OLD controller identity succeeded", succeeded);
        console2.log("Return/revert data bytes", data.length);
        assertFalse(succeeded, "SECURITY WARNING: old controller can still direct ALMProxy");
    }
}
