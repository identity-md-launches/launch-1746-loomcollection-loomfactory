// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LoomCollection} from "../../src/LoomCollection.sol";
import {LoomFactory} from "../../src/LoomFactory.sol";

abstract contract LoomTestBase is Test {
    uint256 internal constant PRICE = 0.01 ether;
    uint256 internal constant FEE = 0.0005 ether;
    uint256 internal constant CREATE_FEE = 0.002 ether;

    address internal owner;
    address internal creator;
    address internal platform;
    address internal reserve;
    address internal pauser;
    address internal alice;
    address internal bob;
    LoomCollection internal implementation;
    LoomCollection internal collection;
    LoomFactory internal factory;

    function setUp() public virtual {
        owner = makeAddr("collection owner");
        creator = makeAddr("creator");
        platform = makeAddr("platform");
        reserve = makeAddr("reserve");
        pauser = makeAddr("factory pauser");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(owner, 1000 ether);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        implementation = new LoomCollection(platform, reserve);
        factory = new LoomFactory(address(implementation), platform, pauser);
        collection = _create(owner, 1000, PRICE, 20, creator, 500);
    }

    function _create(
        address collectionOwner,
        uint256 supply,
        uint256 price,
        uint256 cap,
        address artist,
        uint96 royalty
    ) internal returns (LoomCollection) {
        vm.prank(collectionOwner);
        return LoomCollection(
            factory.createCollection{value: CREATE_FEE}("Swarm Art", "ART", supply, price, cap, artist, royalty)
        );
    }

    function _blankClone() internal returns (LoomCollection) {
        return LoomCollection(Clones.clone(address(implementation)));
    }

    function _mint(LoomCollection target, address minter, uint256 quantity) internal {
        uint256 payment = (target.mintPriceWei() + FEE) * quantity;
        vm.prank(minter);
        target.mint{value: payment}(quantity);
    }

    function _reserveMint(LoomCollection target, address minter, uint256 quantity) internal {
        uint256 payment = (target.mintPriceWei() + FEE) * quantity;
        vm.prank(minter);
        target.reserveMint{value: payment}(quantity);
    }
}
