// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IRoleManager } from "../../src/interfaces/IRoleManager.sol";
import { IVaultLenderRegistry } from "../../src/interfaces/IVaultLenderRegistry.sol";

/// @dev Deterministic loan asset. `mint` is open on purpose: the prover must be able to fund
///      arbitrary symbolic actors so deposit/repay rules are not vacuous.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev Role source with concrete, storage-backed answers so `onlyVaultManager` is not havoced.
contract MockRoleManager is IRoleManager {
    address public immutable manager;

    constructor(address manager_) {
        manager = manager_;
    }

    function isVaultManager(address who) external view returns (bool) {
        return who == manager;
    }

    function isFactoryAdmin(address who) external view returns (bool) {
        return who == manager;
    }

    function isLenderManager(address who) external view returns (bool) {
        return who == manager;
    }

    function isLenderApprover(address who) external view returns (bool) {
        return who == manager;
    }
}

/// @dev Registry whose approval set is real storage, so `isApproved` is deterministic and stable
///      across the two calls a single exit leg makes (view then execution).
contract MockLenderRegistry is IVaultLenderRegistry {
    IRoleManager private immutable _roleManager;
    address public immutable controller;
    mapping(address => mapping(address => bool)) private _approved;

    constructor(IRoleManager roleManager_, address controller_) {
        _roleManager = roleManager_;
        controller = controller_;
    }

    function roleManager() external view returns (IRoleManager) {
        return _roleManager;
    }

    /// @dev Unrestricted on purpose: the harness drives it to reach approved-lender states.
    function forceApprove(address vault, address lender) external {
        _approved[vault][lender] = true;
        emit LenderApproved(vault, lender, msg.sender);
    }

    function forceRevoke(address vault, address lender) external {
        _approved[vault][lender] = false;
        emit LenderRevoked(vault, lender, msg.sender);
    }

    function approveLender(address vault, address lender) external {
        _approved[vault][lender] = true;
        emit LenderApproved(vault, lender, msg.sender);
    }

    function approveLendersBatch(address vault, address[] calldata lenders) external {
        for (uint256 i = 0; i < lenders.length; ++i) {
            _approved[vault][lenders[i]] = true;
        }
    }

    function revokeLender(address vault, address lender) external {
        if (!_approved[vault][lender]) revert LenderNotApproved();
        _approved[vault][lender] = false;
        emit LenderRevoked(vault, lender, msg.sender);
    }

    /// @dev ERC-7540 semantics: the vault calls `isApproved(lender)` on itself as msg.sender.
    function isApproved(address lender) external view returns (bool) {
        return _approved[msg.sender][lender];
    }

    function isApprovedFor(address vault, address lender) external view returns (bool) {
        return _approved[vault][lender];
    }

    function getVaultLenders(address) external pure returns (address[] memory empty) {}

    function getVaultLenderCount(address) external pure returns (uint256) {
        return 0;
    }
}
