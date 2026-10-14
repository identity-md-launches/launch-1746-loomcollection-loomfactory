// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase} from "./helpers/LoomTestBase.sol";
import {LoomCollection} from "../src/LoomCollection.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract LoomInitializationTest is LoomTestBase {
    function test_factoryInitializesEveryParameterAndStartsWithEmptyMetadata() public view {
        assertEq(collection.name(), "Swarm Art");
        assertEq(collection.symbol(), "ART");
        assertEq(collection.owner(), owner);
        assertEq(collection.creator(), creator);
        assertEq(collection.maxSupply(), 1000);
        assertEq(collection.maxPerWallet(), 20);
        assertEq(collection.mintPriceWei(), PRICE);
        assertEq(collection.royaltyBps(), 500);
        assertEq(collection.PLATFORM(), platform);
        assertEq(collection.RESERVE(), reserve);
        assertEq(collection.PLATFORM_FEE(), FEE);
        assertEq(collection.totalSupply(), 0);
        assertEq(collection.reserveMinted(), 0);
        assertEq(collection.baseURI(), "");
        assertEq(collection.unrevealedURI(), "");
        assertFalse(collection.paused());
        assertFalse(collection.metadataFrozen());
        assertFalse(collection.revealSeedSet());
        assertFalse(collection.provenanceSet());
        assertEq(collection.pendingOwner(), address(0));
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize("Attack", "BAD", 1000, 0, 100, alice, 0, alice);
        assertEq(implementation.owner(), address(0));
        assertEq(implementation.totalSupply(), 0);
    }

    function test_cloneCannotBeInitializedTwiceEvenByOwner() public {
        vm.startPrank(owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        collection.initialize("Attack", "BAD", 1000, 0, 100, alice, 0, alice);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        collection.initialize("Attack", "BAD", 1000, 0, 100, alice, 0, alice);
        assertEq(collection.owner(), owner);
        assertEq(collection.creator(), creator);
    }

    function test_invalidInitializationRollsBackAndCanBeCorrected() public {
        LoomCollection fresh = _blankClone();
        vm.expectRevert(LoomCollection.InvalidSupplyOrWalletCap.selector);
        fresh.initialize("Art", "ART", 0, 0, 1, creator, 500, owner);
        fresh.initialize("Art", "ART", 1, 0, 1, creator, 500, owner);
        assertEq(fresh.owner(), owner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh.initialize("Art", "ART", 1, 0, 1, creator, 500, owner);
    }

    function test_rejectsZeroConstructorRecipients() public {
        vm.expectRevert(LoomCollection.ZeroAddress.selector);
        new LoomCollection(address(0), reserve);
        vm.expectRevert(LoomCollection.ZeroAddress.selector);
        new LoomCollection(platform, address(0));
    }

    function test_rejectsZeroCreatorOrOwner() public {
        LoomCollection fresh = _blankClone();
        vm.expectRevert(LoomCollection.ZeroAddress.selector);
        fresh.initialize("Art", "ART", 10, 0, 1, address(0), 500, owner);
        vm.expectRevert(LoomCollection.ZeroAddress.selector);
        fresh.initialize("Art", "ART", 10, 0, 1, creator, 500, address(0));
    }

    function test_rejectsEmptyNameOrSymbol() public {
        LoomCollection fresh = _blankClone();
        vm.expectRevert(LoomCollection.EmptyNameOrSymbol.selector);
        fresh.initialize("", "ART", 10, 0, 1, creator, 500, owner);
        vm.expectRevert(LoomCollection.EmptyNameOrSymbol.selector);
        fresh.initialize("Art", "", 10, 0, 1, creator, 500, owner);
    }

    function test_rejectsZeroSupplyZeroWalletCapOrWalletCapAboveSupply() public {
        LoomCollection fresh = _blankClone();
        vm.expectRevert(LoomCollection.InvalidSupplyOrWalletCap.selector);
        fresh.initialize("Art", "ART", 0, 0, 1, creator, 500, owner);
        vm.expectRevert(LoomCollection.InvalidSupplyOrWalletCap.selector);
        fresh.initialize("Art", "ART", 10, 0, 0, creator, 500, owner);
        vm.expectRevert(LoomCollection.InvalidSupplyOrWalletCap.selector);
        fresh.initialize("Art", "ART", 10, 0, 11, creator, 500, owner);
    }

    function test_rejectsUnrepresentableUnitPrice() public {
        LoomCollection fresh = _blankClone();
        vm.expectRevert(LoomCollection.InvalidMintPrice.selector);
        fresh.initialize("Art", "ART", 10, type(uint256).max - FEE + 1, 1, creator, 0, owner);
        fresh.initialize("Art", "ART", 10, type(uint256).max - FEE, 1, creator, 0, owner);
        assertEq(fresh.mintPriceWei(), type(uint256).max - FEE);
    }

    function testFuzz_rejectsRoyaltyAboveTenPercent(uint96 bps) public {
        bps = uint96(bound(bps, 1001, type(uint96).max));
        LoomCollection fresh = _blankClone();
        vm.expectRevert(LoomCollection.RoyaltyTooHigh.selector);
        fresh.initialize("Art", "ART", 100, 0, 10, creator, bps, owner);
    }

    function testFuzz_validInitialization(uint256 supply, uint256 price, uint256 cap, uint96 bps) public {
        supply = bound(supply, 1, type(uint256).max);
        cap = bound(cap, 1, supply);
        price = bound(price, 0, type(uint256).max - FEE);
        bps = uint96(bound(bps, 0, 1000));
        LoomCollection fresh = _blankClone();
        fresh.initialize("Art", "ART", supply, price, cap, creator, bps, owner);
        assertEq(fresh.maxSupply(), supply);
        assertEq(fresh.maxPerWallet(), cap);
        assertEq(fresh.mintPriceWei(), price);
        assertEq(fresh.royaltyBps(), bps);
    }

    function test_twoClonesAndImplementationDoNotShareStorage() public {
        LoomCollection second = _create(bob, 200, 0, 10, alice, 1000);
        vm.startPrank(owner);
        collection.setProvenanceHash(keccak256("provenance"));
        collection.setRevealSeed(keccak256("seed"));
        collection.setBaseURI("ipfs://first/");
        collection.setUnrevealedURI("ipfs://hidden");
        collection.transferOwnership(alice);
        vm.stopPrank();
        _mint(collection, alice, 2);
        _reserveMint(collection, owner, 1);
        vm.prank(alice);
        collection.setApprovalForAll(bob, true);
        vm.startPrank(owner);
        collection.freezeMetadata();
        collection.pause();
        vm.stopPrank();

        assertEq(second.owner(), bob);
        assertEq(second.pendingOwner(), address(0));
        assertEq(second.creator(), alice);
        assertEq(second.maxSupply(), 200);
        assertEq(second.maxPerWallet(), 10);
        assertEq(second.mintPriceWei(), 0);
        assertEq(second.royaltyBps(), 1000);
        assertEq(second.totalSupply(), 0);
        assertEq(second.reserveMinted(), 0);
        assertEq(second.mintedPerWallet(alice), 0);
        assertEq(second.balanceOf(alice), 0);
        assertFalse(second.isApprovedForAll(alice, bob));
        assertFalse(second.paused());
        assertFalse(second.metadataFrozen());
        assertFalse(second.provenanceSet());
        assertFalse(second.revealSeedSet());
        assertEq(second.baseURI(), "");
        assertEq(second.unrevealedURI(), "");
        assertEq(second.provenanceHash(), bytes32(0));
        assertEq(second.revealSeed(), bytes32(0));
        assertEq(implementation.totalSupply(), 0);
        assertEq(implementation.baseURI(), "");
        assertEq(implementation.owner(), address(0));
        _mint(second, bob, 1);
        assertEq(second.ownerOf(1), bob);
        assertEq(collection.ownerOf(1), alice);
        assertEq(collection.totalSupply(), 3);
        assertEq(second.PLATFORM(), collection.PLATFORM());
        assertEq(second.RESERVE(), collection.RESERVE());
    }
}
