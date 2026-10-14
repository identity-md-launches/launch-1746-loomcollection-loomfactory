// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase} from "./helpers/LoomTestBase.sol";
import {LoomCollection} from "../src/LoomCollection.sol";
import {LoomFactory} from "../src/LoomFactory.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract LoomFactoryTest is LoomTestBase {
    function test_creationChargesPlatformAndRegistersAnInitializedMinimalProxy() public {
        uint256 beforePlatform = platform.balance;
        uint256 beforeBob = bob.balance;
        vm.expectEmit(false, true, false, true, address(factory));
        emit LoomFactory.CollectionCreated(address(0), bob, "Second", 200);
        vm.prank(bob);
        address deployed = factory.createCollection{value: CREATE_FEE}("Second", "TWO", 200, 0, 5, alice, 0);
        assertEq(platform.balance - beforePlatform, CREATE_FEE);
        assertEq(beforeBob - bob.balance, CREATE_FEE);
        assertEq(address(factory).balance, 0);
        assertEq(factory.collectionCount(), 2);
        assertEq(factory.collections(0), address(collection));
        assertEq(factory.collections(1), deployed);
        assertTrue(factory.isCollection(deployed));
        assertFalse(factory.isCollection(address(implementation)));
        assertEq(LoomCollection(deployed).owner(), bob);
        assertEq(LoomCollection(deployed).name(), "Second");
        assertEq(deployed.code.length, 45);
        assertEq(
            deployed.code,
            abi.encodePacked(hex"363d3d373d3d3d363d73", address(implementation), hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    function test_creationRequiresExactFeeIncludingNoOverpayment() public {
        uint256 beforePlatform = platform.balance;
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.IncorrectCreateFee.selector, CREATE_FEE, 0));
        factory.createCollection("Art", "ART", 100, 0, 1, creator, 500);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.IncorrectCreateFee.selector, CREATE_FEE, CREATE_FEE - 1));
        factory.createCollection{value: CREATE_FEE - 1}("Art", "ART", 100, 0, 1, creator, 500);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.IncorrectCreateFee.selector, CREATE_FEE, CREATE_FEE + 1));
        factory.createCollection{value: CREATE_FEE + 1}("Art", "ART", 100, 0, 1, creator, 500);
        vm.stopPrank();
        assertEq(factory.collectionCount(), 1);
        assertEq(platform.balance, beforePlatform);
    }

    function testFuzz_rejectsAnyIncorrectCreationFee(uint256 payment) public {
        payment = bound(payment, 0, 100 ether);
        if (payment == CREATE_FEE) ++payment;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LoomFactory.IncorrectCreateFee.selector, CREATE_FEE, payment));
        factory.createCollection{value: payment}("Art", "ART", 100, 0, 1, creator, 500);
        assertEq(factory.collectionCount(), 1);
    }

    function test_invalidCollectionParametersRevertCreationAndFee() public {
        uint256 beforeAlice = alice.balance;
        uint256 beforePlatform = platform.balance;
        vm.prank(alice);
        vm.expectRevert(LoomCollection.RoyaltyTooHigh.selector);
        factory.createCollection{value: CREATE_FEE}("Art", "ART", 100, 0, 1, creator, 1001);
        assertEq(factory.collectionCount(), 1);
        assertEq(alice.balance, beforeAlice);
        assertEq(platform.balance, beforePlatform);
        LoomCollection valid = _create(alice, 100, 0, 1, creator, 1000);
        assertEq(factory.collections(1), address(valid));
    }

    function test_onlyPauserCanPauseOrUnpauseCreation() public {
        vm.prank(alice);
        vm.expectRevert(LoomFactory.UnauthorizedPauser.selector);
        factory.pause();
        vm.prank(owner);
        vm.expectRevert(LoomFactory.UnauthorizedPauser.selector);
        factory.pause();
        vm.prank(pauser);
        factory.pause();
        assertTrue(factory.paused());
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.createCollection{value: CREATE_FEE}("Art", "ART", 100, 0, 1, creator, 500);
        vm.prank(alice);
        vm.expectRevert(LoomFactory.UnauthorizedPauser.selector);
        factory.unpause();
        // Existing clones continue minting while creation is paused.
        _mint(collection, alice, 1);
        vm.prank(pauser);
        factory.unpause();
        _create(alice, 100, 0, 1, creator, 500);
        assertEq(factory.collectionCount(), 2);
    }

    function test_repeatedPauseTransitionsRevert() public {
        vm.startPrank(pauser);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        factory.unpause();
        factory.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.pause();
        vm.stopPrank();
    }

    function test_constructorAcceptsAnUndeployedImplementationButFirstUseRejectsIt() public {
        address noCode = makeAddr("not yet deployed");
        LoomFactory pending = new LoomFactory(noCode, platform, pauser);
        assertEq(pending.implementation(), noCode);
        assertEq(pending.PLATFORM(), platform);
        assertEq(pending.pauser(), pauser);
        vm.prank(alice);
        vm.expectRevert(LoomFactory.InvalidImplementation.selector);
        pending.createCollection{value: CREATE_FEE}("Art", "ART", 100, 0, 1, creator, 500);
        assertEq(pending.collectionCount(), 0);
    }

    function test_platformMustMatchImplementationOnFirstUse() public {
        LoomFactory mismatch = new LoomFactory(address(implementation), bob, pauser);
        vm.prank(alice);
        vm.expectRevert(LoomFactory.PlatformMismatch.selector);
        mismatch.createCollection{value: CREATE_FEE}("Art", "ART", 100, 0, 1, creator, 500);
        assertEq(mismatch.collectionCount(), 0);
    }

    function test_rejectsZeroConstructorParameters() public {
        vm.expectRevert(LoomFactory.ZeroAddress.selector);
        new LoomFactory(address(0), platform, pauser);
        vm.expectRevert(LoomFactory.ZeroAddress.selector);
        new LoomFactory(address(implementation), address(0), pauser);
        vm.expectRevert(LoomFactory.ZeroAddress.selector);
        new LoomFactory(address(implementation), platform, address(0));
    }

    function test_paginationHandlesPartialPagesEmptyPagesAndLargeOffsets() public {
        LoomCollection second = _create(alice, 100, 0, 1, creator, 500);
        LoomCollection third = _create(bob, 100, 0, 1, creator, 500);
        address[] memory all = factory.getCollections(0, 100);
        assertEq(all.length, 3);
        assertEq(all[0], address(collection));
        assertEq(all[1], address(second));
        assertEq(all[2], address(third));
        address[] memory middle = factory.getCollections(1, 1);
        assertEq(middle.length, 1);
        assertEq(middle[0], address(second));
        address[] memory tail = factory.getCollections(2, 2);
        assertEq(tail.length, 1);
        assertEq(tail[0], address(third));
        assertEq(factory.getCollections(0, 0).length, 0);
        assertEq(factory.getCollections(3, 100).length, 0);
        assertEq(factory.getCollections(type(uint256).max, 1).length, 0);
        vm.expectRevert(LoomFactory.PageTooLarge.selector);
        factory.getCollections(0, 101);
    }

    function test_externalCloneIsNotRegisteredByFactory() public {
        LoomCollection externalClone = _blankClone();
        externalClone.initialize("External", "EXT", 100, 0, 1, creator, 0, alice);
        assertFalse(factory.isCollection(address(externalClone)));
        assertEq(factory.collectionCount(), 1);
    }
}
