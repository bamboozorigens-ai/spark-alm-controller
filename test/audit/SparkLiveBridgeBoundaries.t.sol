// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 374: verify the CURRENT deployed mainnet bridge route ceilings
// with a hypothetical COMPROMISED-but-authorized relayer, on a LOCAL fork.
// Tests intentionally exceed the live rate limits to get a revert BEFORE
// any USDC burn or LayerZero send. No transactions are broadcast.
import { Test } from "../../lib/forge-std/src/Test.sol";
import { console2 } from "../../lib/forge-std/src/console2.sol";
import { IRateLimits } from "../../src/interfaces/IRateLimits.sol";
import { RateLimitHelpers } from "../../src/RateLimitHelpers.sol";

interface IBridgeControllerBounds {
    function RELAYER() external view returns (bytes32);
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
    function LIMIT_USDC_TO_CCTP() external view returns (bytes32);
    function LIMIT_USDC_TO_DOMAIN() external view returns (bytes32);
    function LIMIT_LAYERZERO_TRANSFER() external view returns (bytes32);
    function transferUSDCToCCTP(uint256 amount, uint32 destinationDomain) external;
    function transferTokenLayerZero(address oft, uint256 amount, uint32 destinationEndpointId) external payable;
}

contract SparkLiveBridgeBoundaries is Test {
    address constant CONTROLLER = 0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant LIMITS = 0x7A5FD5cf045e010e62147F065cEAe59e5344b188;
    address constant USDT_OFT = 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee;
    uint32 constant DOMAIN_ARBITRUM = 3;
    uint32 constant DOMAIN_BASE = 6;
    uint32 constant DOMAIN_ETHEREUM = 0;
    uint32 constant LZ_EID_ARBITRUM = 30110;

    IBridgeControllerBounds ctrl;
    IRateLimits limits;
    address relayer;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        ctrl = IBridgeControllerBounds(CONTROLLER);
        limits = IRateLimits(LIMITS);

        bytes32 role = ctrl.RELAYER();
        uint256 count = ctrl.getRoleMemberCount(role);
        console2.log("Live RELAYER-role member count", count);
        require(count > 0, "No live RELAYER role member");
        relayer = ctrl.getRoleMember(role, 0);
        console2.log("Selected authorized relayer", relayer);
        assertTrue(limits.hasRole(limits.CONTROLLER(), CONTROLLER));
    }

    function _assertRevertedWithRateLimitError(bytes memory callData, string memory expected)
        internal
    {
        vm.prank(relayer);
        (bool success, bytes memory returned) = CONTROLLER.call(callData);
        console2.log("Call succeeded (must be false)", success);
        assertFalse(success, "SECURITY FINDING: blocked route unexpectedly succeeded");

        bytes memory expectedPayload = abi.encodeWithSignature("Error(string)", expected);
        assertEq(keccak256(returned), keccak256(expectedPayload), "Unexpected revert reason");
    }

    function _assertCctpDomainBounded(uint32 domain) internal {
        bytes32 key = RateLimitHelpers.makeUint32Key(ctrl.LIMIT_USDC_TO_DOMAIN(), domain);
        IRateLimits.RateLimitData memory data = limits.getRateLimitData(key);
        require(data.maxAmount > 0 && data.maxAmount < type(uint256).max,
            "CCTP domain not bounded by a finite value");

        uint256 availableBefore = limits.getCurrentRateLimit(key);
        uint256 aboveMaximum = data.maxAmount + 1;
        console2.log("CCTP domain", uint256(domain));
        console2.log("Maximum CCTP amount (micro-USDC)", data.maxAmount);
        console2.log("Available before (micro-USDC)", availableBefore);
        console2.log("Hypothetical forbidden amount (micro-USDC)", aboveMaximum);

        _assertRevertedWithRateLimitError(
            abi.encodeCall(IBridgeControllerBounds.transferUSDCToCCTP,
                (aboveMaximum, domain)),
            "RateLimits/rate-limit-exceeded"
        );

        uint256 availableAfter = limits.getCurrentRateLimit(key);
        assertEq(availableAfter, availableBefore, "Domain limit unexpectedly changed");
        console2.log("CCTP domain bound enforced, rate limit unchanged");
    }

    function testLiveCCTPArbitrumLimitExceededReverts() public {
        _assertCctpDomainBounded(DOMAIN_ARBITRUM);
    }

    function testLiveCCTPBaseLimitExceededReverts() public {
        _assertCctpDomainBounded(DOMAIN_BASE);
    }

    function testLiveCCTPEthereumDisabledDomainReverts() public {
        bytes32 key = RateLimitHelpers.makeUint32Key(
            ctrl.LIMIT_USDC_TO_DOMAIN(), DOMAIN_ETHEREUM
        );
        IRateLimits.RateLimitData memory data = limits.getRateLimitData(key);
        assertEq(data.maxAmount, 0, "CCTP Ethereum domain no longer disabled");
        console2.log("CCTP Ethereum domain maximum", data.maxAmount);

        _assertRevertedWithRateLimitError(
            abi.encodeCall(IBridgeControllerBounds.transferUSDCToCCTP,
                (1e6, DOMAIN_ETHEREUM)),
            "RateLimits/zero-maxAmount"
        );
        assertEq(limits.getCurrentRateLimit(key), 0);
        console2.log("Disabled CCTP domain rejected");
    }

    function testLiveLayerZeroArbitrumLimitExceededReverts() public {
        bytes32 key = keccak256(abi.encode(
            ctrl.LIMIT_LAYERZERO_TRANSFER(), USDT_OFT, LZ_EID_ARBITRUM
        ));
        IRateLimits.RateLimitData memory data = limits.getRateLimitData(key);
        require(data.maxAmount > 0 && data.maxAmount < type(uint256).max,
            "LayerZero route not bounded by finite amount");
        uint256 availableBefore = limits.getCurrentRateLimit(key);
        uint256 aboveMaximum = data.maxAmount + 1;
        console2.log("LayerZero maximum (micro-USDT)", data.maxAmount);
        console2.log("Hypothetical forbidden amount", aboveMaximum);

        _assertRevertedWithRateLimitError(
            abi.encodeCall(IBridgeControllerBounds.transferTokenLayerZero,
                (USDT_OFT, aboveMaximum, LZ_EID_ARBITRUM)),
            "RateLimits/rate-limit-exceeded"
        );
        assertEq(limits.getCurrentRateLimit(key), availableBefore);
        console2.log("LayerZero route bound enforced, rate limit unchanged");
    }
}
