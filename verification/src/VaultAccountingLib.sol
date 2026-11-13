// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultAccountingLib
/// @notice Vault math: interest, share conversions, epoch timing. (Reconstructed verbatim.)
library VaultAccountingLib {
    using Math for uint256;

    uint256 internal constant DEFAULT_EPOCH_DURATION = 7 days;
    uint256 internal constant DEFAULT_WITHDRAWAL_NOTICE = 3 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    function calculateInterest(
        uint256 principalAmount,
        uint256 rateBps,
        uint256 elapsed
    )
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(principalAmount, rateBps * elapsed, SECONDS_PER_YEAR * BPS_DENOMINATOR);
    }

    function convertToShares(
        uint256 assets,
        uint256 totalAssetsValue,
        uint256 effectiveSupply,
        uint8 decimalsOffset
    )
        internal
        pure
        returns (uint256)
    {
        return assets.mulDiv(effectiveSupply + 10 ** decimalsOffset, totalAssetsValue + 1, Math.Rounding.Floor);
    }

    function convertToAssets(
        uint256 shares,
        uint256 totalAssetsValue,
        uint256 effectiveSupply,
        uint8 decimalsOffset
    )
        internal
        pure
        returns (uint256)
    {
        return shares.mulDiv(totalAssetsValue + 1, effectiveSupply + 10 ** decimalsOffset, Math.Rounding.Floor);
    }

    function convertToAssetsRoundUp(
        uint256 shares,
        uint256 totalAssetsValue,
        uint256 effectiveSupply,
        uint8 decimalsOffset
    )
        internal
        pure
        returns (uint256)
    {
        return shares.mulDiv(totalAssetsValue + 1, effectiveSupply + 10 ** decimalsOffset, Math.Rounding.Ceil);
    }

    function currentEpoch(uint256 genesisTimestamp, uint256 epochDuration) internal view returns (uint256) {
        if (block.timestamp < genesisTimestamp) return 0;
        return (block.timestamp - genesisTimestamp) / epochDuration;
    }

    function epochAtTimestamp(
        uint256 timestamp,
        uint256 genesisTimestamp,
        uint256 epochDuration
    )
        internal
        pure
        returns (uint256)
    {
        return timestamp < genesisTimestamp ? 0 : (timestamp - genesisTimestamp) / epochDuration;
    }

    function epochStartTime(
        uint256 epoch,
        uint256 genesisTimestamp,
        uint256 epochDuration
    )
        internal
        pure
        returns (uint256)
    {
        return genesisTimestamp + (epoch * epochDuration);
    }

    function getWithdrawalTiming(
        uint256 genesisTimestamp,
        uint256 epochDuration,
        uint256 withdrawalNotice
    )
        internal
        view
        returns (uint256 claimableEpoch)
    {
        uint256 currentEp = currentEpoch(genesisTimestamp, epochDuration);

        if (withdrawalNotice == epochDuration) return currentEp + 2;

        uint256 epochEnd = epochStartTime(currentEp + 1, genesisTimestamp, epochDuration);
        uint256 withdrawalDeadline = epochEnd - withdrawalNotice;

        if (block.timestamp <= withdrawalDeadline) {
            claimableEpoch = currentEp + 1;
        } else {
            claimableEpoch = currentEp + 2;
        }
    }
}
