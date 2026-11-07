// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

// Test-only external dependencies. The audited reward contracts remain unchanged.
contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPoolRegistry {
    mapping(uint256 => mapping(address => address)) public vaultMap;
    function setVault(uint256 pid, address owner, address vault) external {
        vaultMap[pid][owner] = vault;
    }
}

contract MockBooster {
    address public rewardManager;
    address public owner;
    constructor(address manager) {
        rewardManager = manager;
        owner = manager;
    }
    // StakedCvxFxs deliberately tolerates this call. Rewards are injected by the
    // harness as real ERC20 transfers so balance/claim conservation can be checked.
    function claimFees() external {}
}

contract MockVoterProxy {
    address public operator;
    constructor(address _operator) { operator = _operator; }
    function setOperator(address _operator) external { operator = _operator; }
}
