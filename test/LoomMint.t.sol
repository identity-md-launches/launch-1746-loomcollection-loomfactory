// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase} from "./helpers/LoomTestBase.sol";
import {LoomCollection} from "../src/LoomCollection.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {stdError} from "forge-std/StdError.sol";

contract LoomMintTest is LoomTestBase {
    function test_exactFeesAndSequentialTokenIds() public {
        uint256 platformBefore = platform.balance;
        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(collection));
        emit LoomCollection.Minted(alice, 1, 3);
        vm.expectEmit(false, false, false, true, address(collection));
        emit LoomCollection.FeesDistributed(3 * (PRICE + 0.0002 ether), 0.0006 ether, 0.0003 ether);
        _mint(collection, alice, 3);
        assertEq(creator.balance, 3 * PRICE + 0.0006 ether);
        assertEq(platform.balance - platformBefore, 0.0006 ether);
        assertEq(reserve.balance, 0.0003 ether);
        assertEq(aliceBefore - alice.balance, 3 * (PRICE + FEE));
        assertEq(address(collection).balance, 0);
        assertEq(collection.totalSupply(), 3);
        assertEq(collection.balanceOf(alice), 3);
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(collection.ownerOf(id), alice);
        }
        _mint(collection, bob, 1);
        assertEq(collection.ownerOf(4), bob);
    }

    function test_freeCreatorPriceStillPaysPlatformFee() public {
        LoomCollection free = _create(owner, 10, 0, 10, creator, 0);
        uint256 beforePlatform = platform.balance;
        _mint(free, alice, 2);
        assertEq(creator.balance, 0.0004 ether);
        assertEq(platform.balance - beforePlatform, 0.0004 ether);
        assertEq(reserve.balance, 0.0002 ether);
        assertEq(address(free).balance, 0);
    }

    function testFuzz_splitAndCreatorPriceConservePayment(uint128 price, uint8 rawQuantity) public {
        uint256 quantity = bound(rawQuantity, 1, 20);
        LoomCollection target = _create(owner, 1000, price, 20, creator, 500);
        uint256 payment = (uint256(price) + FEE) * quantity;
        vm.deal(alice, payment);
        uint256 platformBefore = platform.balance;
        _mint(target, alice, quantity);
        assertEq(creator.balance, (uint256(price) + 0.0002 ether) * quantity);
        assertEq(platform.balance - platformBefore, 0.0002 ether * quantity);
        assertEq(reserve.balance, 0.0001 ether * quantity);
        assertEq(creator.balance + platform.balance - platformBefore + reserve.balance, payment);
        assertEq(address(target).balance, 0);
        assertEq(alice.balance, 0);
    }

    function testFuzz_anyIncorrectPaymentReverts(uint256 payment) public {
        uint256 expected = (PRICE + FEE) * 2;
        payment = bound(payment, 0, 100 ether);
        if (payment == expected) ++payment;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, expected, payment));
        collection.mint{value: payment}(2);
        assertEq(collection.totalSupply(), 0);
        assertEq(collection.mintedPerWallet(alice), 0);
    }

    function test_rejectsUnderpaymentAndOverpaymentByOneWei() public {
        uint256 expected = PRICE + FEE;
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, expected, expected - 1));
        collection.mint{value: expected - 1}(1);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, expected, expected + 1));
        collection.mint{value: expected + 1}(1);
        vm.stopPrank();
        assertEq(collection.totalSupply(), 0);
    }

    function test_rejectsZeroQuantity() public {
        vm.prank(alice);
        vm.expectRevert(LoomCollection.ZeroQuantity.selector);
        collection.mint(0);
        vm.prank(owner);
        vm.expectRevert(LoomCollection.ZeroQuantity.selector);
        collection.reserveMint(0);
    }

    function test_walletAllowanceIsLifetimeAndTransfersCannotRestoreIt() public {
        _mint(collection, alice, 20);
        vm.prank(alice);
        collection.transferFrom(alice, bob, 1);
        assertEq(collection.balanceOf(alice), 19);
        assertEq(collection.mintedPerWallet(alice), 20);
        vm.prank(alice);
        vm.expectRevert(LoomCollection.WalletCapExceeded.selector);
        collection.mint{value: PRICE + FEE}(1);
        _mint(collection, bob, 20);
        assertEq(collection.balanceOf(bob), 21);
        assertEq(collection.mintedPerWallet(bob), 20);
    }

    function testFuzz_walletCapAccumulatesAcrossBatches(uint8 first) public {
        uint256 quantity = bound(first, 1, 19);
        _mint(collection, alice, quantity);
        _mint(collection, alice, 20 - quantity);
        vm.prank(alice);
        vm.expectRevert(LoomCollection.WalletCapExceeded.selector);
        collection.mint{value: PRICE + FEE}(1);
        assertEq(collection.mintedPerWallet(alice), 20);
    }

    function test_hardSupplyCapAcrossWallets() public {
        LoomCollection small = _create(owner, 3, PRICE, 2, creator, 500);
        _mint(small, alice, 2);
        _mint(small, bob, 1);
        vm.prank(bob);
        vm.expectRevert(LoomCollection.SupplyCapExceeded.selector);
        small.mint{value: PRICE + FEE}(1);
        assertEq(small.totalSupply(), 3);
    }

    function test_reserveHasSeparateOnePercentAllowanceAndSameFees() public {
        uint256 platformBefore = platform.balance;
        _reserveMint(collection, owner, 10);
        assertEq(collection.reserveMinted(), 10);
        assertEq(collection.totalSupply(), 10);
        assertEq(collection.balanceOf(owner), 10);
        assertEq(collection.mintedPerWallet(owner), 0);
        assertEq(creator.balance, (PRICE + 0.0002 ether) * 10);
        assertEq(platform.balance - platformBefore, 0.002 ether);
        assertEq(reserve.balance, 0.001 ether);
        _mint(collection, owner, 20);
        assertEq(collection.balanceOf(owner), 30);
        vm.prank(owner);
        vm.expectRevert(LoomCollection.ReserveCapExceeded.selector);
        collection.reserveMint{value: PRICE + FEE}(1);
    }

    function test_reserveRequiresExactPaymentAndOwner() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, PRICE + FEE, 0));
        collection.reserveMint(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, alice));
        collection.reserveMint{value: PRICE + FEE}(1);
        assertEq(collection.reserveMinted(), 0);
    }

    function testFuzz_reserveLimitRoundsDown(uint16 rawSupply) public {
        uint256 supply = bound(rawSupply, 1, 1999);
        LoomCollection target = _create(owner, supply, 0, supply, creator, 0);
        uint256 limit = supply / 100;
        if (limit > 0) _reserveMint(target, owner, limit);
        vm.prank(owner);
        vm.expectRevert(LoomCollection.ReserveCapExceeded.selector);
        target.reserveMint{value: FEE}(1);
        assertEq(target.totalSupply(), limit);
    }

    function test_ownershipTransferCannotResetReserveAllowance() public {
        _reserveMint(collection, owner, 10);
        vm.prank(owner);
        collection.transferOwnership(bob);
        vm.prank(bob);
        collection.acceptOwnership();
        vm.prank(bob);
        vm.expectRevert(LoomCollection.ReserveCapExceeded.selector);
        collection.reserveMint{value: PRICE + FEE}(1);
    }

    function test_publicAndReserveMintsShareHardSupplyLimit() public {
        LoomCollection small = _create(owner, 100, 0, 100, creator, 0);
        _reserveMint(small, owner, 1);
        _mint(small, alice, 99);
        vm.prank(bob);
        vm.expectRevert(LoomCollection.SupplyCapExceeded.selector);
        small.mint{value: FEE}(1);
        assertEq(small.totalSupply(), 100);
    }

    function test_reserveCannotMintPastPublicSellout() public {
        LoomCollection small = _create(owner, 100, 0, 100, creator, 0);
        _mint(small, alice, 100);
        vm.prank(owner);
        vm.expectRevert(LoomCollection.SupplyCapExceeded.selector);
        small.reserveMint{value: FEE}(1);
    }

    function test_pauseBlocksBothMintPathsButTransfersRemainAvailable() public {
        _mint(collection, alice, 1);
        vm.prank(owner);
        collection.pause();
        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        collection.mint{value: PRICE + FEE}(1);
        vm.prank(owner);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        collection.reserveMint{value: PRICE + FEE}(1);
        vm.prank(alice);
        collection.transferFrom(alice, bob, 1);
        assertEq(collection.ownerOf(1), bob);
        vm.prank(owner);
        collection.unpause();
        _mint(collection, alice, 1);
        _reserveMint(collection, owner, 1);
        assertEq(collection.totalSupply(), 3);
    }

    function test_overflowingBatchPriceRevertsWithoutChangingState() public {
        LoomCollection target = _create(owner, 10, type(uint256).max - FEE, 10, creator, 0);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        target.mint(2);
        assertEq(target.totalSupply(), 0);
    }

    function test_coincidentFeeRecipientsReceiveExactCombinedAmount() public {
        LoomCollection sharedImplementation = new LoomCollection(creator, creator);
        LoomCollection target = LoomCollection(Clones.clone(address(sharedImplementation)));
        target.initialize("Shared", "ONE", 100, PRICE, 10, creator, 500, owner);
        _mint(target, alice, 2);
        assertEq(creator.balance, 2 * (PRICE + FEE));
        assertEq(address(target).balance, 0);
    }

    function test_batchAndIndividualMintsHaveIdenticalFees() public {
        uint256 platformBefore = platform.balance;
        _mint(collection, alice, 3);
        uint256 creatorBatch = creator.balance;
        uint256 platformBatch = platform.balance - platformBefore;
        uint256 reserveBatch = reserve.balance;
        for (uint256 i; i < 3; ++i) {
            _mint(collection, bob, 1);
        }
        assertEq(creator.balance, creatorBatch * 2);
        assertEq(platform.balance - platformBefore, platformBatch * 2);
        assertEq(reserve.balance, reserveBatch * 2);
    }
}
