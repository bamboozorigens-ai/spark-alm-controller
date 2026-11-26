// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { LockstakeEngineIntegrationTest } from "../LockstakeEngine-invariants.t.sol";
import { VoteDelegateMock } from "../mocks/VoteDelegateMock.sol";

interface SpotterAuditLike { function poke(bytes32) external; }
interface DogAuditLike { function bark(bytes32, address, address) external returns (uint256); }
interface VatAuditLike { function suck(address, address, uint256) external; function hope(address) external; }

contract LockstakeMultiUrnForkTest is LockstakeEngineIntegrationTest {
    function test_liquidatingOneUrnLeavesOtherUrnDelegationAndFarmStakeIntact() public {
        address urn1 = engine.open(1);
        uint256 wad = 100 ether;
        sky.approve(address(engine), type(uint256).max);

        engine.lock(address(this), 0, wad, 0);
        engine.lock(address(this), 1, wad, 0);

        vm.prank(pauseProxy);
        engine.addFarm(address(farm0));
        engine.selectVoteDelegate(address(this), 0, voterDelegate0);
        engine.selectVoteDelegate(address(this), 1, voterDelegate0);
        engine.selectFarm(address(this), 0, address(farm0), 0);
        engine.selectFarm(address(this), 1, address(farm0), 0);

        engine.draw(address(this), 1, address(this), 20_000 ether);
        pip.setPrice(100 ether);
        SpotterAuditLike(spot).poke(ilk);
        uint256 auctionId = DogAuditLike(address(dog)).bark(ilk, urn1, address(this));

        assertEq(engine.urnVoteDelegates(urn), voterDelegate0, "unliquidated urn lost delegate");
        assertEq(engine.urnFarms(urn), address(farm0), "unliquidated urn lost farm");
        assertEq(VoteDelegateMock(voterDelegate0).stake(address(engine)), wad, "delegate stake not scoped to urn");
        assertEq(farm0.balanceOf(urn), wad, "farm stake not scoped to urn");

        assertEq(engine.urnVoteDelegates(urn1), address(0), "liquidated urn retained delegate");
        assertEq(engine.urnFarms(urn1), address(0), "liquidated urn retained farm");
        assertEq(VoteDelegateMock(voterDelegate0).stake(address(engine)), wad, "liquidation removed other urn delegate stake");
        assertEq(farm0.balanceOf(urn1), 0, "liquidation left stake in liquidated urn");
        assertEq(engine.urnAuctions(urn1), 1, "auction counter mismatch");

        // Finish the auction with synthetic Vat DAI, on the fork only.
        address buyer = address(0xBEEF);
        vm.prank(pauseProxy);
        VatAuditLike(address(vat)).suck(address(0), buyer, rad(1_000_000 ether));
        vm.prank(buyer);
        VatAuditLike(address(vat)).hope(address(clip));
        vm.prank(buyer);
        clip.take(auctionId, type(uint256).max, type(uint256).max, buyer, "");

        assertEq(engine.urnAuctions(urn1), 0, "auction counter did not clear");
        assertEq(engine.urnVoteDelegates(urn), voterDelegate0, "auction completion changed other urn delegate");
        assertEq(engine.urnFarms(urn), address(farm0), "auction completion changed other urn farm");
        assertEq(VoteDelegateMock(voterDelegate0).stake(address(engine)), wad, "auction completion changed other urn delegate stake");
        assertEq(farm0.balanceOf(urn), wad, "auction completion changed other urn farm stake");
    }
}
