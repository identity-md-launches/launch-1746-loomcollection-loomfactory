// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase} from "./helpers/LoomTestBase.sol";
import {CallbackReceiver} from "./helpers/CallbackReceiver.sol";
import {LoomCollection} from "src/LoomCollection.sol";
import {LoomFactory} from "src/LoomFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Properties use independent literal fee expectations rather than reading the implementation's shares.
contract LoomClonePropertiesTest is LoomTestBase {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partitioningMintsAcrossTwoClonesCannotCreateFeeDust(
        uint128 price,
        uint8 rawQuantity,
        uint8 rawFirst,
        bool reserved
    ) public {
        uint256 quantity = bound(rawQuantity, 2, reserved ? 10 : 25);
        uint256 first = bound(rawFirst, 1, quantity - 1);
        address otherCreator = makeAddr("partition creator");
        LoomCollection batch = _create(owner, 1000, price, 25, creator, 1);
        LoomCollection split = _create(bob, 1000, price, 25, otherCreator, 999);
        uint256 payment = (uint256(price) + FEE) * quantity;
        address batchMinter = reserved ? owner : alice;
        address splitMinter = reserved ? bob : alice;
        vm.deal(batchMinter, payment * 2);
        vm.deal(splitMinter, payment * 2);
        uint256 platformBefore = platform.balance;
        uint256 reserveBefore = reserve.balance;

        if (reserved) _reserveMint(batch, batchMinter, quantity);
        else _mint(batch, batchMinter, quantity);
        uint256 platformBatch = platform.balance - platformBefore;
        uint256 reserveBatch = reserve.balance - reserveBefore;
        if (reserved) {
            _reserveMint(split, splitMinter, first);
            _reserveMint(split, splitMinter, quantity - first);
        } else {
            _mint(split, splitMinter, first);
            _mint(split, splitMinter, quantity - first);
        }

        assertEq(creator.balance, (uint256(price) + 200_000_000_000_000) * quantity);
        assertEq(otherCreator.balance, creator.balance);
        assertEq(platformBatch, 200_000_000_000_000 * quantity);
        assertEq(reserveBatch, 100_000_000_000_000 * quantity);
        assertEq(platform.balance - platformBefore, 2 * platformBatch);
        assertEq(reserve.balance - reserveBefore, 2 * reserveBatch);
        assertEq(creator.balance + platformBatch + reserveBatch, payment);
        assertEq(address(batch).balance, 0);
        assertEq(address(split).balance, 0);
        assertEq(batch.totalSupply(), quantity);
        assertEq(split.totalSupply(), quantity);
        assertEq(batch.reserveMinted(), reserved ? quantity : 0);
        assertEq(split.reserveMinted(), reserved ? quantity : 0);
        assertEq(batch.mintedPerWallet(batchMinter), reserved ? 0 : quantity);
        assertEq(split.mintedPerWallet(splitMinter), reserved ? 0 : quantity);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_reinitializationCannotRewriteEitherLiveClone(
        uint256 supply,
        uint256 price,
        uint256 cap,
        uint96 royalty,
        bytes32 replacement,
        uint8 callerChoice
    ) public {
        LoomCollection second = _create(bob, 199, 1, 7, alice, 1000);
        vm.startPrank(owner);
        collection.setProvenanceHash(keccak256("first provenance"));
        collection.setRevealSeed(keccak256("first reveal"));
        collection.setBaseURI("ipfs://first/");
        collection.setUnrevealedURI("ipfs://first-hidden.json");
        collection.freezeMetadata();
        collection.transferOwnership(alice);
        vm.stopPrank();
        vm.prank(alice);
        collection.acceptOwnership();
        _mint(collection, bob, 2);
        _reserveMint(collection, alice, 1);
        vm.prank(alice);
        collection.pause();
        _mint(second, owner, 1);
        vm.prank(owner);
        second.approve(alice, 1);

        LoomCollection[3] memory targets = [collection, second, implementation];
        address[4] memory callers = [owner, alice, bob, address(factory)];
        bytes32[3] memory beforeState;
        for (uint256 i; i < targets.length; ++i) {
            beforeState[i] = _state(targets[i]);
        }
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(callers[callerChoice % callers.length]);
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            targets[i].initialize(vm.toString(replacement), "REPLAY", supply, price, cap, bob, royalty, owner);
        }
        for (uint256 i; i < targets.length; ++i) {
            assertEq(_state(targets[i]), beforeState[i]);
        }
        assertEq(collection.ownerOf(1), bob);
        assertEq(collection.ownerOf(3), alice);
        assertEq(second.ownerOf(1), owner);
        assertEq(second.getApproved(1), alice);
        assertEq(factory.collectionCount(), 2);
    }

    function test_createFeeCallbackCannotSeizeTheAlreadyInitializedClone() public {
        CallbackReceiver receiver = new CallbackReceiver();
        LoomCollection impl = new LoomCollection(address(receiver), reserve);
        LoomFactory target = new LoomFactory(address(impl), address(receiver), pauser);
        address predicted = vm.computeCreateAddress(address(target), 1);
        receiver.arm(
            predicted, abi.encodeCall(collection.initialize, ("Stolen", "BAD", 1, 0, 1, bob, 1000, bob)), 0, true, false
        );
        vm.prank(alice);
        address created = target.createCollection{value: CREATE_FEE}("Atomic", "ONE", 100, 1, 5, creator, 500);
        assertEq(created, predicted);
        assertEq(receiver.attempts(), 1);
        assertFalse(receiver.succeeded());
        assertEq(receiver.result(), abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        assertEq(LoomCollection(created).owner(), alice);
        assertEq(LoomCollection(created).creator(), creator);
        assertEq(LoomCollection(created).name(), "Atomic");
        assertEq(target.collections(0), created);
        assertTrue(target.isCollection(created));
        assertEq(address(receiver).balance, CREATE_FEE);
    }

    function test_reentrancyGuardsAreIndependentAcrossClones() public {
        LoomCollection second = _create(bob, 100, 1, 2, creator, 0);
        CallbackReceiver receiver = new CallbackReceiver();
        uint256 payment = 2 * (PRICE + FEE) + FEE + 1;
        vm.deal(address(receiver), payment);
        uint256 beforePlatform = platform.balance;
        receiver.arm(address(second), abi.encodeCall(second.mint, (1)), FEE + 1, false, true);
        receiver.execute(address(collection), abi.encodeCall(collection.mint, (2)), 2 * (PRICE + FEE));
        assertTrue(receiver.succeeded());
        assertEq(receiver.attempts(), 1);
        assertEq(collection.totalSupply(), 2);
        assertEq(second.totalSupply(), 1);
        assertEq(collection.mintedPerWallet(address(receiver)), 2);
        assertEq(second.mintedPerWallet(address(receiver)), 1);
        assertEq(collection.balanceOf(address(receiver)), 2);
        assertEq(second.balanceOf(address(receiver)), 1);
        assertEq(creator.balance, PRICE * 2 + 1 + 0.0006 ether);
        assertEq(platform.balance - beforePlatform, 0.0006 ether);
        assertEq(reserve.balance, 0.0003 ether);
        assertEq(address(receiver).balance, 0);
        assertEq(address(collection).balance + address(second).balance, 0);
    }

    function test_approvalForSameTokenIdDoesNotAuthorizeTheOtherClone() public {
        LoomCollection second = _create(bob, 100, 0, 2, creator, 500);
        _mint(collection, alice, 1);
        _mint(second, alice, 1);
        vm.prank(alice);
        collection.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, 1));
        second.transferFrom(alice, bob, 1);
        vm.prank(alice);
        collection.setApprovalForAll(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, 1));
        second.safeTransferFrom(alice, bob, 1);
        assertEq(second.ownerOf(1), alice);
        assertEq(second.getApproved(1), address(0));
        assertFalse(second.isApprovedForAll(alice, bob));
        vm.prank(bob);
        collection.transferFrom(alice, bob, 1);
        assertEq(collection.ownerOf(1), bob);
    }

    function test_rejectedSafeTransferRestoresOwnerApprovalAndBothCloneBalances() public {
        LoomCollection second = _create(bob, 100, 0, 2, creator, 500);
        CallbackReceiver rejects = new CallbackReceiver();
        rejects.rejectNFT(1);
        LoomCollection[2] memory targets = [collection, second];
        for (uint256 i; i < targets.length; ++i) {
            LoomCollection target = targets[i];
            _mint(target, alice, 1);
            vm.prank(alice);
            target.approve(bob, 1);
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(rejects)));
            target.safeTransferFrom(alice, address(rejects), 1, hex"1234");
            assertEq(target.ownerOf(1), alice);
            assertEq(target.getApproved(1), bob);
            assertEq(target.balanceOf(alice), 1);
            assertEq(target.balanceOf(address(rejects)), 0);
            assertEq(target.mintedPerWallet(alice), 1);
            assertEq(target.totalSupply(), 1);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_royaltyRoundingIsIndependentAcrossClones(uint256 sale, uint96 bpsA, uint96 bpsB) public {
        bpsA = uint96(bound(bpsA, 0, 1000));
        bpsB = uint96(bound(bpsB, 0, 1000));
        LoomCollection first = _create(owner, 100, 1, 2, creator, bpsA);
        LoomCollection second = _create(bob, 100, 0, 2, alice, bpsB);
        (address recipientA, uint256 amountA) = first.royaltyInfo(1, sale);
        (address recipientB, uint256 amountB) = second.royaltyInfo(type(uint256).max, sale);
        // Quotient/remainder oracle avoids duplicating Math.mulDiv or overflowing sale * bps.
        assertEq(amountA, (sale / 10_000) * bpsA + ((sale % 10_000) * bpsA) / 10_000);
        assertEq(amountB, (sale / 10_000) * bpsB + ((sale % 10_000) * bpsB) / 10_000);
        assertEq(recipientA, creator);
        assertEq(recipientB, alice);
        assertLe(amountA, sale / 10);
        assertLe(amountB, sale / 10);
    }

    function test_ownershipCancellationReplacementAndFreezeSurviveHandoverOnBothClones() public {
        LoomCollection second = _create(owner, 200, 0, 3, alice, 0);
        LoomCollection[2] memory targets = [collection, second];
        for (uint256 i; i < targets.length; ++i) {
            LoomCollection target = targets[i];
            vm.startPrank(owner);
            target.setBaseURI("ipfs://permanent/");
            target.freezeMetadata();
            target.transferOwnership(alice);
            target.transferOwnership(address(0));
            vm.stopPrank();
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
            target.acceptOwnership();
            vm.startPrank(owner);
            target.transferOwnership(alice);
            target.transferOwnership(bob);
            vm.stopPrank();
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
            target.acceptOwnership();
            vm.prank(bob);
            target.acceptOwnership();
            vm.prank(bob);
            vm.expectRevert(LoomCollection.MetadataIsFrozen.selector);
            target.setBaseURI("ipfs://replacement/");
            assertEq(target.owner(), bob);
            assertEq(target.pendingOwner(), address(0));
            assertEq(target.baseURI(), "ipfs://permanent/");
            _mint(target, alice, 1);
            assertEq(target.tokenURI(1), "ipfs://permanent/1.json");
        }
    }

    function _state(LoomCollection target) private view returns (bytes32) {
        bytes32 configuration = keccak256(
            abi.encode(
                target.name(),
                target.symbol(),
                target.creator(),
                target.maxSupply(),
                target.mintPriceWei(),
                target.maxPerWallet(),
                target.royaltyBps(),
                target.PLATFORM(),
                target.RESERVE()
            )
        );
        bytes32 accounting = keccak256(
            abi.encode(
                target.owner(),
                target.pendingOwner(),
                target.totalSupply(),
                target.reserveMinted(),
                target.paused(),
                target.balanceOf(alice),
                target.balanceOf(bob),
                target.balanceOf(owner),
                target.mintedPerWallet(alice),
                target.mintedPerWallet(bob),
                target.mintedPerWallet(owner)
            )
        );
        return keccak256(
            abi.encode(
                configuration,
                accounting,
                target.baseURI(),
                target.unrevealedURI(),
                target.provenanceHash(),
                target.revealSeed(),
                target.provenanceSet(),
                target.revealSeedSet(),
                target.metadataFrozen(),
                address(target).balance
            )
        );
    }
}
