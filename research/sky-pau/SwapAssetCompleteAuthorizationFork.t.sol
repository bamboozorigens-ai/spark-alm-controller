// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";
import { IAccessControl } from "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { IRateLimits } from "../../src/interfaces/IRateLimits.sol";
import { IERC20Like, SwapAsset_TestBase } from "../mainnet-fork/SwapAsset.t.sol";

contract SwapAssetCallRelay {
    function invoke(address target, bytes calldata data) external returns (bool, bytes memory) {
        return target.call(data);
    }
}

contract SwapAssetCompleteAuthorizationFork is SwapAsset_TestBase {
    function test_unknownCounterpartyCannotCompleteSwapOrChangeProxyBalances() external {
        SwapAssetCallRelay relay = new SwapAssetCallRelay();

        deal(Ethereum.USDS, address(almProxy), 10_000e18);
        deal(Ethereum.USDT, address(almProxy), 10_000e6);

        uint256 usdsBefore = IERC20Like(Ethereum.USDS).balanceOf(address(almProxy));
        uint256 usdtBefore = IERC20Like(Ethereum.USDT).balanceOf(address(almProxy));

        bytes32 unconfiguredKey = mainnetController.swapAsset_getCompleteSwapRateLimitKey(
            Ethereum.USDS,
            address(relay),
            Ethereum.USDT
        );
        assertEq(rateLimits.getRateLimitData(unconfiguredKey).maxAmount, 0);

        (bool success, bytes memory reason) = relay.invoke(
            address(mainnetController),
            abi.encodeWithSignature(
                "swapAsset_completeSwap(address,address,uint256)",
                Ethereum.USDS,
                Ethereum.USDT,
                1_000e18
            )
        );

        assertFalse(success, "unconfigured counterparty unexpectedly completed a swap");
        assertEq(
            keccak256(reason),
            keccak256(abi.encodeWithSignature("Error(string)", "RateLimits/zero-maxAmount"))
        );
        assertEq(IERC20Like(Ethereum.USDS).balanceOf(address(almProxy)), usdsBefore);
        assertEq(IERC20Like(Ethereum.USDT).balanceOf(address(almProxy)), usdtBefore);
        assertEq(IERC20Like(Ethereum.USDS).balanceOf(address(relay)), 0);
        assertEq(IERC20Like(Ethereum.USDT).balanceOf(address(relay)), 0);
    }

    function test_nonAllocatorCannotInitiateCounterpartySwap() external {
        SwapAssetCallRelay relay = new SwapAssetCallRelay();
        bytes memory callData = abi.encodeWithSignature(
            "swapAsset_initiateSwap(address,address,address,uint256)",
            address(counterpartyController),
            Ethereum.USDS,
            Ethereum.USDT,
            1_000e18
        );

        (bool success, bytes memory reason) = relay.invoke(address(mainnetController), callData);

        assertFalse(success, "non-allocator unexpectedly initiated a swap");
        assertEq(
            keccak256(reason),
            keccak256(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    address(relay),
                    ALLOCATOR_ROLE
                )
            )
        );
    }

    function test_unknownCounterpartyCannotInstallOrConsumeItsOwnRateLimit() external {
        SwapAssetCallRelay relay = new SwapAssetCallRelay();
        bytes32 key = mainnetController.swapAsset_getCompleteSwapRateLimitKey(
            Ethereum.USDS,
            address(relay),
            Ethereum.USDT
        );

        (bool configured, bytes memory adminError) = relay.invoke(
            address(rateLimits),
            abi.encodeCall(IRateLimits.setUnlimitedRateLimitData, (key))
        );
        assertFalse(configured, "unknown peer configured its own rate limit");
        assertEq(
            keccak256(adminError),
            keccak256(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    address(relay),
                    DEFAULT_ADMIN_ROLE
                )
            )
        );

        (bool consumed, bytes memory controllerError) = relay.invoke(
            address(rateLimits),
            abi.encodeCall(IRateLimits.triggerRateLimitDecrease, (key, uint256(1)))
        );
        assertFalse(consumed, "unknown peer directly consumed a rate limit");
        assertEq(
            keccak256(controllerError),
            keccak256(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    address(relay),
                    rateLimits.CONTROLLER()
                )
            )
        );
        assertEq(rateLimits.getRateLimitData(key).maxAmount, 0);
    }
}
