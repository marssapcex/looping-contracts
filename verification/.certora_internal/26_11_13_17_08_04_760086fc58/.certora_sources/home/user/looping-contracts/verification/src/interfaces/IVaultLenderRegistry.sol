// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IRoleManager } from "./IRoleManager.sol";

interface IVaultLenderRegistry {
    error ZeroAddress();
    error NotAuthorized();
    error LenderNotApproved();

    event LenderApproved(address indexed vault, address indexed lender, address approver);
    event LenderRevoked(address indexed vault, address indexed lender, address revoker);

    function approveLender(address vault, address lender) external;
    function approveLendersBatch(address vault, address[] calldata lenders) external;
    function revokeLender(address vault, address lender) external;
    function roleManager() external view returns (IRoleManager);
    function isApproved(address lender) external view returns (bool);
    function isApprovedFor(address vault, address lender) external view returns (bool);
    function getVaultLenders(address vault) external view returns (address[] memory);
    function getVaultLenderCount(address vault) external view returns (uint256);
}
