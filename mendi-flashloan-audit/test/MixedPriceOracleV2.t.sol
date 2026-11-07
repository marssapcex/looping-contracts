// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import { Test } from "forge-std/Test.sol";
import { MixedPriceOracleV2, PriceConfig } from "../upstream/contracts/PriceOracle/MixedPriceOracleV2.sol";
import { CToken } from "../upstream/contracts/CToken.sol";

contract MockCToken {
    string public symbol;

    constructor(string memory symbol_) {
        symbol = symbol_;
    }
}

contract MockFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    string public description;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_, string memory description_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = 1;
        description = description_;
    }

    function setRound(int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return updatedAt;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, answeredInRound);
    }
}

contract MixedPriceOracleV2Test is Test {
    uint256 internal constant STALE_AGE = 365 days;

    MockCToken internal meUsdc;
    MockCToken internal meWeth;
    MockCToken internal meWeEth;
    MockFeed internal usdcFeed;
    MockFeed internal wethFeed;
    MockFeed internal weEthRatioFeed;
    MixedPriceOracleV2 internal oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        meUsdc = new MockCToken("meUSDC");
        meWeth = new MockCToken("meWETH");
        meWeEth = new MockCToken("meweETH");
        usdcFeed = new MockFeed(8, 1e8, block.timestamp - STALE_AGE, "USDC / USD");
        wethFeed = new MockFeed(8, 2_000e8, block.timestamp - STALE_AGE, "ETH / USD");
        weEthRatioFeed = new MockFeed(8, 1.05e8, block.timestamp - STALE_AGE, "weETH / ETH");

        string[] memory symbols = new string[](3);
        symbols[0] = "meUSDC";
        symbols[1] = "meWETH";
        symbols[2] = "meweETH";
        PriceConfig[] memory configs = new PriceConfig[](3);
        configs[0] = PriceConfig(_addressId(address(usdcFeed)), "USD", 6);
        configs[1] = PriceConfig(_addressId(address(wethFeed)), "USD", 18);
        configs[2] = PriceConfig(_addressId(address(weEthRatioFeed)), "meWETH", 18);
        oracle = new MixedPriceOracleV2(symbols, configs);
    }

    function testStaleOneYearOldChainlinkStyleAnswerIsAccepted() public view {
        assertEq(block.timestamp - usdcFeed.updatedAt(), STALE_AGE);
        assertEq(oracle.getPrice(CToken(address(meUsdc))), 1e18);
        assertEq(oracle.getUnderlyingPrice(CToken(address(meUsdc))), 1e30);
    }

    function testIncompleteRoundAndZeroAnsweredInRoundAreNotRejected() public {
        usdcFeed.setRound(1.02e8, block.timestamp - STALE_AGE, 0);
        assertEq(oracle.getPrice(CToken(address(meUsdc))), 1.02e18);
    }

    function testRecursiveLstRatioScaling() public view {
        assertEq(oracle.getPrice(CToken(address(meWeEth))), 2_100e18);
        assertEq(oracle.getUnderlyingPrice(CToken(address(meWeEth))), 2_100e18);
    }

    function testZeroAnswerIsRejected() public {
        usdcFeed.setRound(0, block.timestamp - STALE_AGE, 0);
        vm.expectRevert("price cannot be zero");
        oracle.getPrice(CToken(address(meUsdc)));
    }

    function testMissingConfigIsRejected() public {
        MockCToken unknown = new MockCToken("meUNKNOWN");
        vm.expectRevert("missing priceFeed");
        oracle.getPrice(CToken(address(unknown)));
    }

    function _addressId(address feed) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(feed)));
    }
}
