// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LoomCollection} from "../src/LoomCollection.sol";
import {LoomFactory} from "../src/LoomFactory.sol";

/// @dev Local constructor/runtime checks with the release's actual owner parameter. No broadcasting.
contract LaunchCompatibilityTest is Test {
    address private constant RELEASE_OWNER = address(bytes20(hex"7efaa4fe311657ac972b6f1ce05a2ee460805fdf"));

    function test_releaseConstructorsPreserveLaunchSupplyAndRoles() public {
        vm.chainId(11155111);
        LaunchToken token = new LaunchToken();
        LoomCollection implementation = new LoomCollection(RELEASE_OWNER, RELEASE_OWNER);
        LoomFactory factory = new LoomFactory(address(implementation), RELEASE_OWNER, RELEASE_OWNER);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.balanceOf(address(implementation)), 0);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(factory.pauser(), RELEASE_OWNER);
        assertEq(factory.PLATFORM(), RELEASE_OWNER);
        assertEq(implementation.PLATFORM(), RELEASE_OWNER);
        assertEq(implementation.RESERVE(), RELEASE_OWNER);
        assertEq(implementation.owner(), address(0));
        assertEq(factory.collectionCount(), 0);
        _assertRuntime(address(token));
        _assertRuntime(address(implementation));
        _assertRuntime(address(factory));
    }

    function _assertRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        // Same PUSH-aware opcode scan as the supplied project floor; clone runtime is separate.
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode in launch artifact");
        }
    }
}
