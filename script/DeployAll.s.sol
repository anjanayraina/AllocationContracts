// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "forge-std/Script.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {StakingRewardsPool} from "../src/StakingRewardsPool-2026.sol";
import {StakingContract} from "../src/StakingContract-2026.sol";
import {FounderAllocationContract} from "../src/FounderAllocationContract-2026.sol";
import {DappStakeRouter} from "../src/DappStakeRouter-2026.sol";

// Minimal Interfaces for PancakeSwap V2 Setup
interface IPancakeRouter {
    function factory() external view returns (address);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

// Simple contract to act as deployed Gnosis Safe / multisig contracts
contract MockGnosisSafe {}

contract DeployAllScript is Script {
    // BSC Mainnet Constants
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    // Contracts
    AIEFToken public token;
    StakingRewardsPool public rewardsPool;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;
    DappStakeRouter public dappRouter;

    // Mock Wallets to satisfy code.length > 0 checks
    MockGnosisSafe public founderPoolWallet;
    MockGnosisSafe public lpAccumulatorWallet;
    MockGnosisSafe public opsSafe;
    MockGnosisSafe public signer;
    MockGnosisSafe public remainderWallet;

    function run() public {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Gnosis Safe mocks
        founderPoolWallet = new MockGnosisSafe();
        lpAccumulatorWallet = new MockGnosisSafe();
        opsSafe = new MockGnosisSafe();
        signer = new MockGnosisSafe();
        remainderWallet = new MockGnosisSafe();

        // 2. Deploy AIEFToken
        token = new AIEFToken(
            address(founderPoolWallet),
            address(lpAccumulatorWallet)
        );

        // 3. Deploy StakingRewardsPool
        rewardsPool = new StakingRewardsPool(
            address(token),
            address(opsSafe),
            address(signer)
        );

        // 4. Deploy StakingContract
        staking = new StakingContract(
            address(token),
            address(rewardsPool),
            address(opsSafe),
            address(founderPoolWallet),
            address(lpAccumulatorWallet)
        );

        // 5. Deploy FounderAllocationContract
        founderAlloc = new FounderAllocationContract(
            address(token),
            address(staking),
            address(opsSafe),
            5, // planId 5
            500, // maxFounders
            50_000e18, // maxAllocation
            block.timestamp + 30 days, // campaignEndTime
            address(remainderWallet)
        );

        // 6. Deploy DappStakeRouter
        dappRouter = new DappStakeRouter(
            address(token),
            USDT,
            PANCAKE_ROUTER,
            address(staking),
            address(opsSafe)
        );

        // 7. Setup configurations & exemptions
        token.setStakingRewardsPool(address(rewardsPool));

        address factory = IPancakeRouter(PANCAKE_ROUTER).factory();
        address dexPair = IPancakeFactory(factory).createPair(address(token), USDT);
        token.setDexPair(dexPair);

        // Mark contracts exempt in Token
        token.setExempt(address(staking), true, false);
        token.setExempt(address(dappRouter), true, true);
        token.setExempt(address(rewardsPool), true, false);
        token.setExempt(address(founderAlloc), true, false);

        // Authorize Router and FounderAllocationContract in StakingContract
        staking.setRouterCaller(address(dappRouter), true);
        staking.setAuthorizedPlanCaller(5, address(founderAlloc), true);

        // 8. Add Seed Liquidity to PancakeSwap (0.5M AIEF + e.g., 10,000 USDT)
        // Note: For local script execution, the caller will need USDT. If this script is run on Anvil
        // with a fork, the deployer can get USDT from standard deal cheats or pre-existing balance.
        uint256 aiefLiquidity = 500_000e18;
        uint256 usdtLiquidity = 10_000e18;

        token.approve(PANCAKE_ROUTER, aiefLiquidity);
        IERC20(USDT).approve(PANCAKE_ROUTER, usdtLiquidity);

        // Standard addLiquidity call (only if USDT balance is sufficient)
        if (IERC20(USDT).balanceOf(msg.sender) >= usdtLiquidity) {
            IPancakeRouter(PANCAKE_ROUTER).addLiquidity(
                address(token),
                USDT,
                aiefLiquidity,
                usdtLiquidity,
                0,
                0,
                msg.sender,
                block.timestamp
            );
        }

        // 9. Distribute Allocations
        token.transfer(address(rewardsPool), 400_000_000e18); // 400M
        token.transfer(address(founderAlloc), 25_000_000e18); // 25M
        
        // Empty remaining deployer balance to safes to enable trading
        uint256 remainingDeployerBalance = token.balanceOf(msg.sender);
        if (remainingDeployerBalance > 0) {
            token.transfer(address(remainderWallet), remainingDeployerBalance);
        }

        // 10. Enable Trading & Renounce Ownership
        token.removeExempt(msg.sender);
        token.enableTrading();
        token.renounceOwnership();

        vm.stopBroadcast();
    }
}
