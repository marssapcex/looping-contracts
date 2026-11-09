// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Atomic collateral-inflation feasibility model
/// @notice Pure arithmetic only. It answers one question for the Mango-style attack shape
///         "flashloan -> buy the collateral on the DEX -> supply it -> borrow the opposite
///         reserve -> repay the flashloan in the same transaction":
///
///         Does the borrow power unlocked by the collateral exceed what the flashloan demands
///         back, given (a) the reserve's LTV, (b) the flashloan premium and (c) the price the
///         attacker actually paid versus the price the protocol values the collateral at?
///
///         The DEX impact is already inside (c): the realized fill price is what the attacker
///         paid, and the oracle answer after the trade is what the protocol credits. Everything
///         is in the Aave-style 8-decimal base currency so it can be compared to
///         `getUserAccountData().availableBorrowsBase` directly.
library Economics {
    uint256 internal constant BPS = 10_000;

    /// @notice Borrow power unlocked per unit of base currency of collateral.
    function borrowPower(uint256 collateralValueBase, uint256 ltvBps) internal pure returns (uint256) {
        return (collateralValueBase * ltvBps) / BPS;
    }

    /// @notice Coverage of the flashloan by the collateral: 10_000 = exactly break even before
    ///         the premium. Below 10_000 the round trip loses money no matter how large the trade.
    function coverageBps(uint256 postSupplyAvailableBase, uint256 repaymentBase)
        internal
        pure
        returns (uint256)
    {
        if (repaymentBase == 0) return 0;
        return (postSupplyAvailableBase * BPS) / repaymentBase;
    }

    /// @notice Edge required for break even, where edge is
    ///         (oracle value of the bought collateral / price paid) - 1.
    ///         Derivation: LTV * (1 + edge) >= 1 + premium.
    ///         Returns type(uint256).max when LTV is zero (no amount of edge can help).
    function edgeRequiredBps(uint256 ltvBps, uint256 premiumBps) internal pure returns (uint256) {
        if (ltvBps == 0) return type(uint256).max;
        return ((BPS + premiumBps) * BPS) / ltvBps - BPS;
    }

    /// @notice LTV at which the measured fill would have broken even. If this number is above the
    ///         reserve's real LTV, the attack is infeasible at this block by this margin; if it is
    ///         below, the round trip is profitable.
    function breakevenLtvBps(int256 edgeBps, uint256 premiumBps) internal pure returns (uint256) {
        int256 ratio = int256(BPS) + edgeBps;
        if (ratio <= 0) return type(uint256).max;
        return ((BPS + premiumBps) * BPS) / uint256(ratio);
    }

    /// @notice Signed net base currency of the atomic round trip, before any borrowed asset is
    ///         sold: positive means the attacker can repay the flashloan and keep the difference.
    function netBase(uint256 postSupplyAvailableBase, uint256 repaymentBase) internal pure returns (int256) {
        return int256(postSupplyAvailableBase) - int256(repaymentBase);
    }

    /// @notice Realized execution price of a fill, normalised to the base asset's decimals.
    function execPrice(uint256 baseTraded, uint256 quoteTraded, uint256 baseDecimals, uint256 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        if (baseTraded == 0) return 0;
        return (quoteTraded * (10 ** baseDecimals)) / baseTraded / (10 ** (quoteDecimals > 18 ? 18 : 0));
    }

    /// @notice Signed edge of a fill under the protocol's own prices: how much more the protocol
    ///         values the collateral than the attacker paid for it.
    function unitEdgeBps(uint256 collateralValueBase, uint256 paidBase) internal pure returns (int256) {
        if (paidBase == 0) return 0;
        return int256((collateralValueBase * BPS) / paidBase) - int256(BPS);
    }
}
