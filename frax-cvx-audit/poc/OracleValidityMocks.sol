// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

/// @dev Local-only ERC20 for the cvxFXBSwapper oracle-validity boundary.
contract OracleFlagToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) { name = _name; symbol = _symbol; }
    function mint(address to, uint256 amount) external {
        totalSupply += amount; balanceOf[to] += amount;
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}

/// @dev Explicitly returns isBorrowAllowed=false in the counterexample. This is
/// a local oracle/lender state, not a claim about a deployed Fraxlend oracle.
contract OracleFlagLender {
    bool public allowed;
    uint256 public rate;
    uint256 public updateCalls;
    constructor(bool _allowed, uint256 _rate) { allowed = _allowed; rate = _rate; }
    function updateExchangeRate() external returns (bool, uint256, uint256) {
        updateCalls += 1;
        return (allowed, rate, rate);
    }
}

/// @dev Executes a real token pull and output mint while recording minOut.
contract OracleFlagExchange {
    OracleFlagToken public immutable frax;
    OracleFlagToken public immutable fxb;
    uint256 public immutable outputRate;
    uint256 public calls;
    uint256 public lastAmountIn;
    uint256 public lastMinOut;
    address public lastReceiver;

    constructor(OracleFlagToken _frax, OracleFlagToken _fxb, uint256 _outputRate) {
        frax = _frax; fxb = _fxb; outputRate = _outputRate;
    }
    function exchange(int128, int128, uint256 amountIn, uint256 minOut, address receiver) external returns (uint256 amountOut) {
        calls += 1; lastAmountIn = amountIn; lastMinOut = minOut; lastReceiver = receiver;
        require(frax.transferFrom(msg.sender, address(this), amountIn), "frax pull");
        amountOut = amountIn * outputRate / 1e18;
        require(amountOut >= minOut, "minOut");
        fxb.mint(receiver, amountOut);
    }
}
