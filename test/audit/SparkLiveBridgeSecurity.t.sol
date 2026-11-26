// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 370 - Read-only state checks on a LIVE Ethereum mainnet fork.
// The live fork is local. No state change is broadcast to mainnet.
// This is a configuration/access-control check, NOT an exploit claim.
import {Test} from "../../lib/forge-std/src/Test.sol";
import {console2} from "../../lib/forge-std/src/console2.sol";
import {IRateLimits} from "../../src/interfaces/IRateLimits.sol";
import {RateLimitHelpers} from "../../src/RateLimitHelpers.sol";

interface ISparkBridgeControllerRead {
    function proxy() external view returns (address);
    function rateLimits() external view returns (address);
    function usdc() external view returns (address);
    function cctp() external view returns (address);
    function cctpMaxFeeRate() external view returns (uint256);
    function mintRecipients(uint32 destinationDomain) external view returns (bytes32);
    function layerZeroRecipients(uint32 destinationEndpointId) external view returns (bytes32);
    function LIMIT_USDC_TO_CCTP() external view returns (bytes32);
    function LIMIT_USDC_TO_DOMAIN() external view returns (bytes32);
    function LIMIT_LAYERZERO_TRANSFER() external view returns (bytes32);
    function RELAYER() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function transferUSDCToCCTP(uint256 amount, uint32 domain) external;
    function transferTokenLayerZero(address oft, uint256 amount, uint32 endpointId) external payable;
}
contract SparkLiveBridgeSecurity is Test {
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT_OFT = 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee;

    uint32 constant CCTP_DOMAIN_ETHEREUM = 0;
    uint32 constant CCTP_DOMAIN_ARBITRUM = 3;
    uint32 constant CCTP_DOMAIN_BASE = 6;
    uint32 constant LZ_ARBITRUM_EID = 30110;
    address constant UNAUTHORIZED = address(0xBEEF);

    ISparkBridgeControllerRead ctrl;
    IRateLimits limits;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        ctrl = ISparkBridgeControllerRead(CONTROLLER);
        limits = IRateLimits(LIMITS);
    }

    function _printLimit(bytes32 key, string memory label_) internal view {
        IRateLimits.RateLimitData memory data = limits.getRateLimitData(key);
        console2.log(label_);
        console2.logBytes32(key);
        console2.log("Max allowed native token units", data.maxAmount);
        console2.log("Regeneration per second", data.slope);
        console2.log("Currently available", limits.getCurrentRateLimit(key));
    }

    function testLiveBridgeConfigurationAndRates() public {
        console2.log("=== PASSO 370: REAL LIVE BRIDGE CONFIGURATION ===");
        console2.log("Fork block", block.number);
        console2.log("Controller", CONTROLLER);
        assertEq(ctrl.proxy(), PROXY, "Unexpected proxy");
        assertEq(ctrl.rateLimits(), LIMITS, "Unexpected rateLimits");
        assertEq(ctrl.usdc(), USDC, "Unexpected USDC token");
        console2.log("Live CCTP messenger", ctrl.cctp());
        console2.log("CCTP maximum fee rate in basis points", ctrl.cctpMaxFeeRate());
        assertLt(ctrl.cctpMaxFeeRate(), 10_000, "CCTP fee cap out of bound");

        bytes32 totalKey = ctrl.LIMIT_USDC_TO_CCTP();
        _printLimit(totalKey, "USDC to CCTP: global outgoing limit");
        uint32[3] memory domains = [
            CCTP_DOMAIN_ETHEREUM, CCTP_DOMAIN_ARBITRUM, CCTP_DOMAIN_BASE
        ];
        for (uint256 i; i < domains.length; ++i) {
            uint32 domain = domains[i];
            bytes32 key = RateLimitHelpers.makeUint32Key(
                ctrl.LIMIT_USDC_TO_DOMAIN(), domain
            );
            console2.log("Destination CCTP domain", uint256(domain));
            console2.log("Recipient:");
            console2.logBytes32(ctrl.mintRecipients(domain));
            _printLimit(key, "Per-domain CCTP outbound limit");
        }

        console2.log("LayerZero OFT", USDT_OFT);
        console2.log("LayerZero Arbitrum recipient:");
        console2.logBytes32(ctrl.layerZeroRecipients(LZ_ARBITRUM_EID));
        bytes32 lzKey = keccak256(
            abi.encode(ctrl.LIMIT_LAYERZERO_TRANSFER(), USDT_OFT, LZ_ARBITRUM_EID)
        );
        _printLimit(lzKey, "USDT OFT to Arbitrum: configured native-unit limit");

        bytes32 relayerRole = ctrl.RELAYER();
        console2.log("Unknown actor is relayer", ctrl.hasRole(relayerRole, UNAUTHORIZED));
        assertFalse(ctrl.hasRole(relayerRole, UNAUTHORIZED), "Audit actor somehow has RELAYER");
        assertTrue(limits.hasRole(limits.CONTROLLER(), CONTROLLER), "Controller unauthorized in RateLimits");
        console2.log("Only read actions executed on fork");
    }

    function testUnauthorizedCallerCannotBridge() public {
        vm.expectRevert();
        vm.prank(UNAUTHORIZED);
        ctrl.transferUSDCToCCTP(1e6, CCTP_DOMAIN_BASE);
        console2.log("Unauthorized CCTP caller rejected");

        vm.expectRevert();
        vm.prank(UNAUTHORIZED);
        ctrl.transferTokenLayerZero(USDT_OFT, 1e6, LZ_ARBITRUM_EID);
        console2.log("Unauthorized LayerZero caller rejected");

        // RateLimits is checked separately below via a raw call. This avoids
        // false conclusions from an ambiguous vm.expectRevert() mismatch.
    }

    // PASSO 372: distinguish actual unauthorized access from an expectation
    // mismatch. Unlike vm.expectRevert(), a low-level call exposes the real
    // EVM success flag and revert data for explicit assertions.
    function testUnauthorizedRateLimitDirectCall() public {
        console2.log("=== PASSO 372: VERIFY RATELIMITS AUTHORIZATION DIRECTLY ===");
        console2.log("Fork block", block.number);
        bytes32 controllerRole = limits.CONTROLLER();
        bytes32 globalKey = ctrl.LIMIT_USDC_TO_CCTP();

        bool auditActorAuthorized = limits.hasRole(controllerRole, UNAUTHORIZED);
        bool currentControllerAuthorized = limits.hasRole(controllerRole, CONTROLLER);
        console2.log("Unauthorized address has CONTROLLER role", auditActorAuthorized);
        console2.log("Official Spark controller has CONTROLLER role", currentControllerAuthorized);
        assertFalse(auditActorAuthorized, "UNEXPECTED: test actor has RateLimits CONTROLLER role");
        assertTrue(currentControllerAuthorized, "Official controller missing RateLimits role");

        uint256 rateBefore = limits.getCurrentRateLimit(globalKey);
        console2.log("Global CCTP limit before", rateBefore);

        vm.startPrank(UNAUTHORIZED);
        (bool callSucceeded, bytes memory returnData) = address(limits).call(
            abi.encodeCall(IRateLimits.triggerRateLimitDecrease, (globalKey, 1))
        );
        vm.stopPrank();

        console2.log("Unauthorized RateLimits call success", callSucceeded);
        console2.log("Revert data bytes", returnData.length);
        console2.logBytes(returnData);
        assertFalse(callSucceeded, "SECURITY FINDING: unauthorized actor changed a rate limit");

        // OpenZeppelin AccessControlUnauthorizedAccount(address,bytes32)
        bytes4 revertSelector;
        address rejectedActor;
        bytes32 requiredRole;
        if (returnData.length >= 68) {
            assembly {
                revertSelector := mload(add(returnData, 0x20))
                rejectedActor := mload(add(returnData, 0x24))
                requiredRole := mload(add(returnData, 0x44))
            }
            console2.logBytes4(revertSelector);
            console2.log("Rejected caller extracted from revert", rejectedActor);
            console2.log("Role required in revert:");
            console2.logBytes32(requiredRole);
            assertEq(
                revertSelector,
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                "Unexpected revert reason"
            );
            assertEq(rejectedActor, UNAUTHORIZED, "Unexpected rejected actor");
            assertEq(requiredRole, controllerRole, "Unexpected required role");
        } else {
            revert("Missing AccessControlUnauthorizedAccount revert payload");
        }

        uint256 rateAfter = limits.getCurrentRateLimit(globalKey);
        assertEq(rateAfter, rateBefore, "Rate limit was modified by unauthorized call");
        console2.log("RateLimit unchanged; unauthorized call correctly rejected");
    }
}
