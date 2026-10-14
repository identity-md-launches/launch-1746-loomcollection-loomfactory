// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoomTestBase} from "./helpers/LoomTestBase.sol";
import {LoomHandler} from "./helpers/LoomHandler.sol";
import {LoomCollection} from "../src/LoomCollection.sol";

contract LoomInvariantTest is LoomTestBase {
    LoomHandler private handler;
    LoomCollection private second;
    address[4] private actors;
    uint256 private platformStartingBalance;

    function setUp() public override {
        super.setUp();
        second = _create(bob, 300, 0, 30, creator, 1000);
        actors = [owner, alice, bob, makeAddr("fourth actor")];
        handler = new LoomHandler(collection, second, actors);
        platformStartingBalance = platform.balance;
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.reserveMint.selector;
        selectors[2] = handler.transfer.selector;
        selectors[3] = handler.togglePause.selector;
        selectors[4] = handler.metadata.selector;
        selectors[5] = handler.freeze.selector;
        selectors[6] = handler.wrongPayment.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_allSupplyAndWalletLimitsHold() public view {
        for (uint256 i; i < 2; ++i) {
            LoomCollection target = handler.targets(i);
            assertLe(target.totalSupply(), target.maxSupply());
            assertLe(target.reserveMinted(), target.maxSupply() / 100);
            assertEq(target.totalSupply(), handler.publicMinted(i) + handler.reserved(i));
            assertEq(target.reserveMinted(), handler.reserved(i));
            uint256 balances;
            uint256 publicMints;
            for (uint256 j; j < actors.length; ++j) {
                assertLe(target.mintedPerWallet(actors[j]), target.maxPerWallet());
                balances += target.balanceOf(actors[j]);
                publicMints += target.mintedPerWallet(actors[j]);
            }
            assertEq(balances, target.totalSupply());
            assertEq(publicMints, handler.publicMinted(i));
        }
    }

    function invariant_allPaymentsConservedAndNoProceedsRetained() public view {
        uint256 firstSupply = collection.totalSupply();
        uint256 secondSupply = second.totalSupply();
        uint256 combined = firstSupply + secondSupply;
        assertEq(creator.balance, PRICE * firstSupply + 0.0002 ether * combined);
        assertEq(platform.balance - platformStartingBalance, 0.0002 ether * combined);
        assertEq(reserve.balance, 0.0001 ether * combined);
        assertEq(creator.balance + platform.balance - platformStartingBalance + reserve.balance, handler.paid());
        assertEq(address(collection).balance, 0);
        assertEq(address(second).balance, 0);
        assertEq(address(factory).balance, 0);
    }

    function invariant_configurationAndImplementationRemainIsolated() public view {
        assertEq(collection.owner(), owner);
        assertEq(second.owner(), bob);
        assertEq(collection.creator(), creator);
        assertEq(second.creator(), creator);
        assertEq(collection.maxSupply(), 1000);
        assertEq(second.maxSupply(), 300);
        assertEq(collection.mintPriceWei(), PRICE);
        assertEq(second.mintPriceWei(), 0);
        assertEq(collection.royaltyBps(), 500);
        assertEq(second.royaltyBps(), 1000);
        assertEq(implementation.owner(), address(0));
        assertEq(implementation.totalSupply(), 0);
        assertEq(implementation.baseURI(), "");
        assertFalse(implementation.metadataFrozen());
        assertEq(factory.collectionCount(), 2);
    }
}
