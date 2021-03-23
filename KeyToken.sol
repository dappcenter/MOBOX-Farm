
// SPDX-License-Identifier: MIT

pragma solidity ^0.6.6;

import "./comm/Ownable.sol";
import "./comm/SafeMath.sol";
import "./comm/ERC20.sol";

contract KeyToken is Ownable, ERC20 {
    using SafeMath for uint256;

    /**
     * MOBOX Farm Main Contract
     */
    address public moboxFarm;

    /**
     * has key been minted or is it used for marketing or adding LP
     */
    bool public eventMinted;

    constructor() public ERC20("MoMo KEY", "KEY", 18) {

    }

    /**
     * MOBOX Farm Main Contract
     */
    function setFarm(address farm_) external {
        if (moboxFarm == address(0)) {
            require(msg.sender == owner(), "not owner");
        } else {
            require(msg.sender == moboxFarm, "not farm");
        }
        moboxFarm = farm_;
    }

    /**
     * Mint used for marketing or adding LP
     */
    function mintForEvent(address dest_) external onlyOwner {
        require(!eventMinted, "only can mint once");
        eventMinted = true;
        _mint(dest_, 100000e18);
    }

    /**
     * For Mobox Farm minting Key
     */
    function mint(address dest_, uint256 amount_) external {
        require(msg.sender == moboxFarm, "not farm");
        _mint(dest_, amount_);
    }

    function burn(uint256 amount_) external { 
        _burn(msg.sender, amount_);
    }

    function burnFrom(address from_, uint256 amount_) external {
        require(from_ != address(0), "burn from 0");

        _approve(from_, msg.sender, _allowances[from_][msg.sender].sub(amount_));
        _burn(from_, amount_);
    }
}
