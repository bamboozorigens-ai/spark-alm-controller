// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// PASSO 392: sUSDS real-share redemptions under a potentially compromised
// RELAYER, executed on LOCAL fork only. No synthetic funding of the ALMProxy.
// Test the important invariant: shares/assets stay with the ALMProxy, never
// the outside attacker. Also test that excessive minimums revert atomically.
// No on-chain transactions are transmitted.
import { Test } from "../../lib/forge-std/src/Test.sol";
import { console2 } from "../../lib/forge-std/src/console2.sol";

interface IController392 {
    function RELAYER() external view returns (bytes32);
    function hasRole(bytes32 role, address who) external view returns (bool);
    function redeemERC4626(address vault, uint256 shares, uint256 minAssetsOut)
        external returns (uint256 assets);
    function withdrawERC4626(address vault, uint256 assets, uint256 maxSharesIn)
        external returns (uint256 shares);
}
interface IERC20392 {
    function balanceOf(address who) external view returns (uint256);
}
interface IERC4626View392 {
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}
contract SparkForkSUSDSRedemption392 is Test {
    address constant CONTROLLER=0xc953972Cd006d1f12686fd7185c6D443b15900Cd;
    address constant PROXY=0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address constant RELAYER=0x8a25A24EDE9482C4Fc0738F99611BE58F1c839AB;
    address constant USDS=0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant SUSDS=0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant ATTACKER=address(0xA771AC);
    uint256 constant SHARE_AMOUNT=1_000e18;
    uint256 constant ASSET_AMOUNT=1_000e18;

    IController392 controller;
    IERC4626View392 vault;
    IERC20392 susds;
    IERC20392 usds;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        controller=IController392(CONTROLLER);
        vault=IERC4626View392(SUSDS);
        susds=IERC20392(SUSDS);
        usds=IERC20392(USDS);
        assertTrue(controller.hasRole(controller.RELAYER(),RELAYER),"Relayer role unavailable");
        assertFalse(controller.hasRole(controller.RELAYER(),ATTACKER),"Attacker already RELAYER");
        assertGe(susds.balanceOf(PROXY),SHARE_AMOUNT,"Not enough REAL Spark sUSDS shares");
        console2.log("PASSO 392 fork block",block.number);
        console2.log("Real sUSDS shares at ALMProxy",susds.balanceOf(PROXY));
    }

    function testCompromisedRelayerCanOnlyRedeemBackToProxy() public {
        uint256 expectedAssets=vault.previewRedeem(SHARE_AMOUNT);
        uint256 proxySharesBefore=susds.balanceOf(PROXY);
        uint256 proxyUSDSBefore=usds.balanceOf(PROXY);
        uint256 attackerUSDSBefore=usds.balanceOf(ATTACKER);
        uint256 attackerSharesBefore=susds.balanceOf(ATTACKER);

        vm.prank(RELAYER); // impersonation permitted only inside isolated test fork
        uint256 assets=controller.redeemERC4626(SUSDS,SHARE_AMOUNT,expectedAssets);

        assertGe(assets,expectedAssets,"FINDING: redeemed below preview minimum");
        assertEq(proxySharesBefore-susds.balanceOf(PROXY),SHARE_AMOUNT,
            "FINDING: unexpected share accounting");
        assertEq(usds.balanceOf(PROXY)-proxyUSDSBefore,assets,
            "FINDING: redemption proceeds missing at proxy");
        assertEq(usds.balanceOf(ATTACKER),attackerUSDSBefore,
            "FINDING: redemption paid the outside attacker");
        assertEq(susds.balanceOf(ATTACKER),attackerSharesBefore,
            "FINDING: unauthorized transfer of shares");
        console2.log("Authorized fork relayer shares redeemed",SHARE_AMOUNT);
        console2.log("USDS credited only to proxy",assets);
        console2.log("External attacker net USDS",usds.balanceOf(ATTACKER)-attackerUSDSBefore);
    }

    function testCompromisedRelayerCannotForceBelowMinimumRedemption() public {
        uint256 expectedAssets=vault.previewRedeem(SHARE_AMOUNT);
        uint256 beforeShares=susds.balanceOf(PROXY);
        uint256 beforeUSDS=usds.balanceOf(PROXY);
        uint256 beforeAttackerUSDS=usds.balanceOf(ATTACKER);

        vm.prank(RELAYER);
        (bool success,bytes memory data)=CONTROLLER.call(abi.encodeWithSignature(
            "redeemERC4626(address,uint256,uint256)",
            SUSDS,SHARE_AMOUNT,expectedAssets+1
        ));
        console2.log("Overoptimistic minimum redemption success",success);
        console2.log("Revert payload bytes",data.length);
        assertFalse(success,"FINDING: overoptimistic minimum accepted");
        assertEq(susds.balanceOf(PROXY),beforeShares,
                 "FINDING: shares lost on failed redemption");
        assertEq(usds.balanceOf(PROXY),beforeUSDS,
                 "FINDING: underlying moved on failed redemption");
        assertEq(usds.balanceOf(ATTACKER),beforeAttackerUSDS,
                 "FINDING: outsider gained assets on failed redemption");
    }

    function testCompromisedRelayerCannotOverburnSharesInWithdraw() public {
        uint256 burnedExpected=vault.previewWithdraw(ASSET_AMOUNT);
        assertGt(burnedExpected,0,"Invalid previewWithdraw response");
        uint256 sharesBefore=susds.balanceOf(PROXY);
        uint256 assetsBefore=usds.balanceOf(PROXY);
        uint256 attackerBefore=usds.balanceOf(ATTACKER);

        vm.prank(RELAYER);
        (bool success,)=CONTROLLER.call(abi.encodeWithSignature(
            "withdrawERC4626(address,uint256,uint256)",
            SUSDS,ASSET_AMOUNT,burnedExpected-1
        ));
        assertFalse(success,"FINDING: over-burn beyond maxSharesIn accepted");
        assertEq(susds.balanceOf(PROXY),sharesBefore);
        assertEq(usds.balanceOf(PROXY),assetsBefore);
        assertEq(usds.balanceOf(ATTACKER),attackerBefore);
        console2.log("Over-burn withdrawal blocked atomically");
    }

    function testUnprivilegedRedemptionBlockedWithNoPayout() public {
        uint256 beforeShares=susds.balanceOf(PROXY);
        uint256 beforeAssets=usds.balanceOf(PROXY);
        uint256 attackerBefore=usds.balanceOf(ATTACKER);

        vm.prank(ATTACKER);
        (bool success,)=CONTROLLER.call(abi.encodeWithSignature(
            "redeemERC4626(address,uint256,uint256)",
            SUSDS,SHARE_AMOUNT,uint256(0)
        ));
        assertFalse(success,"FINDING: outsider redeemed Spark shares");
        assertEq(susds.balanceOf(PROXY),beforeShares);
        assertEq(usds.balanceOf(PROXY),beforeAssets);
        assertEq(usds.balanceOf(ATTACKER),attackerBefore);
        console2.log("Unprivileged redemption denied");
    }
}
