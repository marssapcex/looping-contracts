// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @dev Minimal reconstruction of the Axcess RoleManager surface used by the vault.
interface IRoleManager {
    function isVaultManager(address who) external view returns (bool);
    function isFactoryAdmin(address who) external view returns (bool);
    function isLenderManager(address who) external view returns (bool);
    function isLenderApprover(address who) external view returns (bool);
}
