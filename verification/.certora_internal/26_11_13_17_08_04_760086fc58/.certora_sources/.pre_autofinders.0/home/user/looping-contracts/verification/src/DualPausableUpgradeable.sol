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

    function __DualPausable_init() internal onlyInitializing {
        _depositsPaused = false;
        _withdrawalsPaused = false;
    }

    modifier whenDepositsNotPaused() {
        _requireDepositsNotPaused();
        _;
    }

    modifier whenWithdrawalsNotPaused() {
        _requireWithdrawalsNotPaused();
        _;
    }

    function depositsPaused() public view returns (bool) {
        return _depositsPaused;
    }

    function withdrawalsPaused() public view returns (bool) {
        return _withdrawalsPaused;
    }

    function _requireDepositsNotPaused() internal view {
        if (_depositsPaused) revert DepositsPaused();
    }

    function _requireWithdrawalsNotPaused() internal view {
        if (_withdrawalsPaused) revert WithdrawalsPaused();
    }

    function _pauseDeposits() internal {
        _depositsPaused = true;
        emit DepositsPausedUpdated(true);
    }

    function _unpauseDeposits() internal {
        _depositsPaused = false;
        emit DepositsPausedUpdated(false);
    }

    function _pauseWithdrawals() internal {
        _withdrawalsPaused = true;
        emit WithdrawalsPausedUpdated(true);
    }

    function _unpauseWithdrawals() internal {
        _withdrawalsPaused = false;
        emit WithdrawalsPausedUpdated(false);
    }

    error DepositsPaused();
    error WithdrawalsPaused();
}
