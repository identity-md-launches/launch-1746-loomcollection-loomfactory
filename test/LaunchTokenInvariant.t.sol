// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenAccountingHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    LaunchToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public successfulTransfers;
    uint256 public rejectedCalls;

    constructor(LaunchToken token_, address[4] memory wallets) {
        token = token_;
        actors = wallets;
        expectedBalance[wallets[0]] = SUPPLY;
    }

    function approve(uint8 who, uint8 spenderIndex, uint256 amount, bool infinite) external {
        address holder = actors[who % 4];
        address spender = spenderIndex % 5 == 4 ? address(0) : actors[spenderIndex % 4];
        if (infinite) amount = type(uint256).max;
        bytes memory error;
        if (spender == address(0)) error = abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, spender);
        _call(holder, abi.encodeCall(token.approve, (spender, amount)), error);
        if (error.length == 0) expectedAllowance[holder][spender] = amount;
    }

    function transfer(uint8 fromIndex, uint8 toIndex, uint256 rawAmount, bool exceedBalance) external {
        address holder = actors[fromIndex % 4];
        address recipient = toIndex % 5 == 4 ? address(0) : actors[toIndex % 4];
        uint256 balance = expectedBalance[holder];
        uint256 amount = exceedBalance ? balance + 1 : bound(rawAmount, 0, balance);
        bytes memory error;
        if (recipient == address(0)) {
            error = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, recipient);
        } else if (amount > balance) {
            error = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, balance, amount);
        }
        _call(holder, abi.encodeCall(token.transfer, (recipient, amount)), error);
        if (error.length == 0) _move(holder, recipient, amount);
    }

    function transferFrom(uint8 spenderIndex, uint8 fromIndex, uint8 toIndex, uint256 rawAmount, uint8 mode) external {
        address spender = actors[spenderIndex % 4];
        address holder = actors[fromIndex % 4];
        address recipient = toIndex % 5 == 4 ? address(0) : actors[toIndex % 4];
        uint256 balance = expectedBalance[holder];
        uint256 allowed = expectedAllowance[holder][spender];
        uint256 available = balance < allowed ? balance : allowed;
        uint256 amount = bound(rawAmount, 0, available);
        if (mode % 3 == 1) amount = balance + 1;
        if (mode % 3 == 2) amount = allowed == type(uint256).max ? balance + 1 : allowed + 1;
        bytes memory error;
        if (allowed != type(uint256).max && amount > allowed) {
            error = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        } else if (recipient == address(0)) {
            error = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, recipient);
        } else if (amount > balance) {
            error = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, balance, amount);
        }
        _call(spender, abi.encodeCall(token.transferFrom, (holder, recipient, amount)), error);
        if (error.length == 0) {
            if (allowed != type(uint256).max) expectedAllowance[holder][spender] -= amount;
            _move(holder, recipient, amount);
        }
    }

    function forbiddenAdministration(uint8 who, uint8 action, uint256 amount) external {
        string[7] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "pause()",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "transferOwnership(address)"
        ];
        address caller = actors[who % 4];
        vm.prank(caller);
        (bool success,) = address(token).call(abi.encodeWithSignature(signatures[action % 7], caller, amount));
        assertFalse(success, "launch token exposes privileged operation");
        ++rejectedCalls;
    }

    function _move(address holder, address recipient, uint256 amount) private {
        expectedBalance[holder] -= amount;
        expectedBalance[recipient] += amount;
        ++successfulTransfers;
    }

    function _call(address caller, bytes memory payload, bytes memory error) private {
        vm.prank(caller);
        (bool success, bytes memory result) = address(token).call(payload);
        if (error.length == 0) {
            assertTrue(success, "valid ERC20 operation reverted");
            assertEq(result, abi.encode(true));
        } else {
            assertFalse(success, "invalid ERC20 operation succeeded");
            assertEq(result, error);
            ++rejectedCalls;
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchToken private token;
    LaunchTokenAccountingHandler private handler;
    address[4] private actors;

    function setUp() public {
        token = new LaunchToken();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("LOOM actor ", vm.toString(i)));
        }
        handler = new LaunchTokenAccountingHandler(token, actors);
        token.transfer(actors[0], 1_000_000_000 ether);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.forbiddenAdministration.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyBalancesAndAllowancesMatchIndependentLedger() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(actors[i]));
            sum += token.balanceOf(actors[i]);
            for (uint256 j; j < actors.length; ++j) {
                assertEq(token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j]));
            }
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.name(), "Loom");
        assertEq(token.symbol(), "LOOM");
        assertEq(token.decimals(), 18);
    }

    function test_handlerCoversUnlimitedAllowanceReplacementAndFailedTransferRollback() public {
        handler.approve(0, 1, 0, true);
        handler.transferFrom(1, 0, 2, 10 ether, 0);
        assertEq(token.allowance(actors[0], actors[1]), type(uint256).max);
        handler.approve(0, 1, 20 ether, false);
        handler.transferFrom(1, 0, 4, 10 ether, 0); // Zero recipient must not consume allowance.
        assertEq(token.allowance(actors[0], actors[1]), 20 ether);
        handler.transferFrom(1, 0, 2, 10 ether, 0);
        handler.approve(0, 1, 0, false);
        handler.transferFrom(1, 0, 2, 1 ether, 2);
        handler.transfer(2, 2, 10 ether, false); // Self-transfer conserves balances.
        handler.transfer(3, 0, 0, true); // Empty holder cannot spend one wei.
        assertEq(handler.successfulTransfers(), 3);
        assertEq(handler.rejectedCalls(), 3);
        invariant_supplyBalancesAndAllowancesMatchIndependentLedger();
    }
}
