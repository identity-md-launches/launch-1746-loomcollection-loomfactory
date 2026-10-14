// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private recipient;

    function setUp() public {
        token = new LaunchToken();
        recipient = makeAddr("token recipient");
    }

    function test_fixedSupplyNameSymbolAndDecimals() public view {
        assertEq(token.name(), "Loom");
        assertEq(token.symbol(), "LOOM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferPreservesSupplyAndMovesExactlyTheRequestedAmount(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_allowanceTransferAndInsufficientAllowance() public {
        address spender = makeAddr("spender");
        token.approve(spender, 100 ether);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 100 ether);
        assertEq(token.balanceOf(recipient), 100 ether);
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), recipient, 1);
    }

    function test_deployerAndOthersHaveNoMintOrAdministrativeSelectors() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory payload = abi.encodeWithSignature(signatures[i], recipient, uint256(1));
            (bool deployerSucceeded,) = address(token).call(payload);
            assertFalse(deployerSucceeded);
            vm.prank(recipient);
            (bool outsiderSucceeded,) = address(token).call(payload);
            assertFalse(outsiderSucceeded);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_zeroRecipientAndInsufficientBalanceRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, recipient, 0, 1));
        token.transfer(address(this), 1);
    }
}
