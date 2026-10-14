// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoomCollection} from "../../src/LoomCollection.sol";

/// @dev Stateful test actions over two independent collections and four distinct wallets.
contract LoomHandler is Test {
    LoomCollection[2] public targets;
    address[4] public actors;
    uint256[2] public publicMinted;
    uint256[2] public reserved;
    uint256 public paid;

    constructor(LoomCollection first, LoomCollection second, address[4] memory wallets) {
        targets[0] = first;
        targets[1] = second;
        actors = wallets;
    }

    function mint(uint256 which, uint256 who, uint256 rawQuantity) external {
        which %= 2;
        LoomCollection target = targets[which];
        address minter = actors[who % 4];
        if (target.paused()) return;
        uint256 available = target.maxSupply() - target.totalSupply();
        uint256 allowance = target.maxPerWallet() - target.mintedPerWallet(minter);
        if (allowance < available) available = allowance;
        if (available == 0) return;
        if (available > 5) available = 5;
        uint256 quantity = bound(rawQuantity, 1, available);
        uint256 payment = (target.mintPriceWei() + target.PLATFORM_FEE()) * quantity;
        uint256 otherSupply = targets[1 - which].totalSupply();
        vm.deal(minter, minter.balance + payment);
        vm.prank(minter);
        target.mint{value: payment}(quantity);
        publicMinted[which] += quantity;
        paid += payment;
        assertEq(targets[1 - which].totalSupply(), otherSupply, "mint leaked into other clone");
    }

    function reserveMint(uint256 which, uint256 rawQuantity) external {
        which %= 2;
        LoomCollection target = targets[which];
        if (target.paused()) return;
        uint256 available = target.maxSupply() - target.totalSupply();
        uint256 allowance = target.maxSupply() / 100 - target.reserveMinted();
        if (allowance < available) available = allowance;
        if (available == 0) return;
        uint256 quantity = bound(rawQuantity, 1, available);
        uint256 payment = (target.mintPriceWei() + target.PLATFORM_FEE()) * quantity;
        uint256 otherSupply = targets[1 - which].totalSupply();
        address collectionOwner = target.owner();
        vm.deal(collectionOwner, collectionOwner.balance + payment);
        vm.prank(collectionOwner);
        target.reserveMint{value: payment}(quantity);
        reserved[which] += quantity;
        paid += payment;
        assertEq(targets[1 - which].totalSupply(), otherSupply, "reserve leaked into other clone");
    }

    function transfer(uint256 which, uint256 rawId, uint256 who) external {
        LoomCollection target = targets[which % 2];
        if (target.totalSupply() == 0) return;
        uint256 tokenId = bound(rawId, 1, target.totalSupply());
        address holder = target.ownerOf(tokenId);
        vm.prank(holder);
        target.transferFrom(holder, actors[who % 4], tokenId);
    }

    function togglePause(uint256 which) external {
        which %= 2;
        LoomCollection target = targets[which];
        bool otherPaused = targets[1 - which].paused();
        bool paused = target.paused();
        vm.prank(target.owner());
        if (paused) target.unpause();
        else target.pause();
        assertEq(targets[1 - which].paused(), otherPaused, "pause leaked into other clone");
    }

    function metadata(uint256 which, bytes32 value) external {
        which %= 2;
        LoomCollection target = targets[which];
        if (target.metadataFrozen()) return;
        bytes32 otherBase = keccak256(bytes(targets[1 - which].baseURI()));
        bytes32 otherSeed = targets[1 - which].revealSeed();
        bytes32 otherProvenance = targets[1 - which].provenanceHash();
        vm.startPrank(target.owner());
        if (target.totalSupply() == 0 && !target.provenanceSet()) target.setProvenanceHash(value);
        if (!target.revealSeedSet()) target.setRevealSeed(value);
        target.setBaseURI(string.concat("ipfs://", vm.toString(value), "/"));
        target.setUnrevealedURI("ipfs://hidden.json");
        vm.stopPrank();
        assertEq(keccak256(bytes(targets[1 - which].baseURI())), otherBase, "URI leaked into other clone");
        assertEq(targets[1 - which].revealSeed(), otherSeed, "seed leaked into other clone");
        assertEq(targets[1 - which].provenanceHash(), otherProvenance, "provenance leaked into other clone");
    }

    function freeze(uint256 which) external {
        which %= 2;
        LoomCollection target = targets[which];
        if (target.metadataFrozen()) return;
        bool otherFrozen = targets[1 - which].metadataFrozen();
        vm.prank(target.owner());
        target.freezeMetadata();
        assertEq(targets[1 - which].metadataFrozen(), otherFrozen, "freeze leaked into other clone");
    }

    function wrongPayment(uint256 which, uint256 who) external {
        LoomCollection target = targets[which % 2];
        uint256 previousSupply = target.totalSupply();
        address minter = actors[who % 4];
        uint256 previousMints = target.mintedPerWallet(minter);
        uint256 payment = target.mintPriceWei() + target.PLATFORM_FEE() + 1;
        vm.deal(minter, minter.balance + payment);
        vm.prank(minter);
        (bool success,) = address(target).call{value: payment}(abi.encodeCall(target.mint, (1)));
        assertFalse(success, "overpayment accepted");
        assertEq(target.totalSupply(), previousSupply);
        assertEq(target.mintedPerWallet(minter), previousMints);
    }
}
