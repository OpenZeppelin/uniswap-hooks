// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract ERC20RejectZeroTransferMock is ERC20Mock {
    /// @dev A zero-value transfer was attempted.
    error ZeroTransfer();

    function _update(address from, address to, uint256 value) internal virtual override {
        if (value == 0 && from != address(0) && to != address(0)) revert ZeroTransfer();
        super._update(from, to, value);
    }

    // Exclude from coverage report
    function test() public {}
}
