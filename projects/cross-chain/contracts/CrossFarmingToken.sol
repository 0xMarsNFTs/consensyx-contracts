// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title A mintable and burnable ERC20 token as cross-farming Masterchef mock pool LP token.
/// @notice Must 'transferOwnership' to 'receiver' contract on BSC chain after added as LP token in MasterchefV2 pool.
contract CrossFarmingToken is ERC20Burnable, Ownable {
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    // only cross-farming receiver contract can mint token automatically after called by messagebus.
    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }
}
