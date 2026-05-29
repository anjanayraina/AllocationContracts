// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {StakingRewardsPool} from "../src/StakingRewardsPool-2026.sol";
import {StakingContract} from "../src/StakingContract-2026.sol";
import {FounderAllocationContract} from "../src/FounderAllocationContract-2026.sol";
import {DappStakeRouter} from "../src/DappStakeRouter-2026.sol";

// Interfaces for Fork Integration Setup
interface IPancakeRouter02 {
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

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IPancakeFactory02 {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IERC20Fork {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract MockSafe {}

contract ForkIntegrationTest is Test {
    // BSC Mainnet Constants
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    // Deployed Contracts
    AIEFToken public token;
    StakingRewardsPool public rewardsPool;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;
    DappStakeRouter public dappRouter;

    // Gnosis Safe Mock Contracts
    MockSafe public founderPoolWallet;
    MockSafe public lpAccumulatorWallet;
    MockSafe public opsSafe;
    MockSafe public signer;
    MockSafe public remainderWallet;

    // Test Wallets
    address public deployer = address(0xDE);
    address public user = address(0x8888);

    uint256 public bscFork;

    function setUp() public {
        // Create and select the BSC Mainnet Fork dynamically
        // Using a highly reliable public BSC RPC Node
        bscFork = vm.createSelectFork("https://binance.llamarpc.com");

        string memory path = "./deployed_addresses.json";
        if (vm.exists(path)) {
            // Read addresses from the JSON file
            string memory json = vm.readFile(path);
            
            token = AIEFToken(vm.parseJsonAddress(json, ".token"));
            rewardsPool = StakingRewardsPool(vm.parseJsonAddress(json, ".rewardsPool"));
            staking = StakingContract(vm.parseJsonAddress(json, ".staking"));
            founderAlloc = FounderAllocationContract(vm.parseJsonAddress(json, ".founderAlloc"));
            dappRouter = DappStakeRouter(vm.parseJsonAddress(json, ".dappRouter"));
            
            founderPoolWallet = MockSafe(vm.parseJsonAddress(json, ".founderPoolWallet"));
            lpAccumulatorWallet = MockSafe(vm.parseJsonAddress(json, ".lpAccumulatorWallet"));
            opsSafe = MockSafe(vm.parseJsonAddress(json, ".opsSafe"));
            remainderWallet = MockSafe(vm.parseJsonAddress(json, ".remainderWallet"));
            
            // Signer is mocksafe in standard fork integration tests
            signer = MockSafe(address(0)); // Placeholders for signer if needed
        } else {
            // Deploy Gnosis Safe mock contracts
            vm.startPrank(deployer);
            founderPoolWallet = new MockSafe();
            lpAccumulatorWallet = new MockSafe();
            opsSafe = new MockSafe();
            signer = new MockSafe();
            remainderWallet = new MockSafe();

            // 1. Deploy contracts
            token = new AIEFToken(
                address(founderPoolWallet),
                address(lpAccumulatorWallet)
            );

            rewardsPool = new StakingRewardsPool(
                address(token),
                address(opsSafe),
                address(signer)
            );

            staking = new StakingContract(
                address(token),
                address(rewardsPool),
                address(opsSafe),
                address(founderPoolWallet),
                address(lpAccumulatorWallet)
            );

            founderAlloc = new FounderAllocationContract(
                address(token),
                address(staking),
                address(opsSafe),
                5, // planId 5
                500, // maxFounders
                50_000e18, // maxAllocation
                block.timestamp + 30 days,
                address(remainderWallet)
            );

            dappRouter = new DappStakeRouter(
                address(token),
                USDT,
                PANCAKE_ROUTER,
                address(staking),
                address(opsSafe)
            );

            // 2. Perform handshakes & configurations
            token.setStakingRewardsPool(address(rewardsPool));

            address factory = IPancakeRouter02(PANCAKE_ROUTER).factory();
            address dexPair = IPancakeFactory02(factory).createPair(address(token), USDT);
            token.setDexPair(dexPair);

            // Mark contracts exempt in Token
            token.setExempt(address(staking), true, false);
            token.setExempt(address(dappRouter), true, true);
            token.setExempt(address(rewardsPool), true, false);
            token.setExempt(address(founderAlloc), true, false);

            // Authorize Router and FounderAllocationContract in StakingContract
            staking.setRouterCaller(address(dappRouter), true);
            staking.setAuthorizedPlanCaller(5, address(founderAlloc), true);

            // 3. Seed PancakeSwap Liquidity (0.5M AIEF + 10,000 USDT)
            uint256 aiefLiquidity = 500_000e18;
            uint256 usdtLiquidity = 10_000e18;

            // Deal USDT to the deployer on the fork
            deal(USDT, deployer, usdtLiquidity);

            token.approve(PANCAKE_ROUTER, aiefLiquidity);
            IERC20Fork(USDT).approve(PANCAKE_ROUTER, usdtLiquidity);

            IPancakeRouter02(PANCAKE_ROUTER).addLiquidity(
                address(token),
                USDT,
                aiefLiquidity,
                usdtLiquidity,
                0,
                0,
                deployer,
                block.timestamp
            );

            // 4. Distribute allocations to clear deployer balance
            token.transfer(address(rewardsPool), 400_000_000e18); // 400M
            token.transfer(address(founderAlloc), 25_000_000e18); // 25M

            uint256 remainingDeployerBalance = token.balanceOf(deployer);
            if (remainingDeployerBalance > 0) {
                token.transfer(address(remainderWallet), remainingDeployerBalance);
            }

            // 5. Finalize token status & enable trading
            token.removeExempt(deployer);
            token.enableTrading();
            token.renounceOwnership();

            vm.stopPrank();
        }
    }

    function testFork_DexBuyRestrictionEnforcement() public {
        // Direct public buying of AIEF from PancakeSwap should fail during the 180-day restriction window
        uint256 buyUsdtAmount = 100e18; // 100 USDT
        deal(USDT, user, buyUsdtAmount);

        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = address(token);

        vm.startPrank(user);
        IERC20Fork(USDT).approve(PANCAKE_ROUTER, buyUsdtAmount);

        // Expect revert due to DEX restriction window (buy through dApp only)
        vm.expectRevert("AIEF: buy through dApp only");
        IPancakeRouter02(PANCAKE_ROUTER).swapExactTokensForTokens(
            buyUsdtAmount,
            0,
            path,
            user,
            block.timestamp + 10 minutes
        );
        vm.stopPrank();
    }

    function testFork_USDTStakingRouterRouteSuccess() public {
        // The DappStakeRouter should successfully bypass restriction and stake in a single transaction
        uint256 stakeUsdtAmount = 100e18; // 100 USDT
        deal(USDT, user, stakeUsdtAmount);

        vm.startPrank(user);
        IERC20Fork(USDT).approve(address(dappRouter), stakeUsdtAmount);

        // Call router.stake for Plan 1 (Standard plan: lock period = 60 days)
        // 0 slippage threshold to bypass preview checks
        uint256 positionId = dappRouter.stake(
            stakeUsdtAmount,
            0, // minAiefOut (0 is fine for sandbox/tests)
            1, // planId 1
            block.timestamp + 10 minutes
        );

        // Verify position details inside StakingContract
        assertEq(positionId, 0); // User's first position
        assertEq(staking.positionCount(user), 1);

        (uint256 principal, uint8 planId, uint64 stakedAt, uint32 lockPeriod, bool active) = staking.getPosition(user, positionId);
        assertTrue(principal > 0, "Principal should be non-zero");
        assertEq(planId, 1);
        assertEq(stakedAt, block.timestamp);
        assertEq(lockPeriod, 60 days);
        assertTrue(active);

        vm.stopPrank();
    }
}
