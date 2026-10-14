// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase} from "./helpers/LoomTestBase.sol";
import {CallbackReceiver} from "./helpers/CallbackReceiver.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LoomCollection} from "../src/LoomCollection.sol";
import {LoomFactory} from "../src/LoomFactory.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract LoomAdversarialTest is LoomTestBase {
    function test_receiverCannotReenterPublicMintAndSeesEntireBatchReserved() public {
        CallbackReceiver receiver = new CallbackReceiver();
        vm.deal(address(receiver), 1 ether);
        receiver.arm(address(collection), abi.encodeCall(collection.mint, (1)), PRICE + FEE, false, true);
        receiver.execute(address(collection), abi.encodeCall(collection.mint, (2)), (PRICE + FEE) * 2);
        _assertCollectionGuard(receiver);
        assertEq(receiver.supplySeen(), 2);
        assertEq(receiver.publicMintsSeen(), 2);
        assertEq(collection.totalSupply(), 2);
        assertEq(collection.mintedPerWallet(address(receiver)), 2);
        assertEq(collection.balanceOf(address(receiver)), 2);
    }

    function test_receiverCannotReenterReserveMint() public {
        CallbackReceiver receiver = new CallbackReceiver();
        vm.deal(address(receiver), 1 ether);
        LoomCollection target = _ownedBy(receiver);
        receiver.arm(address(target), abi.encodeCall(target.reserveMint, (1)), PRICE + FEE, false, true);
        receiver.execute(address(target), abi.encodeCall(target.reserveMint, (2)), (PRICE + FEE) * 2);
        _assertCollectionGuard(receiver);
        assertEq(receiver.supplySeen(), 2);
        assertEq(receiver.reserveMintsSeen(), 2);
        assertEq(target.reserveMinted(), 2);
    }

    function test_receiverCannotReenterReserveMintFromPublicMint() public {
        CallbackReceiver receiver = new CallbackReceiver();
        vm.deal(address(receiver), 1 ether);
        LoomCollection target = _ownedBy(receiver);
        receiver.arm(address(target), abi.encodeCall(target.reserveMint, (1)), PRICE + FEE, false, true);
        receiver.execute(address(target), abi.encodeCall(target.mint, (2)), (PRICE + FEE) * 2);
        _assertCollectionGuard(receiver);
        assertEq(target.reserveMinted(), 0);
        assertEq(target.totalSupply(), 2);
    }

    function test_receiverCannotReenterPublicMintFromReserveMint() public {
        CallbackReceiver receiver = new CallbackReceiver();
        vm.deal(address(receiver), 1 ether);
        LoomCollection target = _ownedBy(receiver);
        receiver.arm(address(target), abi.encodeCall(target.mint, (1)), PRICE + FEE, false, true);
        receiver.execute(address(target), abi.encodeCall(target.reserveMint, (2)), (PRICE + FEE) * 2);
        _assertCollectionGuard(receiver);
        assertEq(target.mintedPerWallet(address(receiver)), 0);
        assertEq(target.totalSupply(), 2);
    }

    function test_allThreeETHRecipientsCannotReenterMint() public {
        for (uint256 role; role < 3; ++role) {
            CallbackReceiver receiver = new CallbackReceiver();
            vm.deal(address(receiver), 1 ether);
            LoomCollection target = _withRecipient(receiver, role);
            receiver.arm(address(target), abi.encodeCall(target.mint, (1)), PRICE + FEE, true, false);
            _mint(target, alice, 2);
            _assertCollectionGuard(receiver);
            assertEq(target.totalSupply(), 2);
            assertEq(target.mintedPerWallet(address(receiver)), 0);
            assertEq(address(target).balance, 0);
        }
    }

    function test_eachRejectedPaymentRollsBackMintTokensAllowancesAndEarlierPayouts() public {
        for (uint256 role; role < 3; ++role) {
            CallbackReceiver receiver = new CallbackReceiver();
            receiver.rejectETH(true);
            LoomCollection target = _withRecipient(receiver, role);
            uint256 aliceBefore = alice.balance;
            uint256 creatorBefore = creator.balance;
            uint256 platformBefore = platform.balance;
            uint256 reserveBefore = reserve.balance;
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(LoomCollection.ETHTransferFailed.selector, address(receiver)));
            target.mint{value: (PRICE + FEE) * 2}(2);
            assertEq(alice.balance, aliceBefore);
            assertEq(creator.balance, creatorBefore);
            assertEq(platform.balance, platformBefore);
            assertEq(reserve.balance, reserveBefore);
            assertEq(address(target).balance, 0);
            assertEq(target.totalSupply(), 0);
            assertEq(target.mintedPerWallet(alice), 0);
            assertEq(target.balanceOf(alice), 0);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
            target.ownerOf(1);
            // A failed payout leaves no debt and does not poison the reentrancy guard.
            receiver.rejectETH(false);
            _mint(target, alice, 1);
            assertEq(target.totalSupply(), 1);
        }
    }

    function test_rejectedReservePaymentRollsBackReserveAllowance() public {
        CallbackReceiver receiver = new CallbackReceiver();
        receiver.rejectETH(true);
        LoomCollection target = _withRecipient(receiver, 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.ETHTransferFailed.selector, address(receiver)));
        target.reserveMint{value: PRICE + FEE}(1);
        assertEq(target.reserveMinted(), 0);
        assertEq(target.totalSupply(), 0);
        receiver.rejectETH(false);
        _reserveMint(target, owner, 1);
        assertEq(target.reserveMinted(), 1);
    }

    function test_secondRejectedNFTCallbackRollsBackTheWholeBatch() public {
        CallbackReceiver receiver = new CallbackReceiver();
        vm.deal(address(receiver), 1 ether);
        receiver.rejectNFT(2);
        uint256 platformBefore = platform.balance;
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(receiver)));
        receiver.execute(address(collection), abi.encodeCall(collection.mint, (2)), (PRICE + FEE) * 2);
        assertEq(collection.totalSupply(), 0);
        assertEq(collection.mintedPerWallet(address(receiver)), 0);
        assertEq(collection.balanceOf(address(receiver)), 0);
        assertEq(receiver.nftCallbacks(), 0);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(creator.balance, 0);
        assertEq(reserve.balance, 0);
        assertEq(platform.balance, platformBefore);
        receiver.rejectNFT(0);
        receiver.execute(address(collection), abi.encodeCall(collection.mint, (2)), (PRICE + FEE) * 2);
        assertEq(collection.totalSupply(), 2);
    }

    function test_forwardingTokensDuringCallbacksCannotResetWalletAllowance() public {
        CallbackReceiver receiver = new CallbackReceiver();
        vm.deal(address(receiver), 1 ether);
        receiver.forwardNFT(bob);
        receiver.execute(address(collection), abi.encodeCall(collection.mint, (20)), (PRICE + FEE) * 20);
        assertEq(collection.balanceOf(address(receiver)), 0);
        assertEq(collection.balanceOf(bob), 20);
        assertEq(collection.mintedPerWallet(address(receiver)), 20);
        vm.expectRevert(LoomCollection.WalletCapExceeded.selector);
        receiver.execute(address(collection), abi.encodeCall(collection.mint, (1)), PRICE + FEE);
    }

    function test_provenanceCannotBeSetFromTheFirstMintCallback() public {
        CallbackReceiver receiver = new CallbackReceiver();
        vm.deal(address(receiver), 1 ether);
        LoomCollection target = _ownedBy(receiver);
        receiver.arm(address(target), abi.encodeCall(target.setProvenanceHash, (keccak256("too late"))), 0, false, true);
        receiver.execute(address(target), abi.encodeCall(target.mint, (1)), PRICE + FEE);
        assertFalse(receiver.succeeded());
        assertEq(receiver.result(), abi.encodeWithSelector(LoomCollection.MintingAlreadyStarted.selector));
        assertFalse(target.provenanceSet());
    }

    function test_rejectedCreateFeeRollsBackCloneAndRegistryThenCanRetry() public {
        CallbackReceiver receiver = new CallbackReceiver();
        LoomCollection impl = new LoomCollection(address(receiver), reserve);
        LoomFactory target = new LoomFactory(address(impl), address(receiver), pauser);
        receiver.rejectETH(true);
        uint256 beforeAlice = alice.balance;
        address predicted = vm.computeCreateAddress(address(target), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.ETHTransferFailed.selector, address(receiver)));
        target.createCollection{value: CREATE_FEE}("Art", "ART", 100, 0, 1, creator, 500);
        assertEq(alice.balance, beforeAlice);
        assertEq(target.collectionCount(), 0);
        assertFalse(target.isCollection(predicted));
        assertEq(predicted.code.length, 0);
        assertEq(address(target).balance, 0);
        receiver.rejectETH(false);
        vm.prank(alice);
        address deployed = target.createCollection{value: CREATE_FEE}("Art", "ART", 100, 0, 1, creator, 500);
        assertEq(deployed, predicted);
        assertEq(target.collectionCount(), 1);
        assertEq(address(receiver).balance, CREATE_FEE);
    }

    function test_platformCannotReenterFactoryCreation() public {
        CallbackReceiver receiver = new CallbackReceiver();
        vm.deal(address(receiver), 1 ether);
        LoomCollection impl = new LoomCollection(address(receiver), reserve);
        LoomFactory target = new LoomFactory(address(impl), address(receiver), pauser);
        bytes memory nested = abi.encodeCall(target.createCollection, ("Attack", "BAD", 100, 0, 1, creator, 500));
        receiver.arm(address(target), nested, CREATE_FEE, true, false);
        vm.prank(alice);
        address deployed = target.createCollection{value: CREATE_FEE}("Art", "ART", 100, 0, 1, creator, 500);
        assertEq(receiver.attempts(), 1);
        assertFalse(receiver.succeeded());
        assertEq(receiver.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(target.collectionCount(), 1);
        assertEq(LoomCollection(deployed).owner(), alice);
    }

    function test_forcedETHCannotSubsidizeIncorrectPaymentsOrChangeSplits() public {
        vm.deal(address(collection), 2 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, PRICE + FEE, 0));
        collection.mint(1);
        _mint(collection, alice, 1);
        assertEq(address(collection).balance, 2 ether);
        assertEq(creator.balance, PRICE + 0.0002 ether);
        vm.deal(address(factory), 2 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.IncorrectCreateFee.selector, CREATE_FEE, 0));
        factory.createCollection("Art", "ART", 100, 0, 1, creator, 500);
        _create(alice, 100, 0, 1, creator, 500);
        assertEq(address(factory).balance, 2 ether);
    }

    function _ownedBy(CallbackReceiver receiver) private returns (LoomCollection target) {
        target = _blankClone();
        target.initialize("Contract Owner", "OWN", 1000, PRICE, 20, creator, 500, address(receiver));
    }

    function _withRecipient(CallbackReceiver receiver, uint256 role) private returns (LoomCollection target) {
        LoomCollection impl =
            new LoomCollection(role == 1 ? address(receiver) : platform, role == 2 ? address(receiver) : reserve);
        target = LoomCollection(Clones.clone(address(impl)));
        target.initialize("Callback", "CALL", 1000, PRICE, 20, role == 0 ? address(receiver) : creator, 500, owner);
    }

    function _assertCollectionGuard(CallbackReceiver receiver) private view {
        assertEq(receiver.attempts(), 1);
        assertFalse(receiver.succeeded());
        assertEq(
            receiver.result(), abi.encodeWithSelector(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector)
        );
    }
}
