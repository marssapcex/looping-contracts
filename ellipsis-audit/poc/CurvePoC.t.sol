// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "./TestBase.sol";
import "./Mocks.sol";

interface ICryptoSwap {
    function initialize(
        uint256 A,
        uint256 gamma,
        uint256 mid_fee,
        uint256 out_fee,
        uint256 allowed_extra_profit,
        uint256 fee_gamma,
        uint256 adjustment_step,
        uint256 admin_fee,
        uint256 ma_half_time,
        uint256 initial_price,
        address _token,
        address[2] calldata _coins,
        uint256 _precisions
    ) external;
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount, bool use_eth, address receiver) external payable returns (uint256);
    function remove_liquidity(uint256 amount, uint256[2] calldata min_amounts, bool use_eth, address receiver) external;
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, bool use_eth, address receiver) external payable returns (uint256);
    function exchange_extended(int128 i, int128 j, uint256 dx, uint256 min_dy, bool use_eth, address sender, address receiver, bytes32 cb) external payable returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function balances(uint256 i) external view returns (uint256);
    function D() external view returns (uint256);
    function virtual_price() external view returns (uint256);
    function mid_fee() external view returns (uint256);
}

contract CallbackExchanger {
    ICryptoSwap public immutable pool;
    MockMintableToken public immutable inputCoin;
    bool public reentryRejected;

    constructor(ICryptoSwap _pool, MockMintableToken _inputCoin) {
        pool = _pool;
        inputCoin = _inputCoin;
    }

    function callback(address, address, address, uint256 dx, uint256) external {
        require(msg.sender == address(pool), "only pool callback");
        (bool ok, ) = address(pool).call(
            abi.encodeWithSelector(ICryptoSwap.exchange.selector, int128(0), int128(1), uint256(1), uint256(0), false, address(this))
        );
        reentryRejected = !ok;
        require(inputCoin.transfer(msg.sender, dx), "callback input transfer");
    }

    function swap(uint256 dx) external returns (uint256) {
        bytes32 cb = bytes32(this.callback.selector);
        return pool.exchange_extended(0, 1, dx, 0, false, address(this), address(this), cb);
    }
}

contract CurvePoC is TestBase {
    ICryptoSwap internal constant pool = ICryptoSwap(address(0xC0FFEE));
    MockMintableToken internal coin0;
    MockMintableToken internal coin1;
    MockCurveLPToken internal lp;

    function setUp() public {
        deployVyperRuntime("evidence/curve.runtime", address(pool));
        coin0 = new MockMintableToken("Model coin zero", "MC0", 18);
        coin1 = new MockMintableToken("Model coin one", "MC1", 18);
        lp = new MockCurveLPToken();
        lp.setMinter(address(pool));
        _initialize();

        coin0.mint(address(this), 10_000_000 ether);
        coin1.mint(address(this), 10_000_000 ether);
        coin0.approve(address(pool), type(uint256).max);
        coin1.approve(address(pool), type(uint256).max);
        uint256[2] memory amounts = [uint256(1_000_000 ether), uint256(1_000_000 ether)];
        uint256 minted = pool.add_liquidity(amounts, 1, false, address(this));
        assertGt(minted, 0, "initial exact-Vyper liquidity");
    }

    function _initialize() internal {
        address[2] memory coins = [address(coin0), address(coin1)];
        pool.initialize(
            4_000_000,
            145_000_000_000_000,
            5_000_000,
            20_000_000,
            2_000_000_000_000,
            50_000_000_000_000_000,
            100_000_000_000_000,
            0,
            600,
            1 ether,
            address(lp),
            coins,
            0
        );
    }

    function test_initialize_cannot_run_twice() public {
        assertGt(pool.mid_fee(), 0, "initialized fee");
        vm.expectRevert();
        _initialize();
    }

    function test_get_dy_matches_real_exchange() public {
        uint256 dx = 1_000 ether;
        uint256 quoted = pool.get_dy(0, 1, dx);
        uint256 before0 = coin0.balanceOf(address(this));
        uint256 before1 = coin1.balanceOf(address(this));
        uint256 dy = pool.exchange(0, 1, dx, quoted, false, address(this));
        assertEq(dy, quoted, "quote and executable exchange");
        assertEq(before0 - coin0.balanceOf(address(this)), dx, "input delta");
        assertEq(coin1.balanceOf(address(this)) - before1, dy, "output delta");
        console.log("EXACT_VYPER normal swap dx raw 1e18", dx);
        console.log("EXACT_VYPER normal swap dy raw 1e18", dy);
    }

    function test_extended_callback_reentry_rejected() public {
        CallbackExchanger callback = new CallbackExchanger(pool, coin0);
        coin0.mint(address(callback), 10_000 ether);
        uint256 before0 = coin0.balanceOf(address(callback));
        uint256 before1 = coin1.balanceOf(address(callback));
        uint256 dy = callback.swap(1_000 ether);
        assertTrue(callback.reentryRejected(), "nonreentrant exchange must reject nested swap");
        assertEq(before0 - coin0.balanceOf(address(callback)), 1_000 ether, "callback paid input");
        assertEq(coin1.balanceOf(address(callback)) - before1, dy, "callback received output");
        console.log("EXACT_VYPER callback nested exchange rejected=1; no drain P&L", int256(0));
    }

    function test_proportional_withdrawal_burns_lp_and_returns_coins() public {
        uint256 burn = lp.balanceOf(address(this)) / 10;
        uint256 lpSupplyBefore = lp.totalSupply();
        uint256 before0 = coin0.balanceOf(address(this));
        uint256 before1 = coin1.balanceOf(address(this));
        uint256[2] memory minimums = [uint256(0), uint256(0)];
        pool.remove_liquidity(burn, minimums, false, address(this));
        uint256 received0 = coin0.balanceOf(address(this)) - before0;
        uint256 received1 = coin1.balanceOf(address(this)) - before1;
        assertGt(received0, 0, "coin zero withdrawn");
        assertGt(received1, 0, "coin one withdrawn");
        assertEq(lpSupplyBefore - lp.totalSupply(), burn, "LP burned exactly once");
        console.log("EXACT_VYPER withdrawal LP cost raw 1e18", burn);
        console.log("EXACT_VYPER withdrawal coin0 raw 1e18", received0);
        console.log("EXACT_VYPER withdrawal coin1 raw 1e18", received1);
    }

    function testFuzz_swap_quote_execution(uint256 dx) public {
        dx = dx % 10_000 ether;
        if (dx < 1e6) dx = 1e6;
        uint256 quoted = pool.get_dy(0, 1, dx);
        uint256 dy = pool.exchange(0, 1, dx, quoted, false, address(this));
        assertEq(dy, quoted, "fuzz quote equals execution");
        assertGt(dy, 0, "positive output");
    }
}
