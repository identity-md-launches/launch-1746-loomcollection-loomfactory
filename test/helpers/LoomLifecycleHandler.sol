// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoomCollection} from "src/LoomCollection.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Independent model: success/failure and new state are predicted BEFORE each call.
/// Invalid actions are asserted, not discarded; frozen and paused states remain active targets.
contract LoomLifecycleHandler is Test {
    uint256 private constant FEE = 0.0005 ether;

    struct Model {
        address owner;
        address pendingOwner;
        uint256 supply;
        uint256 reserved;
        bool paused;
        bool frozen;
        bool hasProvenance;
        bool hasSeed;
        bytes32 provenance;
        bytes32 seed;
        string base;
        string hidden;
    }

    LoomCollection[2] public targets;
    address[4] public actors;
    Model[2] internal models;
    mapping(uint256 => mapping(address => uint256)) public minted;
    mapping(uint256 => mapping(address => uint256)) public balances;
    mapping(uint256 => mapping(uint256 => address)) public holders;
    uint256[2] public prices;
    uint256[2] public caps;
    uint256[2] public supplies;
    address[2] public creators;
    uint256 public paid;
    uint256 public successfulMints;
    uint256 public rejectedCalls;

    constructor(LoomCollection first, LoomCollection second, address[4] memory wallets, address[2] memory artists) {
        targets = [first, second];
        actors = wallets;
        creators = artists;
        models[0].owner = wallets[0];
        models[1].owner = wallets[1];
        prices = [uint256(1), uint256(0.003 ether + 7)];
        caps = [uint256(17), uint256(29)];
        supplies = [uint256(101), uint256(207)];
    }

    function model(uint256 which) external view returns (Model memory) {
        return models[which];
    }

    function mint(uint8 whichRaw, uint8 who, uint8 rawQuantity, uint8 paymentMode, bool reserved, bool asOwner)
        external
    {
        uint256 which = whichRaw % 2;
        Model storage m = models[which];
        address caller = asOwner ? m.owner : actors[who % 4];
        uint256 quantity = uint256(rawQuantity) % 7;
        uint256 payment = (prices[which] + FEE) * quantity;
        uint256 sent = payment;
        if (paymentMode % 4 == 1) sent = payment == 0 ? 1 : payment - 1;
        if (paymentMode % 4 == 2) sent = payment + 1;

        bytes memory error;
        if (reserved && caller != m.owner) {
            error = _unauthorized(caller);
        } else if (m.paused) {
            error = abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector);
        } else if (quantity == 0) {
            error = abi.encodeWithSelector(LoomCollection.ZeroQuantity.selector);
        } else if (quantity > supplies[which] - m.supply) {
            error = abi.encodeWithSelector(LoomCollection.SupplyCapExceeded.selector);
        } else if (sent != payment) {
            error = abi.encodeWithSelector(LoomCollection.IncorrectPayment.selector, payment, sent);
        } else if (reserved && quantity > supplies[which] / 100 - m.reserved) {
            error = abi.encodeWithSelector(LoomCollection.ReserveCapExceeded.selector);
        } else if (!reserved && quantity > caps[which] - minted[which][caller]) {
            error = abi.encodeWithSelector(LoomCollection.WalletCapExceeded.selector);
        }

        vm.deal(caller, caller.balance + sent);
        uint256 beforeBalance = caller.balance;
        bytes memory payload = reserved
            ? abi.encodeCall(LoomCollection.reserveMint, (quantity))
            : abi.encodeCall(LoomCollection.mint, (quantity));
        _call(which, caller, payload, sent, error);
        if (error.length != 0) {
            assertEq(caller.balance, beforeBalance, "failed mint charged payer");
            return;
        }
        assertEq(caller.balance, beforeBalance - payment);
        for (uint256 id = m.supply + 1; id <= m.supply + quantity; ++id) {
            holders[which][id] = caller;
        }
        m.supply += quantity;
        balances[which][caller] += quantity;
        if (reserved) m.reserved += quantity;
        else minted[which][caller] += quantity;
        paid += payment;
        ++successfulMints;
    }

    function administer(uint8 whichRaw, uint8 who, uint8 actionRaw, bytes32 value, bool asOwner) external {
        uint256 which = whichRaw % 2;
        Model storage m = models[which];
        address caller = asOwner ? m.owner : actors[who % 4];
        uint256 action = actionRaw % 8;
        bytes memory payload;
        bytes memory error;
        string memory uri = uint256(value) % 3 == 0 ? "" : string.concat("ipfs://", vm.toString(value), "/");
        if (action == 0) {
            payload = abi.encodeCall(LoomCollection.setProvenanceHash, (value));
        } else if (action == 1) {
            payload = abi.encodeCall(LoomCollection.setRevealSeed, (value));
        } else if (action == 2) {
            payload = abi.encodeCall(LoomCollection.setBaseURI, (uri));
        } else if (action == 3) {
            payload = abi.encodeCall(LoomCollection.setUnrevealedURI, (uri));
        } else if (action == 4) {
            payload = abi.encodeCall(LoomCollection.freezeMetadata, ());
        } else if (action == 5) {
            payload = abi.encodeCall(LoomCollection.pause, ());
        } else if (action == 6) {
            payload = abi.encodeCall(LoomCollection.unpause, ());
        } else {
            payload =
                abi.encodeCall(LoomCollection.initialize, (uri, "REPLAY", uint256(value), 0, 1, caller, 0, caller));
        }

        if (action == 7) {
            error = abi.encodeWithSelector(Initializable.InvalidInitialization.selector);
        } else if (caller != m.owner) {
            error = _unauthorized(caller);
        } else if (action <= 4 && m.frozen) {
            error = abi.encodeWithSelector(LoomCollection.MetadataIsFrozen.selector);
        } else if (action == 0 && m.hasProvenance) {
            error = abi.encodeWithSelector(LoomCollection.ProvenanceAlreadySet.selector);
        } else if (action == 0 && m.supply != 0) {
            error = abi.encodeWithSelector(LoomCollection.MintingAlreadyStarted.selector);
        } else if (action == 1 && m.hasSeed) {
            error = abi.encodeWithSelector(LoomCollection.RevealSeedAlreadySet.selector);
        } else if (action == 5 && m.paused) {
            error = abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector);
        } else if (action == 6 && !m.paused) {
            error = abi.encodeWithSelector(PausableUpgradeable.ExpectedPause.selector);
        }
        _call(which, caller, payload, 0, error);
        if (error.length != 0) return;
        if (action == 0) {
            m.hasProvenance = true;
            m.provenance = value;
        } else if (action == 1) {
            m.hasSeed = true;
            m.seed = value;
        } else if (action == 2) {
            m.base = uri;
        } else if (action == 3) {
            m.hidden = uri;
        } else if (action == 4) {
            m.frozen = true;
        } else if (action == 5) {
            m.paused = true;
        } else if (action == 6) {
            m.paused = false;
        }
    }

    function ownership(uint8 whichRaw, uint8 who, uint8 next, bool accept, bool authorized) external {
        uint256 which = whichRaw % 2;
        Model storage m = models[which];
        // Use real actor callers even when no handover is pending; never impersonate address(0).
        address caller = actors[who % 4];
        if (authorized) caller = accept && m.pendingOwner != address(0) ? m.pendingOwner : m.owner;
        address proposed = next % 5 == 4 ? address(0) : actors[next % 4];
        bytes memory payload = accept
            ? abi.encodeCall(targets[which].acceptOwnership, ())
            : abi.encodeCall(targets[which].transferOwnership, (proposed));
        bool allowed = caller == (accept ? m.pendingOwner : m.owner);
        _call(which, caller, payload, 0, allowed ? bytes("") : _unauthorized(caller));
        if (!allowed) return;
        if (accept) {
            m.owner = caller;
            m.pendingOwner = address(0);
        } else {
            m.pendingOwner = proposed;
        }
    }

    function transfer(uint8 whichRaw, uint256 rawId, uint8 who, uint8 to, bool authorized) external {
        uint256 which = whichRaw % 2;
        Model storage m = models[which];
        if (m.supply == 0) return;
        uint256 id = bound(rawId, 1, m.supply);
        address holder = holders[which][id];
        address caller = authorized ? holder : actors[who % 4];
        address recipient = actors[to % 4];
        bytes memory error;
        if (caller != holder) {
            error = abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, caller, id);
        }
        _call(which, caller, abi.encodeCall(targets[which].transferFrom, (holder, recipient, id)), 0, error);
        if (error.length != 0) return;
        --balances[which][holder];
        ++balances[which][recipient];
        holders[which][id] = recipient;
    }

    function _call(uint256 which, address caller, bytes memory payload, uint256 value, bytes memory error) private {
        vm.prank(caller);
        (bool success, bytes memory reason) = address(targets[which]).call{value: value}(payload);
        if (error.length == 0) {
            assertTrue(success, "model expected success");
        } else {
            assertFalse(success, "model expected rejection");
            assertEq(reason, error, "unexpected rejection reason");
            ++rejectedCalls;
        }
    }

    function _unauthorized(address caller) private pure returns (bytes memory) {
        return abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, caller);
    }
}
