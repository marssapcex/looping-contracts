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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00640000, 1037618708580) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00640001, 3) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00640005, 73) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00646002, elapsed) }
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00650000, 1037618708581) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00650001, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00650005, 585) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00656003, decimalsOffset) }
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00670000, 1037618708583) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00670001, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00670005, 585) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00676003, decimalsOffset) }
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00680000, 1037618708584) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00680001, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00680005, 585) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00686003, decimalsOffset) }
        return shares.mulDiv(totalAssetsValue + 1, effectiveSupply + 10 ** decimalsOffset, Math.Rounding.Ceil);
    }

    function currentEpoch(uint256 genesisTimestamp, uint256 epochDuration) internal view returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00660000, 1037618708582) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00660001, 2) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00660005, 9) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00666001, epochDuration) }
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00690000, 1037618708585) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00690001, 3) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00690005, 73) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00696002, epochDuration) }
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006a0000, 1037618708586) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006a0001, 3) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006a0005, 73) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006a6002, epochDuration) }
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006b0000, 1037618708587) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006b0001, 3) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006b0005, 73) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff006b6002, withdrawalNotice) }
        uint256 currentEp = currentEpoch(genesisTimestamp, epochDuration);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000010d,currentEp)}

        if (withdrawalNotice == epochDuration) return currentEp + 2;

        uint256 epochEnd = epochStartTime(currentEp + 1, genesisTimestamp, epochDuration);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000010e,epochEnd)}
        uint256 withdrawalDeadline = epochEnd - withdrawalNotice;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000010f,withdrawalDeadline)}

        if (block.timestamp <= withdrawalDeadline) {
            claimableEpoch = currentEp + 1;
        } else {
            claimableEpoch = currentEp + 2;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000110,claimableEpoch)}
        }
    }
}
