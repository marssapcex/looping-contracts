// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface Vm {
    function createSelectFork(string calldata rpc, uint256 blockNumber) external returns (uint256);
    function envString(string calldata name) external view returns (string memory);
    function prank(address msgSender, address txOrigin) external;
    function label(address account, string calldata label_) external;
}

contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    function assertGt(uint256 a, uint256 b, string memory message) internal pure {
        require(a > b, message);
    }
    function assertApproxEqAbs(uint256 a, uint256 b, uint256 tolerance, string memory message) internal pure {
        uint256 delta = a > b ? a - b : b - a;
        require(delta <= tolerance, message);
    }
}
