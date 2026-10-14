// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase} from "./helpers/LoomTestBase.sol";
import {LoomCollection} from "../src/LoomCollection.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract LoomMetadataTest is LoomTestBase {
    function test_tokenURIUsesUnrevealedUntilBaseIsSet() public {
        _mint(collection, alice, 12);
        assertEq(collection.tokenURI(1), "");
        vm.startPrank(owner);
        collection.setUnrevealedURI("ipfs://unrevealed.json");
        assertEq(collection.tokenURI(1), "ipfs://unrevealed.json");
        assertEq(collection.tokenURI(12), "ipfs://unrevealed.json");
        vm.expectEmit(false, false, false, true, address(collection));
        emit LoomCollection.BaseURISet("ipfs://art/");
        collection.setBaseURI("ipfs://art/");
        assertEq(collection.tokenURI(1), "ipfs://art/1.json");
        assertEq(collection.tokenURI(12), "ipfs://art/12.json");
        collection.setBaseURI("");
        assertEq(collection.tokenURI(1), "ipfs://unrevealed.json");
        vm.stopPrank();
    }

    function test_tokenURIRejectsUnmintedIdsBeforeAndAfterReveal() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        collection.tokenURI(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        collection.tokenURI(1);
        _mint(collection, alice, 1);
        vm.prank(owner);
        collection.setBaseURI("ipfs://art/");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2));
        collection.tokenURI(2);
    }

    function test_freezeIsIrreversibleAndLocksAllMetadataSetters() public {
        _mint(collection, alice, 1);
        vm.startPrank(owner);
        collection.setBaseURI("ipfs://final/");
        collection.setUnrevealedURI("ipfs://hidden.json");
        vm.expectEmit(false, false, false, true, address(collection));
        emit LoomCollection.MetadataFrozen();
        collection.freezeMetadata();
        assertTrue(collection.metadataFrozen());
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.setBaseURI("ipfs://changed/");
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.setUnrevealedURI("ipfs://changed.json");
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.setRevealSeed(keccak256("late seed"));
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.setProvenanceHash(keccak256("late provenance"));
        vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
        collection.freezeMetadata();
        vm.stopPrank();
        assertEq(collection.tokenURI(1), "ipfs://final/1.json");
        _mint(collection, alice, 1);
        assertEq(collection.tokenURI(2), "ipfs://final/2.json");
    }

    function test_canFreezeAnUnrevealedCollection() public {
        vm.startPrank(owner);
        collection.setUnrevealedURI("ipfs://permanent-placeholder.json");
        collection.freezeMetadata();
        vm.stopPrank();
        _mint(collection, alice, 1);
        assertEq(collection.tokenURI(1), "ipfs://permanent-placeholder.json");
    }

    function testFuzz_revealSeedCanOnlyBeSetOnce(bytes32 seed) public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(collection));
        emit LoomCollection.Revealed(seed);
        collection.setRevealSeed(seed);
        assertTrue(collection.revealSeedSet());
        assertEq(collection.revealSeed(), seed);
        vm.expectRevert(LoomCollection.RevealSeedAlreadySet.selector);
        collection.setRevealSeed(keccak256("replacement"));
        vm.stopPrank();
    }

    function test_zeroSeedStillConsumesTheOneShot() public {
        vm.startPrank(owner);
        collection.setRevealSeed(bytes32(0));
        vm.expectRevert(LoomCollection.RevealSeedAlreadySet.selector);
        collection.setRevealSeed(bytes32(0));
        vm.stopPrank();
    }

    function test_revealSeedIsARecordAndDoesNotShuffleTokenURIs() public {
        _mint(collection, alice, 1);
        vm.startPrank(owner);
        collection.setBaseURI("ipfs://art/");
        collection.setRevealSeed(keccak256("off-chain seed"));
        vm.stopPrank();
        assertEq(collection.tokenURI(1), "ipfs://art/1.json");
    }

    function testFuzz_provenanceOnlyOnceBeforeMint(bytes32 provenance) public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(collection));
        emit LoomCollection.ProvenanceSet(provenance);
        collection.setProvenanceHash(provenance);
        assertEq(collection.provenanceHash(), provenance);
        assertTrue(collection.provenanceSet());
        vm.expectRevert(LoomCollection.ProvenanceAlreadySet.selector);
        collection.setProvenanceHash(provenance);
        vm.stopPrank();
    }

    function test_zeroProvenanceStillConsumesTheOneShot() public {
        vm.startPrank(owner);
        collection.setProvenanceHash(bytes32(0));
        vm.expectRevert(LoomCollection.ProvenanceAlreadySet.selector);
        collection.setProvenanceHash(keccak256("replacement"));
        vm.stopPrank();
    }

    function test_provenanceCannotBeSetAfterPublicMint() public {
        _mint(collection, alice, 1);
        vm.prank(owner);
        vm.expectRevert(LoomCollection.MintingAlreadyStarted.selector);
        collection.setProvenanceHash(keccak256("too late"));
    }

    function test_provenanceCannotBeSetAfterReserveMint() public {
        _reserveMint(collection, owner, 1);
        vm.prank(owner);
        vm.expectRevert(LoomCollection.MintingAlreadyStarted.selector);
        collection.setProvenanceHash(keccak256("too late"));
    }

    function test_onlyOwnerCanAdministerCollection() public {
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(collection.setBaseURI, ("ipfs://attack/"));
        calls[1] = abi.encodeCall(collection.setUnrevealedURI, ("ipfs://attack"));
        calls[2] = abi.encodeCall(collection.setProvenanceHash, (keccak256("attack")));
        calls[3] = abi.encodeCall(collection.setRevealSeed, (keccak256("attack")));
        calls[4] = abi.encodeCall(collection.freezeMetadata, ());
        calls[5] = abi.encodeCall(collection.pause, ());
        calls[6] = abi.encodeCall(collection.unpause, ());
        calls[7] = abi.encodeCall(collection.transferOwnership, (alice));
        calls[8] = abi.encodeCall(collection.renounceOwnership, ());
        address[4] memory unauthorized = [alice, creator, pauser, address(factory)];
        for (uint256 j; j < unauthorized.length; ++j) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(unauthorized[j]);
                (bool success, bytes memory reason) = address(collection).call(calls[i]);
                assertFalse(success);
                assertEq(
                    reason,
                    abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, unauthorized[j])
                );
            }
        }
    }

    function test_ownershipRequiresAcceptanceAndDoesNotChangeCreatorOrRoyalty() public {
        vm.prank(owner);
        collection.transferOwnership(bob);
        assertEq(collection.owner(), owner);
        assertEq(collection.pendingOwner(), bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bob));
        collection.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        collection.acceptOwnership();
        vm.prank(bob);
        collection.acceptOwnership();
        assertEq(collection.owner(), bob);
        assertEq(collection.pendingOwner(), address(0));
        assertEq(collection.creator(), creator);
        (address receiver, uint256 royalty) = collection.royaltyInfo(1, 1 ether);
        assertEq(receiver, creator);
        assertEq(royalty, 0.05 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        collection.setBaseURI("ipfs://old-owner/");
        vm.prank(bob);
        collection.setBaseURI("ipfs://new-owner/");
    }

    function test_renouncingOwnershipClearsPendingOwnerAndLeavesMintingAvailable() public {
        vm.startPrank(owner);
        collection.transferOwnership(bob);
        collection.renounceOwnership();
        vm.stopPrank();
        assertEq(collection.owner(), address(0));
        assertEq(collection.pendingOwner(), address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, bob));
        collection.acceptOwnership();
        _mint(collection, alice, 1);
    }

    function testFuzz_royaltiesUseFullPrecisionAndStayWithinCap(uint256 salePrice, uint96 bps) public {
        bps = uint96(bound(bps, 0, 1000));
        LoomCollection target = _create(owner, 100, 0, 10, creator, bps);
        (address receiver, uint256 amount) = target.royaltyInfo(999, salePrice);
        uint256 expected = (salePrice / 10_000) * bps + (salePrice % 10_000) * bps / 10_000;
        assertEq(receiver, creator);
        assertEq(amount, expected);
        assertLe(amount, salePrice / 10);
    }

    function test_maxRoyaltyAtMaxSalePriceDoesNotOverflow() public {
        LoomCollection target = _create(owner, 100, 0, 10, creator, 1000);
        (, uint256 amount) = target.royaltyInfo(1, type(uint256).max);
        assertEq(amount, type(uint256).max / 10);
    }

    function test_supportsERC165ERC721MetadataAndERC2981() public view {
        assertTrue(collection.supportsInterface(0x01ffc9a7));
        assertTrue(collection.supportsInterface(0x80ac58cd));
        assertTrue(collection.supportsInterface(0x5b5e139f));
        assertTrue(collection.supportsInterface(0x2a55205a));
        assertFalse(collection.supportsInterface(0xffffffff));
        assertFalse(collection.supportsInterface(0x780e9d63));
    }

    function test_ERC721ApprovalsTransfersAndApprovalClearing() public {
        _mint(collection, alice, 2);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, 1));
        collection.transferFrom(alice, bob, 1);
        vm.prank(alice);
        collection.approve(bob, 1);
        assertEq(collection.getApproved(1), bob);
        vm.prank(bob);
        collection.transferFrom(alice, bob, 1);
        assertEq(collection.getApproved(1), address(0));
        assertEq(collection.ownerOf(1), bob);
        vm.prank(alice);
        collection.setApprovalForAll(bob, true);
        vm.prank(bob);
        collection.safeTransferFrom(alice, bob, 2);
        assertEq(collection.balanceOf(bob), 2);
        assertEq(collection.totalSupply(), 2);
        assertEq(collection.mintedPerWallet(alice), 2);
    }
}
