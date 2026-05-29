// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {StakingContract} from "../src/StakingContract-2026.sol";

contract StakingContractTest is Test {
    AIEFToken public token;
    StakingContract public staking;

    address public deployer = address(0xDE);
    address public founderPool = address(0x1111);
    address public lpAccumulator = address(0x2222);
    address public rewardsPool = address(0x3333);
    address public opsSafe = address(0x4444);
    address public dexPair = address(0x5555);
    address public user = address(0x6666);
    address public router = address(0x7777);

    function setUp() public {
        vm.etch(founderPool, new bytes(1));
        vm.etch(lpAccumulator, new bytes(1));
        vm.etch(rewardsPool, new bytes(1));
        vm.etch(opsSafe, new bytes(1));
        vm.etch(dexPair, new bytes(1));
        vm.etch(router, new bytes(1));

        vm.startPrank(deployer);
        token = new AIEFToken(founderPool, lpAccumulator);
        token.setStakingRewardsPool(rewardsPool);
        token.setDexPair(dexPair);
        
        staking = new StakingContract(
            address(token),
            rewardsPool,
            opsSafe,
            founderPool,
            lpAccumulator
        );

        // Make StakingContract burn exempt so staking deposits aren't burned by 0.5%
        token.setExempt(address(staking), true, false);

        // Distribute some tokens to the user
        token.transfer(user, 10_000e18);
        vm.stopPrank();
    }

    function test_InitialPlans() public {
        (bool exists, bool active, bool directAllowed, bool routerAllowed, uint32 lockPeriod) = staking.plans(0);
        assertTrue(exists);
        assertTrue(active);
        assertTrue(directAllowed);
        assertFalse(routerAllowed);
        assertEq(lockPeriod, 0);

        (exists, active, directAllowed, routerAllowed, lockPeriod) = staking.plans(1);
        assertTrue(exists);
        assertTrue(active);
        assertTrue(directAllowed);
        assertTrue(routerAllowed);
        assertEq(lockPeriod, 60 days);
    }

    function test_RegisterNewPlan() public {
        vm.startPrank(opsSafe);
        staking.registerPlan(
            6,
            StakingContract.PlanConfig({
                exists: true,
                active: true,
                directAllowed: true,
                routerAllowed: false,
                lockPeriod: 90 days
            })
        );

        (bool exists, bool active, bool directAllowed, bool routerAllowed, uint32 lockPeriod) = staking.plans(6);
        assertTrue(exists);
        assertTrue(active);
        assertTrue(directAllowed);
        assertFalse(routerAllowed);
        assertEq(lockPeriod, 90 days);
        vm.stopPrank();
    }

    function test_PauseNewStakesOnly() public {
        vm.startPrank(opsSafe);
        staking.pauseNewStakes(true);
        assertTrue(staking.newStakesPaused());

        // Staking should fail when paused
        vm.startPrank(user);
        token.approve(address(staking), 100e18);
        vm.expectRevert("SC: new stakes paused");
        staking.stake(100e18, 0);
        vm.stopPrank();
    }

    function test_DirectStakingAndUnstakingWithTiers() public {
        vm.startPrank(user);
        token.approve(address(staking), 1000e18);

        // --- Tier 1: Stake and immediately Unstake (20% exit deduction) ---
        staking.stake(200e18, 0); // Plan 0 (Flexible)
        assertEq(staking.positionCount(user), 1);

        uint256 userBalanceBefore = token.balanceOf(user);
        
        // Unstake immediately
        staking.unstake(0);
        
        // 20% of 200 = 40 tokens exit fee. User gets 160 back.
        assertEq(token.balanceOf(user), userBalanceBefore + 160e18);

        // --- Tier 2: Stake, warp 65 days (10% exit deduction) ---
        staking.stake(200e18, 0);
        userBalanceBefore = token.balanceOf(user);
        
        vm.warp(block.timestamp + 65 days);
        staking.unstake(1);
        
        // 10% of 200 = 20 tokens exit fee. User gets 180 back.
        assertEq(token.balanceOf(user), userBalanceBefore + 180e18);

        // --- Tier 3: Stake, warp 130 days (5% exit deduction) ---
        staking.stake(200e18, 0);
        userBalanceBefore = token.balanceOf(user);
        
        vm.warp(block.timestamp + 130 days);
        staking.unstake(2);
        
        // 5% of 200 = 10 tokens exit fee. User gets 190 back.
        assertEq(token.balanceOf(user), userBalanceBefore + 190e18);

        // --- Tier 4: Stake, warp 210 days (0% exit deduction) ---
        staking.stake(200e18, 0);
        userBalanceBefore = token.balanceOf(user);
        
        vm.warp(block.timestamp + 210 days);
        staking.unstake(3);
        
        // 0% exit fee. User gets full 200 back.
        assertEq(token.balanceOf(user), userBalanceBefore + 200e18);

        vm.stopPrank();
    }

    function test_LockPeriodEnforcement() public {
        vm.startPrank(user);
        token.approve(address(staking), 500e18);

        // Stake in Plan 1 (Standard: 60-day lock)
        staking.stake(500e18, 1);
        
        // Unstaking early should fail
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert("SC: position locked");
        staking.unstake(0);

        // Unstaking after 60 days should succeed
        vm.warp(block.timestamp + 55 days); // Total elapsed = 65 days
        staking.unstake(0);
        vm.stopPrank();
    }
}
