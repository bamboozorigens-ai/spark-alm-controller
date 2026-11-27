// Controlled PoC for sky-ecosystem/diamond-pau.
// Place in that repository at test/audit/MapleImpairmentDepositSimulation.t.sol
// and run: forge test --match-path test/audit/MapleImpairmentDepositSimulation.t.sol -vv
// This uses a synthetic impairment mock, not Maple bytecode, and is not a live exploit.

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IController } from "../../src/interfaces/IController.sol";
import { IALMProxy } from "../../src/interfaces/IALMProxy.sol";
import { IRateLimits } from "../../src/interfaces/IRateLimits.sol";
import { IEnumerableIntegrations } from "../../src/interfaces/IEnumerableIntegrations.sol";
import { IFacet } from "../../src/facets/IFacet.sol";
import { IERC4626Facet } from "../../src/facets/erc4626/IERC4626Facet.sol";
import { ERC4626Facet } from "../../src/facets/erc4626/ERC4626Facet.sol";
import { Integration_TestBase } from "../integration/TestBase.t.sol";

interface IControllerERC4626Audit {
    function setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external;
    function getDepositRateLimitKey(address token, address asset) external pure returns (bytes32);
    function deposit(address token, uint256 amount, uint256 minSharesOut) external returns (uint256);
    function updateIntegrations(bytes32[] memory integrationIds) external;
}

/// @dev Models the documented Maple impairment split: deposits price from gross assets, while
///      exits use gross assets less unrealized losses. This is a local mock, not Maple bytecode.
contract ImpairedMapleLikeVault is ERC20 {
    IERC20 public immutable asset;
    uint256 public immutable grossAssets;
    uint256 public immutable unrealizedLosses;

    constructor(IERC20 asset_, uint256 grossAssets_, uint256 losses_)
        ERC20("Mock Maple Share", "mMAPLE")
    {
        asset = asset_;
        grossAssets = grossAssets_;
        unrealizedLosses = losses_;
        _mint(address(this), grossAssets_);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets * totalSupply() / asset.balanceOf(address(this));
        asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function exitValue(uint256 shares) external view returns (uint256) {
        return shares * (asset.balanceOf(address(this)) - unrealizedLosses) / totalSupply();
    }
}

contract MapleImpairmentDepositSimulation is Integration_TestBase {
    address internal controller;
    IRateLimits internal rateLimits;
    MockUSD internal usd;
    ImpairedMapleLikeVault internal mapleLike;

    uint256 internal constant GROSS_ASSETS = 1_000_000e6;
    uint256 internal constant EXISTING_LOSSES = 200_000e6;
    uint256 internal constant NEW_DEPOSIT = 100_000e6;

    function setUp() external {
        controller = _deploy();
        rateLimits = IRateLimits(IController(controller).rateLimits());
        usd = new MockUSD();
        usd.mint(address(this), GROSS_ASSETS);
        usd.mint(IController(controller).proxy(), NEW_DEPOSIT);
        mapleLike = new ImpairedMapleLikeVault(IERC20(address(usd)), GROSS_ASSETS, EXISTING_LOSSES);
        usd.transfer(address(mapleLike), GROSS_ASSETS);

        address facet = address(new ERC4626Facet());
        IEnumerableIntegrations.Wire[] memory wires = new IEnumerableIntegrations.Wire[](3);
        wires[0] = IEnumerableIntegrations.Wire(
            IControllerERC4626Audit.deposit.selector,
            IERC4626Facet.deposit.selector
        );
        wires[1] = IEnumerableIntegrations.Wire(
            IControllerERC4626Audit.setMaxExchangeRate.selector,
            IERC4626Facet.setMaxExchangeRate.selector
        );
        wires[2] = IEnumerableIntegrations.Wire(
            IControllerERC4626Audit.getDepositRateLimitKey.selector,
            IERC4626Facet.getDepositRateLimitKey.selector
        );

        vm.prank(beaconAdmin);
        beacon.setIntegration(
            "ERC4626_FACET",
            IEnumerableIntegrations.Config(facet, wires)
        );

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = "ERC4626_FACET";
        vm.prank(admin);
        IControllerERC4626Audit(controller).updateIntegrations(integrationIds);

        bytes32 depositKey = IControllerERC4626Audit(controller).getDepositRateLimitKey(
            address(mapleLike), address(usd)
        );
        vm.prank(admin);
        rateLimits.setRateLimitData(depositKey, NEW_DEPOSIT, 0);

        vm.prank(admin);
        IControllerERC4626Audit(controller).setMaxExchangeRate(address(mapleLike), 1e18, 1e18);
    }

    function test_impairedDepositPassesGrossExchangeRateButHasLowerExitValue() external {
        uint256 existingShares = mapleLike.balanceOf(address(mapleLike));
        uint256 existingExitValueBefore = mapleLike.exitValue(existingShares);

        vm.prank(allocator);
        uint256 shares = IControllerERC4626Audit(controller).deposit(address(mapleLike), NEW_DEPOSIT, NEW_DEPOSIT);

        uint256 exitValue = mapleLike.exitValue(shares);
        uint256 existingExitValueAfter = mapleLike.exitValue(existingShares);

        assertEq(shares, NEW_DEPOSIT); // gross-price exchange rate is exactly 1:1
        assertEq(exitValue, NEW_DEPOSIT * 900_000 / 1_100_000);
        assertEq(NEW_DEPOSIT - exitValue, 18_181_818_182);
        assertEq(existingExitValueBefore, 800_000e6);
        assertEq(existingExitValueAfter - existingExitValueBefore, 18_181_818_181);
    }

    function test_zeroRateLimitBlocksDepositBeforeAssetsMove() external {
        address proxy = IController(controller).proxy();
        bytes32 depositKey = IControllerERC4626Audit(controller).getDepositRateLimitKey(
            address(mapleLike), address(usd)
        );
        vm.prank(admin);
        rateLimits.setRateLimitData(depositKey, 0, 0);

        uint256 beforeBalance = usd.balanceOf(proxy);
        vm.expectRevert(bytes("RateLimits/zero-maxAmount"));
        vm.prank(allocator);
        IControllerERC4626Audit(controller).deposit(address(mapleLike), NEW_DEPOSIT, 0);
        assertEq(usd.balanceOf(proxy), beforeBalance);
    }

    function test_directProxyCallCannotBypassFacetRateLimit() external {
        address proxy = IController(controller).proxy();
        bytes memory data = abi.encodeCall(
            ImpairedMapleLikeVault.deposit,
            (NEW_DEPOSIT, proxy)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IFacet.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                IALMProxy(proxy).CONTROLLER()
            )
        );
        vm.prank(unauthorized);
        IALMProxy(proxy).doCall(address(mapleLike), data);
        assertEq(usd.balanceOf(proxy), NEW_DEPOSIT);
    }
}

contract MockUSD is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
