// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

library MiniMath {
    function min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) { z = 1; }
    }
}

// Faithful local constant-product surrogate: 0.25% input fee, no feeTo mint.
contract MiniPair is ERC20 {
    using MiniMath for uint256;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    constructor(address _token0, address _token1) ERC20("Pancake LPs", "Cake-LP") {
        token0 = _token0;
        token1 = _token1;
    }
    function getReserves() external view returns (uint112, uint112, uint32) { return (reserve0, reserve1, 0); }
    function _update() internal {
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }
    function mint(address to) external returns (uint256 liquidity) {
        uint256 old0 = reserve0;
        uint256 old1 = reserve1;
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - old0;
        uint256 amount1 = balance1 - old1;
        if (totalSupply() == 0) {
            liquidity = MiniMath.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = MiniMath.min(amount0 * totalSupply() / old0, amount1 * totalSupply() / old1);
        }
        require(liquidity > 0, "insufficient liquidity");
        _mint(to, liquidity);
        _update();
    }
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        uint256 old0 = reserve0;
        uint256 old1 = reserve1;
        require(amount0Out < old0 && amount1Out < old1, "insufficient liquidity");
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > old0 - amount0Out ? balance0 - (old0 - amount0Out) : 0;
        uint256 amount1In = balance1 > old1 - amount1Out ? balance1 - (old1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "no input");
        uint256 adjusted0 = balance0 * 10000 - amount0In * 25;
        uint256 adjusted1 = balance1 * 10000 - amount1In * 25;
        require(adjusted0 * adjusted1 >= old0 * old1 * 10000 ** 2, "K");
        _update();
    }
}

contract MiniFactory {
    mapping(address => mapping(address => address)) public getPair;
    function createPair(address a, address b) external returns (address pair) {
        (address token0, address token1) = a < b ? (a, b) : (b, a);
        pair = address(new MiniPair(token0, token1));
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}

contract MiniRouter {
    MiniFactory public immutable factory;
    constructor(address _factory) { factory = MiniFactory(_factory); }
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 9975;
        return amountInWithFee * reserveOut / (reserveIn * 10000 + amountInWithFee);
    }
    function _reserves(address pair, address tokenIn) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        (uint112 reserve0, uint112 reserve1,) = MiniPair(pair).getReserves();
        (reserveIn, reserveOut) = tokenIn == MiniPair(pair).token0()
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
    }
    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i + 1 < path.length; i++) {
            address pair = factory.getPair(path[i], path[i + 1]);
            (uint256 reserveIn, uint256 reserveOut) = _reserves(pair, path[i]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "slippage");
        address pair = factory.getPair(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, pair, amountIn);
        (uint256 amount0Out, uint256 amount1Out) = path[0] == MiniPair(pair).token0()
            ? (uint256(0), amounts[1])
            : (amounts[1], uint256(0));
        MiniPair(pair).swap(amount0Out, amount1Out, to);
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        address pair = factory.getPair(path[0], path[1]);
        (uint256 reserveIn, uint256 reserveOut) = _reserves(pair, path[0]);
        uint256 balanceBefore = IERC20(path[1]).balanceOf(pair);
        IERC20(path[0]).transferFrom(msg.sender, pair, amountIn);
        uint256 balanceInAfter = IERC20(path[0]).balanceOf(pair);
        uint256 actualInput = balanceInAfter - reserveIn;
        uint256 amountOut = getAmountOut(actualInput, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "slippage");
        (uint256 amount0Out, uint256 amount1Out) = path[0] == MiniPair(pair).token0()
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        MiniPair(pair).swap(amount0Out, amount1Out, to);
        require(IERC20(path[1]).balanceOf(pair) == balanceBefore - amountOut, "output mismatch");
    }
    function _optimal(address pair, address tokenA, uint256 desiredA, uint256 desiredB)
        internal view returns (uint256 amountA, uint256 amountB)
    {
        (uint256 reserveA, uint256 reserveB) = _reserves(pair, tokenA);
        if (reserveA == 0 && reserveB == 0) return (desiredA, desiredB);
        uint256 optimalB = desiredA * reserveB / reserveA;
        if (optimalB <= desiredB) return (desiredA, optimalB);
        return (desiredB * reserveA / reserveB, desiredB);
    }
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 desiredA,
        uint256 desiredB,
        uint256,
        uint256,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        address pair = factory.getPair(tokenA, tokenB);
        (amountA, amountB) = _optimal(pair, tokenA, desiredA, desiredB);
        IERC20(tokenA).transferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).transferFrom(msg.sender, pair, amountB);
        liquidity = MiniPair(pair).mint(to);
    }
}
