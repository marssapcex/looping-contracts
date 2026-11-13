// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @dev Reconstructed stand-in for the Axcess `DualPausableUpgradeable`; only the surface used by
///      LoanVaultBase/LoanVault matters for verification (init, the two flags, the two modifiers).
abstract contract DualPausableUpgradeable is Initializable {
    bool private _depositsPaused;
    bool private _withdrawalsPaused;

    event DepositsPausedUpdated(bool paused);
    event WithdrawalsPausedUpdated(bool paused);

    function __DualPausable_init() internal logInternal29()onlyInitializing {
        _depositsPaused = false;
        _withdrawalsPaused = false;
    }modifier logInternal29() { assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff001d0000, 1037618708509) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff001d0001, 0) } _; }

    modifier whenDepositsNotPaused() {
        _requireDepositsNotPaused();
        _;
    }

    modifier whenWithdrawalsNotPaused() {
        _requireWithdrawalsNotPaused();
        _;
    }

    function depositsPaused() public view returns (bool) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00080000, 1037618708488) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00080001, 0) }
        return _depositsPaused;
    }

    function withdrawalsPaused() public view returns (bool) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff000b0000, 1037618708491) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff000b0001, 0) }
        return _withdrawalsPaused;
    }

    function _requireDepositsNotPaused() internal view {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff001e0000, 1037618708510) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff001e0001, 0) }
        if (_depositsPaused) revert DepositsPaused();
    }

    function _requireWithdrawalsNotPaused() internal view {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00200000, 1037618708512) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00200001, 0) }
        if (_withdrawalsPaused) revert WithdrawalsPaused();
    }

    function _pauseDeposits() internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00210000, 1037618708513) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00210001, 0) }
        _depositsPaused = true;
        emit DepositsPausedUpdated(true);
    }

    function _unpauseDeposits() internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff001f0000, 1037618708511) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff001f0001, 0) }
        _depositsPaused = false;
        emit DepositsPausedUpdated(false);
    }

    function _pauseWithdrawals() internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00220000, 1037618708514) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00220001, 0) }
        _withdrawalsPaused = true;
        emit WithdrawalsPausedUpdated(true);
    }

    function _unpauseWithdrawals() internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00230000, 1037618708515) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00230001, 0) }
        _withdrawalsPaused = false;
        emit WithdrawalsPausedUpdated(false);
    }

    error DepositsPaused();
    error WithdrawalsPaused();
}
