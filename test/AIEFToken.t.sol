// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";

contract AIEFTokenTest is Test {
    AIEFToken public token;

    address public deployer = address(0xDE);
    address public founderPool = address(0x1111);
    address public lpAccumulator = address(0x2222);
    address public rewardsPool = address(0x3333);
    address public dexPair = address(0x4444);
    address public user1 = address(0x5555);
    address public user2 = address(0x6666);

    function setUp() public {
        // Etch code at addresses to bypass code.length > 0 checks in contract
        vm.etch(founderPool, new bytes(1));
        vm.etch(lpAccumulator, new bytes(1));
        vm.etch(rewardsPool, new bytes(1));
        vm.etch(dexPair, new bytes(1));

        vm.startPrank(deployer);
        token = new AIEFToken(founderPool, lpAccumulator);
        vm.stopPrank();
    }

    function test_InitialState() public {
        assertEq(token.name(), "AIEF");
        assertEq(token.symbol(), "AIEF");
        assertEq(token.totalSupply(), 500_000_000e18);
        assertEq(token.balanceOf(deployer), 500_000_000e18);
        
        // Deployer should be temporarily exempt
        assertTrue(token.isTransferBurnExempt(deployer));
        assertTrue(token.isDexRestrictionExempt(deployer));
    }

    function test_OneTimeSetters() public {
        vm.startPrank(deployer);

        token.setStakingRewardsPool(rewardsPool);
        assertEq(token.rewardsPool(), rewardsPool);

        // Reverts if trying to set rewards pool again
        vm.expectRevert("AIEF: already set");
        token.setStakingRewardsPool(address(0x99));

        token.setDexPair(dexPair);
        assertEq(token.dexPair(), dexPair);

        // Reverts if trying to set dex pair again
        vm.expectRevert("AIEF: pair already set");
        token.setDexPair(address(0x99));

        vm.stopPrank();
    }

    function test_ExemptionManagement() public {
        vm.startPrank(deployer);

        token.setExempt(user1, true, false);
        assertTrue(token.isTransferBurnExempt(user1));
        assertFalse(token.isDexRestrictionExempt(user1));

        token.removeExempt(user1);
        assertFalse(token.isTransferBurnExempt(user1));
        assertFalse(token.isDexRestrictionExempt(user1));

        vm.stopPrank();
    }

    function test_TradingEnablementGates() public {
        vm.startPrank(deployer);

        // Pre-setup
        token.setStakingRewardsPool(rewardsPool);
        token.setDexPair(dexPair);

        // 1. Should fail if deployer exemptions are not removed
        vm.expectRevert("AIEF: deployer exemption not removed");
        token.enableTrading();

        token.removeExempt(deployer);

        // 2. Should fail if deployer still holds tokens
        vm.expectRevert("AIEF: deployer must hold zero tokens");
        token.enableTrading();

        // Distribute all tokens so deployer has 0 balance
        token.transfer(user1, token.balanceOf(deployer));
        assertEq(token.balanceOf(deployer), 0);

        // 3. Succeeds now
        token.enableTrading();
        assertTrue(token.tradingEnabled());
        assertEq(token.restrictionEndTime(), block.timestamp + 180 days);

        // 4. Exemption actions should now revert since trading is enabled
        vm.expectRevert("AIEF: exemptions locked");
        token.setExempt(user2, true, false);

        vm.expectRevert("AIEF: exemptions locked");
        token.removeExempt(user1);

        vm.stopPrank();
    }

    function test_WalletToWalletTransferBurn() public {
        vm.startPrank(deployer);
        token.setStakingRewardsPool(rewardsPool);
        token.setDexPair(dexPair);
        token.transfer(user1, 1000e18);
        token.removeExempt(deployer);
        vm.stopPrank();

        // Wallet-to-wallet transfer from user1 to user2 should apply 0.5% burn
        uint256 amount = 100e18; // 100 tokens
        uint256 expectedBurn = (amount * 50) / 10000; // 0.5% = 0.5 tokens

        vm.prank(user1);
        token.transfer(user2, amount);

        assertEq(token.balanceOf(user2), amount - expectedBurn);
        assertEq(token.totalSupply(), 500_000_000e18 - expectedBurn);
    }

    function test_DexSellTaxSplit() public {
        vm.startPrank(deployer);
        token.setStakingRewardsPool(rewardsPool);
        token.setDexPair(dexPair);
        token.removeExempt(deployer);
        token.transfer(user1, 10_000e18);
        token.transfer(address(this), token.balanceOf(deployer)); // Empty deployer
        token.enableTrading();
        vm.stopPrank();

        // Set up initial balances
        uint256 user1BalanceBefore = token.balanceOf(user1);
        uint256 rewardsPoolBefore = token.balanceOf(rewardsPool);
        uint256 founderPoolBefore = token.balanceOf(founderPool);
        uint256 lpAccumulatorBefore = token.balanceOf(lpAccumulator);
        uint256 supplyBefore = token.totalSupply();

        // User1 sells 1000 tokens to DEX pair
        uint256 sellAmount = 1000e18;
        vm.prank(user1);
        token.transfer(dexPair, sellAmount);

        // Calculations:
        // Tax is 4% of 1000 = 40 tokens
        // Split into:
        // - Burn: 25% of 40 = 10 tokens (supply reduced by 10)
        // - Rewards: 25% of 40 = 10 tokens
        // - Founder: 25% of 40 = 10 tokens
        // - LP: 25% of 40 = 10 tokens (remainder)
        // Net transfer to DEX pair = 960 tokens
        // Transfer burn on net = 0.5% of 960 = 4.8 tokens (supply reduced by 4.8)
        // Total supply reduction = 14.8 tokens
        // DEX Pair receives 960 - 4.8 = 955.2 tokens

        assertEq(token.balanceOf(user1), user1BalanceBefore - sellAmount);
        assertEq(token.balanceOf(rewardsPool), rewardsPoolBefore + 10e18);
        assertEq(token.balanceOf(founderPool), founderPoolBefore + 10e18);
        assertEq(token.balanceOf(lpAccumulator), lpAccumulatorBefore + 10e18);
        assertEq(token.balanceOf(dexPair), 955.2e18);
        assertEq(token.totalSupply(), supplyBefore - 14.8e18);
    }
}
