// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {LoomCollection} from "../../src/LoomCollection.sol";

/// @dev Test-only receiver that can reject transfers or attempt arbitrary reentrant calls.
contract CallbackReceiver is IERC721Receiver {
    bool public rejectsETH;
    uint256 public rejectNFTNumber;
    uint256 public nftCallbacks;
    uint256 public attempts;
    bool public succeeded;
    bytes public result;
    uint256 public supplySeen;
    uint256 public publicMintsSeen;
    uint256 public reserveMintsSeen;
    address public forwardNFTTo;
    address private target;
    bytes private payload;
    uint256 private payment;
    bool private attackETH;
    bool private attackNFT;

    function rejectETH(bool rejects) external {
        rejectsETH = rejects;
    }

    function rejectNFT(uint256 number) external {
        rejectNFTNumber = number;
    }

    function forwardNFT(address recipient) external {
        forwardNFTTo = recipient;
    }

    function arm(address target_, bytes calldata payload_, uint256 payment_, bool onETH, bool onNFT) external {
        target = target_;
        payload = payload_;
        payment = payment_;
        attackETH = onETH;
        attackNFT = onNFT;
    }

    function execute(address destination, bytes calldata data, uint256 value) external returns (bytes memory returned) {
        bool success;
        (success, returned) = destination.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returned, 32), mload(returned))
            }
        }
    }

    receive() external payable {
        require(!rejectsETH, "receiver rejects ETH");
        if (attackETH) _attempt();
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        ++nftCallbacks;
        if (nftCallbacks == rejectNFTNumber) return bytes4(0);
        LoomCollection collection = LoomCollection(msg.sender);
        supplySeen = collection.totalSupply();
        publicMintsSeen = collection.mintedPerWallet(address(this));
        reserveMintsSeen = collection.reserveMinted();
        if (attackNFT) _attempt();
        if (forwardNFTTo != address(0)) collection.transferFrom(address(this), forwardNFTTo, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _attempt() private {
        // One attempt allows an unguarded target to succeed without an infinite recursive call.
        if (attempts != 0) return;
        ++attempts;
        (succeeded, result) = target.call{value: payment}(payload);
    }
}
