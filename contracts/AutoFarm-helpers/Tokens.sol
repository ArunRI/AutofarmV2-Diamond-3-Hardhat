// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./helpers/ERC20.sol";
import "./helpers/Ownable.sol";

contract MyToken1 is ERC20, Ownable {
    constructor() ERC20("MyToken1", "MTK1") {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}