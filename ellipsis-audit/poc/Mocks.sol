// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";

contract MockMintableToken {
    using SafeMath for uint256;

    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        minter = msg.sender;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "not minter");
        _;
    }

    function setMinter(address _minter) external onlyMinter {
        minter = _minter;
    }

    function mint(address to, uint256 amount) external onlyMinter returns (bool) {
        totalSupply = totalSupply.add(amount);
        balanceOf[to] = balanceOf[to].add(amount);
        emit Transfer(address(0), to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(amount);
        balanceOf[to] = balanceOf[to].add(amount);
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed.sub(amount);
        }
        balanceOf[from] = balanceOf[from].sub(amount);
        balanceOf[to] = balanceOf[to].add(amount);
        emit Transfer(from, to, amount);
        return true;
    }
}

// Curve LP-token test double. Mint and burn are restricted to the pool, as in
// the supplied Vyper token; mintRelative is used only by CryptoSwap admin fees.
contract MockCurveLPToken is MockMintableToken {
    using SafeMath for uint256;

    constructor() MockMintableToken("MODEL-LP", "MLP", 18) {}

    function mintRelative(address to, uint256 frac) external onlyMinter returns (uint256) {
        uint256 amount = totalSupply.mul(frac) / 1e18;
        totalSupply = totalSupply.add(amount);
        balanceOf[to] = balanceOf[to].add(amount);
        emit Transfer(address(0), to, amount);
        return amount;
    }

    function burnFrom(address from, uint256 amount) external onlyMinter returns (bool) {
        totalSupply = totalSupply.sub(amount);
        balanceOf[from] = balanceOf[from].sub(amount);
        emit Transfer(from, address(0), amount);
        return true;
    }
}
