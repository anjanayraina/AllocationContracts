// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {StakingContract} from "../src/StakingContract-2026.sol";
import {
    FounderAllocationContract
} from "../src/FounderAllocationContract-2026.sol";

contract FounderAllocationContractTest is Test {
    AIEFToken public token;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;

    address public deployer = address(0xDE);
    address public founderPool = address(0x1111);
    address public lpAccumulator = address(0x2222);
    address public rewardsPool = address(0x3333);
    address public opsSafe = address(0x4444);
    address public dexPair = address(0x5555);
    address public remainderWallet = address(0x6666);
    address public founder1 = address(0x7777);
    address public founder2 = address(0x8888);

    uint8 public founderPlanId = 5;
    uint256 public maxFounders = 2;
    uint256 public maxAllocation = 50_000e18;
    uint256 public campaignDuration = 30 days;
    uint256 public campaignEndTime;

    function setUp() public {
        vm.etch(founderPool, new bytes(1));
        vm.etch(lpAccumulator, new bytes(1));
        vm.etch(rewardsPool, new bytes(1));
        vm.etch(opsSafe, new bytes(1));
        vm.etch(dexPair, new bytes(1));
        vm.etch(remainderWallet, new bytes(1));

        campaignEndTime = block.timestamp + campaignDuration;

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

        founderAlloc = new FounderAllocationContract(
            address(token),
            address(staking),
            opsSafe,
            founderPlanId,
            maxFounders,
            maxAllocation,
            campaignEndTime,
            remainderWallet
        );

        // Make both StakingContract and FounderAllocationContract burn-exempt
        token.setExempt(address(staking), true, false);
        token.setExempt(address(founderAlloc), true, false);

        // Seed FounderAllocationContract with tokens for the campaign
        token.transfer(address(founderAlloc), 100_000e18);
        vm.stopPrank();

        // Authorize FounderAllocationContract in StakingContract for plan 5
        vm.prank(opsSafe);
        staking.setAuthorizedPlanCaller(
            founderPlanId,
            address(founderAlloc),
            true
        );
    }

    function test_Initialization() public {
        assertEq(address(founderAlloc.token()), address(token));
        assertEq(address(founderAlloc.stakingContract()), address(staking));
        assertEq(founderAlloc.opsSafe(), opsSafe);
        assertEq(founderAlloc.founderPlanId(), founderPlanId);
        assertEq(founderAlloc.maxFounders(), maxFounders);
        assertEq(founderAlloc.maxAllocationPerFounder(), maxAllocation);
        assertEq(founderAlloc.campaignEndTime(), campaignEndTime);
        assertEq(founderAlloc.remainderWallet(), remainderWallet);
        assertEq(founderAlloc.poolBalance(), 100_000e18);
    }

    function test_RegisterFounderSuccess() public {
        uint256 allocAmount = 40_000e18;

        vm.startPrank(opsSafe);
        founderAlloc.registerFounder(founder1, allocAmount);

        assertTrue(founderAlloc.isFounder(founder1));
        assertEq(founderAlloc.founderCount(), 1);
        assertEq(founderAlloc.totalAllocated(), allocAmount);

        (
            uint256 founderNum,
            uint256 allocatedAmount,
            uint256 positionId,
            uint64 registeredAt
        ) = founderAlloc.getFounderInfo(founder1);
        assertEq(founderNum, 1);
        assertEq(allocatedAmount, allocAmount);
        assertEq(positionId, 0); // first position in StakingContract for founder1
        assertEq(registeredAt, block.timestamp);

        // Check StakingContract record
        (
            uint256 principal,
            uint8 planId,
            uint64 stakedAt,
            uint32 lockPeriod,
            bool active
        ) = staking.getPosition(founder1, 0);
        assertEq(principal, allocAmount);
        assertEq(planId, founderPlanId);
        assertEq(stakedAt, block.timestamp);
        assertEq(lockPeriod, 360 days); // Plan 5 has 360 days lock
        assertTrue(active);

        vm.stopPrank();
    }

    function test_RegisterFounderFailures() public {
        vm.startPrank(opsSafe);

        // 1. Should fail if amount is above cap
        vm.expectRevert("FAC: above allocation cap");
        founderAlloc.registerFounder(founder1, maxAllocation + 1);

        // 2. Should fail if amount is below minimum stake (1 AIEF)
        vm.expectRevert("FAC: below min stake");
        founderAlloc.registerFounder(founder1, 0.5e18);

        // Register founder1 successfully
        founderAlloc.registerFounder(founder1, 40_000e18);

        // 3. Should fail if registering duplicate wallet
        vm.expectRevert("FAC: already registered");
        founderAlloc.registerFounder(founder1, 10_000e18);

        // Register founder2 to reach max seats
        founderAlloc.registerFounder(founder2, 40_000e18);

        // 4. Should fail if seats are full
        address founder3 = address(0x9999);
        vm.expectRevert("FAC: all seats filled");
        founderAlloc.registerFounder(founder3, 10_000e18);

        vm.stopPrank();
    }

    function test_RemainderReleaseCondition() public {
        // Unused balance is 100,000 AIEF.
        // Try to release remainder early (should revert since campaign has not ended nor are seats filled)
        vm.startPrank(opsSafe);
        vm.expectRevert("FAC: remainder not releasable");
        founderAlloc.transferRemainder();

        // Warp past campaign end time
        vm.warp(campaignEndTime + 1);

        uint256 walletBalanceBefore = token.balanceOf(remainderWallet);
        founderAlloc.transferRemainder();

        assertEq(
            token.balanceOf(remainderWallet),
            walletBalanceBefore + 100_000e18
        );
        assertEq(founderAlloc.poolBalance(), 0);
        vm.stopPrank();
    }
}
