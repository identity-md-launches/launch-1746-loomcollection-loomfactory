// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase} from "./helpers/LoomTestBase.sol";
import {LoomLifecycleHandler} from "./helpers/LoomLifecycleHandler.sol";
import {LoomCollection} from "src/LoomCollection.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LoomLifecycleInvariantTest is LoomTestBase {
    LoomLifecycleHandler private handler;
    address[4] private actors;
    address[2] private artists;
    uint256 private platformStart;

    function setUp() public override {
        super.setUp();
        actors = [owner, bob, alice, makeAddr("lifecycle fourth actor")];
        artists = [creator, makeAddr("lifecycle second creator")];
        LoomCollection first = _create(owner, 101, 1, 17, artists[0], 1);
        LoomCollection second = _create(bob, 207, 0.003 ether + 7, 29, artists[1], 999);
        handler = new LoomLifecycleHandler(first, second, actors, artists);
        platformStart = platform.balance;
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.administer.selector;
        selectors[2] = handler.ownership.selector;
        selectors[3] = handler.transfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_eachCloneMatchesIndependentLifecycleAndNFTLedger() public view {
        for (uint256 i; i < 2; ++i) {
            LoomCollection target = handler.targets(i);
            LoomLifecycleHandler.Model memory m = handler.model(i);
            assertEq(target.owner(), m.owner);
            assertEq(target.pendingOwner(), m.pendingOwner);
            assertEq(target.paused(), m.paused);
            assertEq(target.metadataFrozen(), m.frozen);
            assertEq(target.provenanceSet(), m.hasProvenance);
            assertEq(target.revealSeedSet(), m.hasSeed);
            assertEq(target.provenanceHash(), m.provenance);
            assertEq(target.revealSeed(), m.seed);
            assertEq(target.baseURI(), m.base);
            assertEq(target.unrevealedURI(), m.hidden);
            assertEq(target.totalSupply(), m.supply);
            assertEq(target.reserveMinted(), m.reserved);
            assertLe(m.supply, handler.supplies(i));
            assertLe(m.reserved, handler.supplies(i) / 100);
            uint256 sum;
            uint256 publicMints;
            for (uint256 j; j < actors.length; ++j) {
                assertEq(target.balanceOf(actors[j]), handler.balances(i, actors[j]));
                assertEq(target.mintedPerWallet(actors[j]), handler.minted(i, actors[j]));
                assertLe(target.mintedPerWallet(actors[j]), handler.caps(i));
                sum += target.balanceOf(actors[j]);
                publicMints += target.mintedPerWallet(actors[j]);
            }
            assertEq(sum, m.supply);
            assertEq(publicMints + m.reserved, m.supply);
            for (uint256 id = 1; id <= m.supply; ++id) {
                assertEq(target.ownerOf(id), handler.holders(i, id));
            }
            if (m.supply > 0) {
                string memory expected =
                    bytes(m.base).length == 0 ? m.hidden : string.concat(m.base, vm.toString(m.supply), ".json");
                assertEq(target.tokenURI(m.supply), expected);
            }
        }
    }

    function invariant_paymentsEqualExactRecipientGainsAndConfigurationNeverChanges() public view {
        uint256 combinedSupply;
        uint256 creatorGains;
        for (uint256 i; i < 2; ++i) {
            LoomCollection target = handler.targets(i);
            LoomLifecycleHandler.Model memory m = handler.model(i);
            uint256 expectedCreator = (handler.prices(i) + 0.0002 ether) * m.supply;
            assertEq(artists[i].balance, expectedCreator);
            creatorGains += expectedCreator;
            combinedSupply += m.supply;
            assertEq(address(target).balance, 0);
            assertEq(target.creator(), artists[i]);
            assertEq(target.mintPriceWei(), handler.prices(i));
            assertEq(target.maxSupply(), handler.supplies(i));
            assertEq(target.maxPerWallet(), handler.caps(i));
            assertEq(target.royaltyBps(), i == 0 ? 1 : 999);
            assertEq(target.PLATFORM(), platform);
            assertEq(target.RESERVE(), reserve);
            assertEq(target.name(), "Swarm Art");
            assertEq(target.symbol(), "ART");
        }
        assertEq(platform.balance - platformStart, combinedSupply * 0.0002 ether);
        assertEq(reserve.balance, combinedSupply * 0.0001 ether);
        assertEq(creatorGains + platform.balance - platformStart + reserve.balance, handler.paid());
        assertEq(address(factory).balance, 0);
        assertEq(implementation.totalSupply(), 0);
        assertEq(implementation.owner(), address(0));
        assertEq(implementation.baseURI(), "");
    }

    /// @dev A deterministic sequence ensures the same handler reaches post-freeze, handover,
    /// rollback, and reserve-cap checks even if a random campaign happens not to select them.
    function test_handlerExercisesSuccessfulAndRejectedCallsAfterFreezeAndHandover() public {
        for (uint8 i; i < 2; ++i) {
            handler.administer(i, 0, 0, bytes32(0), true);
            handler.administer(i, 0, 1, bytes32(0), true);
            handler.mint(i, 2, 2, 0, false, false);
            handler.mint(i, 2, 1, 1, false, false);
            handler.mint(i, 0, 1, 0, true, true);
            handler.administer(i, 0, 4, bytes32(0), true);
            handler.administer(i, 0, 2, keccak256("frozen replacement"), true);
            handler.ownership(i, 0, 3, false, true);
            handler.ownership(i, 0, 3, true, true);
            handler.administer(i, 0, 7, keccak256("reinitialize"), true);
            handler.administer(i, 0, 5, bytes32(0), true);
            handler.mint(i, 2, 1, 0, false, false);
            handler.transfer(i, 1, 2, 3, true);
            handler.administer(i, 0, 6, bytes32(0), true);
            handler.mint(i, 0, 2, 0, true, true);
        }
        assertEq(handler.successfulMints(), 4);
        assertGe(handler.rejectedCalls(), 10);
        invariant_eachCloneMatchesIndependentLifecycleAndNFTLedger();
        invariant_paymentsEqualExactRecipientGainsAndConfigurationNeverChanges();
    }
}
