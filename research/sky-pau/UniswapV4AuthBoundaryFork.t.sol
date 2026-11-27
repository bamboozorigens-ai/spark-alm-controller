// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAccessControl } from "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { IALMProxy } from "../../src/interfaces/IALMProxy.sol";
import { IUniswapV4Controller } from "../../src/facets/uniswap-v4/IUniswapV4Controller.sol";
import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";
import { IERC20Like, MainnetController_UniswapV4_Tests } from "../mainnet-fork/UniswapV4.t.sol";

contract UniswapV4CallRelay {
    function invoke(address target, bytes calldata data)
        external
        returns (bool success, bytes memory returnData)
    {
        return target.call(data);
    }
}

contract UniswapV4AuthBoundaryFork is MainnetController_UniswapV4_Tests {
    bytes32 internal constant _CONTROLLER_ROLE = keccak256("CONTROLLER");
    bytes32 internal constant _ALLOCATOR_ADMIN_ROLE = keccak256("ALLOCATOR_ADMIN_ROLE");
    bytes32 internal constant _TEST_POOL_ID = 0x8aa4e11cbdf30eedc92100f4c8a31ff748e201d44712cc8c90d189edaa8e4e47;

    function test_relayCannotMutateAnyUniswapV4EntryPointOrProxyBalances() external {
        UniswapV4CallRelay relay = new UniswapV4CallRelay();

        deal(Ethereum.USDC, address(almProxy), 25_000e6);
        deal(Ethereum.USDT, address(almProxy), 25_000e6);
        uint256 usdcBefore = IERC20Like(Ethereum.USDC).balanceOf(address(almProxy));
        uint256 usdtBefore = IERC20Like(Ethereum.USDT).balanceOf(address(almProxy));

        bytes[] memory attempts = new bytes[](4);
        attempts[0] = abi.encodeCall(
            IUniswapV4Controller.uniswapV4_mintPosition,
            (_TEST_POOL_ID, int24(-10), int24(10), uint128(1), uint128(1), uint128(1))
        );
        attempts[1] = abi.encodeCall(
            IUniswapV4Controller.uniswapV4_increasePosition,
            (_TEST_POOL_ID, uint256(1), uint128(1), uint128(1), uint128(1))
        );
        attempts[2] = abi.encodeCall(
            IUniswapV4Controller.uniswapV4_decreasePosition,
            (_TEST_POOL_ID, uint256(1), uint128(1), uint128(0), uint128(0))
        );
        attempts[3] = abi.encodeCall(
            IUniswapV4Controller.uniswapV4_swap,
            (_TEST_POOL_ID, Ethereum.USDC, uint128(1e6), uint128(1))
        );

        for (uint256 i; i < attempts.length; ++i) {
            (bool success, bytes memory data) = relay.invoke(address(mainnetController), attempts[i]);
            assertFalse(success, "relay unexpectedly reached privileged facet action");
            assertEq(
                keccak256(data),
                keccak256(
                    abi.encodeWithSelector(
                        IAccessControl.AccessControlUnauthorizedAccount.selector,
                        address(relay),
                        ALLOCATOR_ROLE
                    )
                ),
                "unexpected authorization failure"
            );
        }

        assertEq(IERC20Like(Ethereum.USDC).balanceOf(address(almProxy)), usdcBefore);
        assertEq(IERC20Like(Ethereum.USDT).balanceOf(address(almProxy)), usdtBefore);
    }

    function test_relayCannotPromoteItselfOrTakeControllerProxyRole() external {
        UniswapV4CallRelay relay = new UniswapV4CallRelay();

        (bool grantAllocator, bytes memory allocatorError) = relay.invoke(
            address(accessControls),
            abi.encodeCall(IAccessControl.grantRole, (ALLOCATOR_ROLE, address(relay)))
        );
        assertFalse(grantAllocator);
        assertEq(
            keccak256(allocatorError),
            keccak256(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    address(relay),
                        _ALLOCATOR_ADMIN_ROLE
                )
            )
        );

        (bool grantController, bytes memory proxyError) = relay.invoke(
            address(almProxy),
            abi.encodeCall(IAccessControl.grantRole, (_CONTROLLER_ROLE, address(relay)))
        );
        assertFalse(grantController);
        assertEq(
            keccak256(proxyError),
            keccak256(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    address(relay),
                    DEFAULT_ADMIN_ROLE
                )
            )
        );

        assertFalse(accessControls.hasRole(ALLOCATOR_ROLE, address(relay)));
        assertFalse(almProxy.hasRole(_CONTROLLER_ROLE, address(relay)));
    }

    function test_relayCannotChangeFacetOrRoleAdminConfiguration() external {
        UniswapV4CallRelay relay = new UniswapV4CallRelay();

        bytes[] memory attempts = new bytes[](3);
        attempts[0] = abi.encodeCall(
            IUniswapV4Controller.uniswapV4_setMaxSlippage,
            (_TEST_POOL_ID, uint256(0))
        );
        attempts[1] = abi.encodeCall(
            IUniswapV4Controller.uniswapV4_setTickLimits,
            (_TEST_POOL_ID, int24(-887272), int24(887272), uint24(1774544))
        );
        attempts[2] = abi.encodeWithSignature(
            "setRoleAdmin(bytes32,bytes32)", ALLOCATOR_ROLE, bytes32(0)
        );

        for (uint256 i; i < attempts.length; ++i) {
            address target = i == 2 ? address(accessControls) : address(mainnetController);
            (bool success, bytes memory data) = relay.invoke(target, attempts[i]);
            assertFalse(success, "relay unexpectedly changed privileged configuration");
            assertEq(
                keccak256(data),
                keccak256(
                    abi.encodeWithSelector(
                        IAccessControl.AccessControlUnauthorizedAccount.selector,
                        address(relay),
                        DEFAULT_ADMIN_ROLE
                    )
                )
            );
        }

        assertEq(mainnetController.uniswapV4_getMaxSlippage(_TEST_POOL_ID), 0);
        (int24 tickLower, int24 tickUpper, uint24 maxTickSpacing) =
            mainnetController.uniswapV4_getTickLimits(_TEST_POOL_ID);
        assertEq(tickLower, 0);
        assertEq(tickUpper, 0);
        assertEq(maxTickSpacing, 0);
        assertEq(accessControls.getRoleAdmin(ALLOCATOR_ROLE), _ALLOCATOR_ADMIN_ROLE);
    }

    function test_relayCannotInvokeProxyDelegateOrValueCalls() external {
        UniswapV4CallRelay relay = new UniswapV4CallRelay();
        bytes[] memory attempts = new bytes[](2);
        attempts[0] = abi.encodeCall(
            IALMProxy.doDelegateCall,
            (address(relay), abi.encodeWithSignature("invoke(address,bytes)", address(0), bytes("")))
        );
        attempts[1] = abi.encodeCall(
            IALMProxy.doCallWithValue,
            (address(relay), bytes(""), uint256(0))
        );

        for (uint256 i; i < attempts.length; ++i) {
            (bool success, bytes memory data) = relay.invoke(address(almProxy), attempts[i]);
            assertFalse(success, "relay unexpectedly entered privileged proxy call path");
            assertEq(
                keccak256(data),
                keccak256(
                    abi.encodeWithSelector(
                        IAccessControl.AccessControlUnauthorizedAccount.selector,
                        address(relay),
                        _CONTROLLER_ROLE
                    )
                )
            );
        }
    }

    function test_relayCannotCallProxyDoCallToTransferAssets() external {
        UniswapV4CallRelay relay = new UniswapV4CallRelay();
        deal(Ethereum.USDC, address(almProxy), 25_000e6);

        uint256 proxyBefore = IERC20Like(Ethereum.USDC).balanceOf(address(almProxy));
        uint256 relayBefore = IERC20Like(Ethereum.USDC).balanceOf(address(relay));

        bytes memory transferData = abi.encodeWithSignature(
            "transfer(address,uint256)", address(relay), 25_000e6
        );
        (bool success, bytes memory data) = relay.invoke(
            address(almProxy),
            abi.encodeCall(IALMProxy.doCall, (Ethereum.USDC, transferData))
        );

        assertFalse(success, "relay unexpectedly executed ALMProxy call");
        assertEq(
            keccak256(data),
            keccak256(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector,
                    address(relay),
                    _CONTROLLER_ROLE
                )
            )
        );
        assertEq(IERC20Like(Ethereum.USDC).balanceOf(address(almProxy)), proxyBefore);
        assertEq(IERC20Like(Ethereum.USDC).balanceOf(address(relay)), relayBefore);
    }
}
