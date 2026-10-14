// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Standard launch token. The launch pipeline allocates the entire fixed supply.
contract LaunchToken is ERC20 {
    constructor() ERC20("Loom", "LOOM") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
