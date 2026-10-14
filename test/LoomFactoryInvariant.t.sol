// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoomCollection} from "src/LoomCollection.sol";
import {LoomFactory} from "src/LoomFactory.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract LoomRegistryHandler is Test {
    uint256 private constant CREATE_FEE = 0.002 ether;
    uint256 private constant MINT_FEE = 0.0005 ether;

    struct Entry {
        address collection;
        address owner;
        address creator;
        uint256 supply;
        uint256 price;
        uint256 cap;
        uint96 royalty;
    }

    LoomFactory public immutable factory;
    address public immutable pauser;
    address[3] public actors;
    Entry[] private entries;
    bool public expectedPaused;
    uint256 public rejectedCreations;

    constructor(LoomFactory factory_, address pauser_, address[3] memory wallets) {
        factory = factory_;
        pauser = pauser_;
        actors = wallets;
    }

    function count() external view returns (uint256) {
        return entries.length;
    }

    function entry(uint256 i) external view returns (Entry memory) {
        return entries[i];
    }

    function create(
        uint8 who,
        uint16 rawSupply,
        uint128 priceRaw,
        uint16 rawCap,
        uint96 bps,
        uint8 invalid,
        uint8 feeMode
    ) external {
        // Bound successful registry growth while still exercising rejection paths after the bound.
        if (entries.length == 16 && invalid % 9 == 0 && feeMode % 4 == 0 && !expectedPaused) return;
        address caller = actors[who % 3];
        Entry memory e;
        e.owner = caller;
        e.creator = actors[(uint256(who) + 1) % 3];
        e.supply = bound(rawSupply, 1, 1000);
        e.price = priceRaw;
        e.cap = bound(rawCap, 1, e.supply);
        e.royalty = uint96(bound(bps, 0, 1000));
        string memory name = "Registry Art";
        string memory symbol = "REG";
        bytes memory parameterError;
        uint256 kind = invalid % 9;
        if (kind == 1) {
            name = "";
            parameterError = abi.encodeWithSelector(LoomCollection.EmptyNameOrSymbol.selector);
        }
        if (kind == 2) {
            symbol = "";
            parameterError = abi.encodeWithSelector(LoomCollection.EmptyNameOrSymbol.selector);
        }
        if (kind == 3) {
            e.supply = 0;
            parameterError = abi.encodeWithSelector(LoomCollection.InvalidSupplyOrWalletCap.selector);
        }
        if (kind == 4) {
            e.cap = 0;
            parameterError = abi.encodeWithSelector(LoomCollection.InvalidSupplyOrWalletCap.selector);
        }
        if (kind == 5) {
            e.cap = e.supply + 1;
            parameterError = abi.encodeWithSelector(LoomCollection.InvalidSupplyOrWalletCap.selector);
        }
        if (kind == 6) {
            e.royalty = uint96(bound(bps, 1001, type(uint96).max));
            parameterError = abi.encodeWithSelector(LoomCollection.RoyaltyTooHigh.selector);
        }
        if (kind == 7) {
            e.price = type(uint256).max - MINT_FEE + 1;
            parameterError = abi.encodeWithSelector(LoomCollection.InvalidMintPrice.selector);
        }
        if (kind == 8) {
            e.creator = address(0);
            parameterError = abi.encodeWithSelector(LoomCollection.ZeroAddress.selector);
        }
        uint256 payment = CREATE_FEE;
        if (feeMode % 4 == 1) payment = 0;
        if (feeMode % 4 == 2) payment = CREATE_FEE - 1;
        if (feeMode % 4 == 3) payment = CREATE_FEE + 1;
        bytes memory error = parameterError;
        if (expectedPaused) {
            error = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        } else if (payment != CREATE_FEE) {
            error = abi.encodeWithSelector(LoomFactory.IncorrectCreateFee.selector, CREATE_FEE, payment);
        }

        address predicted = vm.computeCreateAddress(address(factory), entries.length + 1);
        vm.deal(caller, caller.balance + payment);
        uint256 beforeBalance = caller.balance;
        uint256 beforePlatform = factory.PLATFORM().balance;
        vm.prank(caller);
        (bool success, bytes memory result) = address(factory).call{value: payment}(
            abi.encodeCall(factory.createCollection, (name, symbol, e.supply, e.price, e.cap, e.creator, e.royalty))
        );
        if (error.length != 0) {
            assertFalse(success, "invalid creation succeeded");
            assertEq(result, error);
            assertEq(caller.balance, beforeBalance);
            assertEq(factory.PLATFORM().balance, beforePlatform);
            assertEq(predicted.code.length, 0, "failed creation left clone code");
            assertFalse(factory.isCollection(predicted));
            assertEq(factory.collectionCount(), entries.length);
            ++rejectedCreations;
        } else {
            assertTrue(success, "valid creation failed");
            e.collection = abi.decode(result, (address));
            assertEq(e.collection, predicted, "failed creation consumed deployment nonce");
            assertEq(caller.balance, beforeBalance - CREATE_FEE);
            assertEq(factory.PLATFORM().balance, beforePlatform + CREATE_FEE);
            entries.push(e);
        }
    }

    function pause(bool pauseCreation, uint8 who, bool authorized) external {
        address caller = authorized ? pauser : actors[who % 3];
        bytes memory error;
        if (caller != pauser) error = abi.encodeWithSelector(LoomFactory.UnauthorizedPauser.selector);
        else if (pauseCreation && expectedPaused) error = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        else if (!pauseCreation && !expectedPaused) error = abi.encodeWithSelector(Pausable.ExpectedPause.selector);
        bytes memory payload = pauseCreation ? abi.encodeCall(factory.pause, ()) : abi.encodeCall(factory.unpause, ());
        vm.prank(caller);
        (bool success, bytes memory result) = address(factory).call(payload);
        if (error.length != 0) {
            assertFalse(success);
            assertEq(result, error);
        } else {
            assertTrue(success);
            expectedPaused = pauseCreation;
        }
    }

    function reinitialize(uint256 index, uint8 who) external {
        if (entries.length == 0) return;
        LoomCollection target = LoomCollection(entries[index % entries.length].collection);
        address caller = actors[who % 3];
        vm.prank(caller);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        target.initialize("Replacement", "BAD", 1, 0, 1, caller, 0, caller);
    }

    function page(uint256 rawOffset, uint8 rawLimit, bool withinList) external view {
        uint256 offset = withinList ? rawOffset % (entries.length + 1) : rawOffset;
        uint256 limit = uint256(rawLimit) % 103;
        if (limit > 100) {
            // staticcall allows exact revert checking from a view handler without expectRevert.
            (bool success, bytes memory reason) =
                address(factory).staticcall(abi.encodeCall(factory.getCollections, (offset, limit)));
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(LoomFactory.PageTooLarge.selector));
            return;
        }
        address[] memory result = factory.getCollections(offset, limit);
        uint256 expected = offset >= entries.length ? 0 : entries.length - offset;
        if (limit < expected) expected = limit;
        assertEq(result.length, expected);
        for (uint256 i; i < expected; ++i) {
            assertEq(result[i], entries[offset + i].collection);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LoomFactoryInvariantTest is Test {
    LoomFactory private factory;
    LoomCollection private implementation;
    LoomRegistryHandler private handler;
    address private platform;
    address private reserve;
    address private pauser;

    function setUp() public {
        platform = makeAddr("registry platform");
        reserve = makeAddr("registry reserve");
        pauser = makeAddr("registry pauser");
        implementation = new LoomCollection(platform, reserve);
        factory = new LoomFactory(address(implementation), platform, pauser);
        address[3] memory actors = [makeAddr("registry alice"), makeAddr("registry bob"), makeAddr("registry carol")];
        handler = new LoomRegistryHandler(factory, pauser, actors);
        handler.create(0, 101, 0, 1, 0, 0, 0);
        handler.create(1, 207, 1, 23, 1000, 0, 0);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.pause.selector;
        selectors[2] = handler.reinitialize.selector;
        selectors[3] = handler.page.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_registryAndFeesOnlyReflectSuccessfulAtomicCreations() public view {
        assertEq(factory.collectionCount(), handler.count());
        assertEq(factory.paused(), handler.expectedPaused());
        assertEq(factory.implementation(), address(implementation));
        assertEq(factory.pauser(), pauser);
        assertEq(factory.PLATFORM(), platform);
        assertEq(platform.balance, handler.count() * 0.002 ether);
        assertEq(reserve.balance, 0);
        assertEq(address(factory).balance, 0);
        assertFalse(factory.isCollection(address(implementation)));
        address[] memory registered = factory.getCollections(0, 100);
        assertEq(registered.length, handler.count());
        for (uint256 i; i < registered.length; ++i) {
            LoomRegistryHandler.Entry memory e = handler.entry(i);
            LoomCollection target = LoomCollection(e.collection);
            assertEq(registered[i], e.collection);
            assertEq(factory.collections(i), e.collection);
            assertTrue(factory.isCollection(e.collection));
            assertEq(
                e.collection.code,
                abi.encodePacked(
                    hex"363d3d373d3d3d363d73", address(implementation), hex"5af43d82803e903d91602b57fd5bf3"
                )
            );
            assertEq(target.owner(), e.owner);
            assertEq(target.creator(), e.creator);
            assertEq(target.maxSupply(), e.supply);
            assertEq(target.mintPriceWei(), e.price);
            assertEq(target.maxPerWallet(), e.cap);
            assertEq(target.royaltyBps(), e.royalty);
            assertEq(target.name(), "Registry Art");
            assertEq(target.symbol(), "REG");
            assertEq(target.PLATFORM(), platform);
            assertEq(target.RESERVE(), reserve);
            assertEq(target.totalSupply(), 0);
            assertEq(target.baseURI(), "");
            assertFalse(target.paused());
            assertEq(e.collection.balance, 0);
        }
    }

    function test_everyInvalidFactoryParameterRollsBackAndAllowsRetry() public {
        for (uint8 invalid = 1; invalid < 9; ++invalid) {
            handler.create(0, 100, 0, 10, 500, invalid, 0);
        }
        assertEq(handler.rejectedCreations(), 8);
        handler.create(2, 199, 7, 19, 999, 0, 0);
        assertEq(handler.count(), 3);
        handler.pause(true, 0, true);
        handler.create(0, 100, 0, 10, 500, 0, 0);
        handler.pause(false, 0, true);
        handler.create(0, 100, 0, 10, 500, 0, 0);
        assertEq(handler.count(), 4);
        assertEq(handler.rejectedCreations(), 9);
        invariant_registryAndFeesOnlyReflectSuccessfulAtomicCreations();
    }
}
