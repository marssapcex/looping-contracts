// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "forge-std/console.sol";

interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function expectRevert() external;
    function expectRevert(bytes calldata) external;
    function etch(address, bytes calldata) external;
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
    function snapshot() external returns (uint256);
    function revertTo(uint256) external returns (bool);
}

contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool value, string memory message) internal pure {
        if (!value) revert(message);
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        if (left != right) {
            console.log(message);
            console.log("left", left);
            console.log("right", right);
            revert("assertEq(uint256) failed");
        }
    }

    function assertEq(int256 left, int256 right, string memory message) internal pure {
        if (left != right) {
            console.log(message);
            console.log("left", left);
            console.log("right", right);
            revert("assertEq(int256) failed");
        }
    }

    function assertGt(uint256 left, uint256 right, string memory message) internal pure {
        if (left <= right) {
            console.log(message);
            console.log("left", left);
            console.log("right", right);
            revert("assertGt failed");
        }
    }

    function deployVyperRuntime(string memory path, address target) internal {
        // LOCAL_VYPER_RUNTIME_ETCH: deployment surrogate for a fresh proxy only.
        // This is not mainnet state and cannot support a promoted FINDING.
        bytes memory runtime = vm.parseBytes(vm.readFile(path));
        vm.etch(target, runtime);
    }
}
