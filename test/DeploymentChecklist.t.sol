// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {StakingRewardsPool} from "../src/StakingRewardsPool-2026.sol";
import {StakingContract} from "../src/StakingContract-2026.sol";
import {FounderAllocationContract} from "../src/FounderAllocationContract-2026.sol";
import {EcosystemPaymentContract} from "../src/EcosystemPaymentContract-2026.sol";
import {DappStakeRouter} from "../src/DappStakeRouter-2026.sol";

// Minimal Interfaces for Mock Setup
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
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

// Mock Safe Contract to act as Gnosis Safes
contract MockGnosisSafe {
    address public owner;
    constructor() {
        owner = msg.sender;
    }
    function executeCall(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "MockSafe: only owner");
        (bool success, bytes memory result) = target.call(data);
        require(success, "MockSafe: call failed");
        return result;
    }
}

// Mock PancakeFactory
contract MockPancakeFactory {
    address public immutable pair;
    constructor(address _pair) {
        pair = _pair;
    }
    function getPair(address, address) external view returns (address) {
        return pair;
    }
    function createPair(address, address) external returns (address) {
        return pair;
    }
}

// Mock PancakeRouter
contract MockPancakeRouter {
    address public immutable factoryAddr;
    constructor(address _factory) {
        factoryAddr = _factory;
    }
    function factory() external view returns (address) {
        return factoryAddr;
    }
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address,
        uint256
    ) external returns (uint256, uint256, uint256) {
        IERC20(tokenA).transferFrom(msg.sender, address(0xDEAD), amountADesired);
        IERC20(tokenB).transferFrom(msg.sender, address(0xDEAD), amountBDesired);
        return (amountADesired, amountBDesired, 0);
    }
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1-to-1 mock swap
        IERC20(path[0]).transferFrom(msg.sender, address(0xDEAD), amountIn);
        IERC20(path[1]).transfer(to, amounts[1]);
    }
}

// Mock USDT
contract MockUSDT {
    string public name = "Mock USDT";
    string public symbol = "USDT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract DeploymentChecklistTest is Test {
    // Confirmed Wallet Addresses & Roles
    address public DEPLOYER_EOA;
    address public LP_ACCUMULATOR_WALLET;
    address public FOUNDER_POOL_WALLET;
    address public OPS_SAFE;
    address public TREASURY_SAFE;
    address public BACKEND_SIGNER;

    // Keys for EOA simulation
    uint256 public deployerPrivateKey = 0x1111111111111111111111111111111111111111111111111111111111111111;
    uint256 public signerPrivateKey = 0x2222222222222222222222222222222222222222222222222222222222222222;

    // External Mock Contracts
    address public PANCAKESWAP_V2_ROUTER;
    address public BSC_USDT;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // AIEF Contracts
    AIEFToken public token;
    StakingRewardsPool public rewardsPool;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;
    EcosystemPaymentContract public ecosystemPayment;
    DappStakeRouter public dappRouter;
    address public pair;

    function setUp() public {
        DEPLOYER_EOA = vm.addr(deployerPrivateKey);
        BACKEND_SIGNER = vm.addr(signerPrivateKey);

        // Pre-fund deployer with BNB for gas simulation
        vm.deal(DEPLOYER_EOA, 100 ether);

        // Start deploying our standard mocks
        vm.startPrank(DEPLOYER_EOA);

        LP_ACCUMULATOR_WALLET = address(new MockGnosisSafe());
        FOUNDER_POOL_WALLET = address(new MockGnosisSafe());
        OPS_SAFE = address(new MockGnosisSafe());
        TREASURY_SAFE = address(new MockGnosisSafe());

        // Deploys Mock USDT
        MockUSDT mockUsdt = new MockUSDT();
        BSC_USDT = address(mockUsdt);
        mockUsdt.mint(DEPLOYER_EOA, 1_000_000e18);

        // Deploys Mock PancakeSwap V2 Factory and Router
        address mockPair = address(new MockGnosisSafe());
        address mockFactory = address(new MockPancakeFactory(mockPair));
        PANCAKESWAP_V2_ROUTER = address(new MockPancakeRouter(mockFactory));

        // ════════════════════════════════════════════════════════════════════════════════
        // DEPLOYMENT SEQUENCE (Steps 1 to 11)
        // ════════════════════════════════════════════════════════════════════════════════

        // Step 1 - Deploy AIEFToken
        token = new AIEFToken(
            FOUNDER_POOL_WALLET,
            LP_ACCUMULATOR_WALLET
        );

        // Step 2 - Deploy StakingRewardsPool
        rewardsPool = new StakingRewardsPool(
            address(token),
            OPS_SAFE,
            BACKEND_SIGNER
        );

        // Step 3 - Deploy StakingContract
        staking = new StakingContract(
            address(token),
            address(rewardsPool),
            OPS_SAFE,
            FOUNDER_POOL_WALLET,
            LP_ACCUMULATOR_WALLET
        );

        // Step 4 - Deploy FounderAllocationContract
        founderAlloc = new FounderAllocationContract(
            address(token),
            address(staking),
            OPS_SAFE,
            5, // founderPlanId
            500, // maxFounders
            50_000e18, // maxAllocationPerFounder
            block.timestamp + 180 days, // 6 months post-deploy
            TREASURY_SAFE // remainderWallet
        );

        // Step 5 - Deploy EcosystemPaymentContract
        ecosystemPayment = new EcosystemPaymentContract(
            address(token),
            address(rewardsPool),
            TREASURY_SAFE,
            OPS_SAFE
        );

        // Step 6 - Deploy DappStakeRouter
        dappRouter = new DappStakeRouter(
            address(token),
            BSC_USDT,
            PANCAKESWAP_V2_ROUTER,
            address(staking),
            OPS_SAFE
        );

        // Step 11 - Set All Exemptions in AIEFToken
        token.setExempt(address(dappRouter), true, true);
        token.setExempt(address(staking), true, false);
        token.setExempt(address(rewardsPool), true, false);
        token.setExempt(address(founderAlloc), true, false);
        token.setExempt(address(ecosystemPayment), true, false);
        token.setExempt(LP_ACCUMULATOR_WALLET, true, false);
        token.setExempt(FOUNDER_POOL_WALLET, true, false);
        token.setExempt(TREASURY_SAFE, true, false);
        token.setExempt(OPS_SAFE, true, false);

        // Step 7 - Distribute Token Allocations
        token.transfer(address(rewardsPool), 400_000_000e18); // 80% Rewards Pool
        token.transfer(address(founderAlloc), 25_000_000e18); // 5% Founders Pool
        
        // Transfer exactly remaining balance of the deploymentWallet to Treasury Safe to clear out to 0
        uint256 deployerRemaining = token.balanceOf(DEPLOYER_EOA);
        if (deployerRemaining > 0) {
            token.transfer(TREASURY_SAFE, deployerRemaining);
        }

        // Step 8 - Set StakingRewardsPool Address in AIEFToken
        token.setStakingRewardsPool(address(rewardsPool));

        // Step 9 - Seed PancakeSwap Liquidity and Create Pair
        uint256 aiefLiquidity = 500_000e18;
        uint256 usdtLiquidity = 10_000e18;

        address factory = IPancakeRouter(PANCAKESWAP_V2_ROUTER).factory();
        pair = IPancakeFactory(factory).getPair(address(token), BSC_USDT);
        if (pair == address(0)) {
            pair = IPancakeFactory(factory).createPair(address(token), BSC_USDT);
        }

        MockUSDT(BSC_USDT).mint(DEPLOYER_EOA, usdtLiquidity);
        IERC20(BSC_USDT).approve(PANCAKESWAP_V2_ROUTER, usdtLiquidity);
        
        // Transfer 500k AIEF back temporarily to deployer just to seed liquidity
        MockGnosisSafe(TREASURY_SAFE).executeCall(
            address(token),
            abi.encodeWithSignature("transfer(address,uint256)", DEPLOYER_EOA, aiefLiquidity)
        );

        token.approve(PANCAKESWAP_V2_ROUTER, aiefLiquidity);
        IPancakeRouter(PANCAKESWAP_V2_ROUTER).addLiquidity(
            address(token),
            BSC_USDT,
            aiefLiquidity,
            usdtLiquidity,
            0,
            0,
            DEPLOYER_EOA,
            block.timestamp + 10 minutes
        );

        // Transfer 100k AIEF to mock router so it can fulfill mock swaps
        MockGnosisSafe(TREASURY_SAFE).executeCall(
            address(token),
            abi.encodeWithSignature("transfer(address,uint256)", PANCAKESWAP_V2_ROUTER, 100_000e18)
        );

        // Step 10 - Register DEX Pair in AIEFToken
        token.setDexPair(pair);

        // Step 12 - Configure StakingContract via Mock Gnosis Safes
        MockGnosisSafe(OPS_SAFE).executeCall(
            address(staking),
            abi.encodeWithSignature("setRouterCaller(address,bool)", address(dappRouter), true)
        );
        MockGnosisSafe(OPS_SAFE).executeCall(
            address(staking),
            abi.encodeWithSignature("setAuthorizedPlanCaller(uint8,address,bool)", 5, address(founderAlloc), true)
        );

        // Remove deployer exemption right before enableTrading
        token.removeExempt(DEPLOYER_EOA);

        // Sweep any remaining deploymentWallet balance to Treasury Safe right before enableTrading to guarantee 0-balance check passes
        uint256 finalDeployerBal = token.balanceOf(DEPLOYER_EOA);
        if (finalDeployerBal > 0) {
            token.transfer(TREASURY_SAFE, finalDeployerBal);
        }

        // Step 14 - Enable Trading + Renounce Ownership
        token.enableTrading();
        token.renounceOwnership();

        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // PART 3 - PRE-FLIGHT & STATE VERIFICATION CHECKLIST
    // ════════════════════════════════════════════════════════════════════════════════

    function testChecklist_TokenStateVerification() public {
        assertEq(token.totalSupply(), 500_000_000e18, "Checklist: totalSupply mismatch");
        assertTrue(token.tradingEnabled(), "Checklist: tradingEnabled should be true");
        assertEq(token.rewardsPool(), address(rewardsPool), "Checklist: rewardsPool address mismatch");
        assertEq(token.dexPair(), pair, "Checklist: dexPair mismatch");
        assertEq(token.founderPoolWallet(), FOUNDER_POOL_WALLET, "Checklist: founderPoolWallet mismatch");
        assertEq(token.lpAccumulatorWallet(), LP_ACCUMULATOR_WALLET, "Checklist: lpAccumulatorWallet mismatch");
        assertEq(token.owner(), address(0), "Checklist: owner should be renounced");
        assertTrue(token.restrictionEndTime() > block.timestamp, "Checklist: restrictionEndTime should be in future");

        // Exemption Checks
        assertTrue(token.isTransferBurnExempt(address(dappRouter)), "Checklist: DappStakeRouter burnExempt mismatch");
        assertTrue(token.isDexRestrictionExempt(address(dappRouter)), "Checklist: DappStakeRouter dexExempt mismatch");
        assertTrue(token.isTransferBurnExempt(address(staking)), "Checklist: StakingContract burnExempt mismatch");
        assertFalse(token.isDexRestrictionExempt(address(staking)), "Checklist: StakingContract dexExempt mismatch");
        assertTrue(token.isTransferBurnExempt(address(rewardsPool)), "Checklist: StakingRewardsPool burnExempt mismatch");
        assertTrue(token.isTransferBurnExempt(address(founderAlloc)), "Checklist: FounderAllocationContract burnExempt mismatch");
        assertTrue(token.isTransferBurnExempt(address(ecosystemPayment)), "Checklist: EcosystemPaymentContract burnExempt mismatch");
        assertTrue(token.isTransferBurnExempt(LP_ACCUMULATOR_WALLET), "Checklist: LP Accumulator burnExempt mismatch");
        assertTrue(token.isTransferBurnExempt(FOUNDER_POOL_WALLET), "Checklist: Founder Pool burnExempt mismatch");
        assertTrue(token.isTransferBurnExempt(TREASURY_SAFE), "Checklist: Treasury Safe burnExempt mismatch");
        assertTrue(token.isTransferBurnExempt(OPS_SAFE), "Checklist: Ops Safe burnExempt mismatch");
        assertFalse(token.isTransferBurnExempt(DEPLOYER_EOA), "Checklist: Deployer burnExempt mismatch");
        assertFalse(token.isDexRestrictionExempt(DEPLOYER_EOA), "Checklist: Deployer dexExempt mismatch");
        assertEq(token.balanceOf(DEPLOYER_EOA), 0, "Checklist: Deployer AIEF balance must be exactly 0");
    }

    function testChecklist_StakingRewardsPoolVerification() public {
        assertEq(rewardsPool.poolBalance(), 400_000_000e18, "Checklist: rewardsPool balance mismatch");
        assertEq(rewardsPool.signer(), BACKEND_SIGNER, "Checklist: rewardsPool signer mismatch");
        assertFalse(rewardsPool.claimsPaused(), "Checklist: rewardsPool claimsPaused mismatch");
    }

    function testChecklist_StakingContractVerification() public {
        assertTrue(staking.routerCallers(address(dappRouter)), "Checklist: DappStakeRouter routerCaller mismatch");
        assertTrue(staking.authorizedPlanCallers(5, address(founderAlloc)), "Checklist: FounderAllocationContract plan5 auth mismatch");
        
        // Plans 0 to 5 configurations
        {
            (bool exists, bool active, bool directAllowed, bool routerAllowed, uint32 lockPeriod) = staking.plans(0);
            assertTrue(exists, "Plan 0 exists");
            assertTrue(active, "Plan 0 should be active");
            assertTrue(directAllowed, "Plan 0 direct stake allowed");
            assertEq(lockPeriod, 0, "Plan 0 lock period mismatch");
        }
        {
            (bool exists, bool active, bool directAllowed, bool routerAllowed, uint32 lockPeriod) = staking.plans(1);
            assertTrue(exists, "Plan 1 exists");
            assertTrue(active, "Plan 1 should be active");
            assertTrue(directAllowed, "Plan 1 direct stake allowed");
            assertEq(lockPeriod, 60 days, "Plan 1 lock period mismatch");
        }
        {
            (bool exists, bool active, bool directAllowed, bool routerAllowed, uint32 lockPeriod) = staking.plans(2);
            assertTrue(exists, "Plan 2 exists");
            assertTrue(active, "Plan 2 should be active");
            assertTrue(directAllowed, "Plan 2 direct stake allowed");
            assertEq(lockPeriod, 120 days, "Plan 2 lock period mismatch");
        }
        {
            (bool exists, bool active, bool directAllowed, bool routerAllowed, uint32 lockPeriod) = staking.plans(3);
            assertTrue(exists, "Plan 3 exists");
            assertTrue(active, "Plan 3 should be active");
            assertTrue(directAllowed, "Plan 3 direct stake allowed");
            assertEq(lockPeriod, 200 days, "Plan 3 lock period mismatch");
        }
        {
            (bool exists, bool active, bool directAllowed, bool routerAllowed, uint32 lockPeriod) = staking.plans(4);
            assertTrue(exists, "Plan 4 exists");
            assertTrue(active, "Plan 4 should be active");
            assertTrue(directAllowed, "Plan 4 direct stake allowed");
            assertEq(lockPeriod, 360 days, "Plan 4 lock period mismatch");
        }
        {
            (bool exists, bool active, bool directAllowed, bool routerAllowed, uint32 lockPeriod) = staking.plans(5);
            assertTrue(exists, "Plan 5 exists");
            assertTrue(active, "Plan 5 should be active");
            assertFalse(directAllowed, "Plan 5 direct stake should be disabled");
            assertFalse(routerAllowed, "Plan 5 router stake should be disabled");
            assertEq(lockPeriod, 360 days, "Plan 5 lock period mismatch");
        }
        assertFalse(staking.newStakesPaused(), "Checklist: newStakesPaused mismatch");
    }

    function testChecklist_FounderAllocationVerification() public {
        assertEq(founderAlloc.poolBalance(), 25_000_000e18, "Checklist: founderAlloc balance mismatch");
        assertEq(founderAlloc.maxFounders(), 500, "Checklist: maxFounders mismatch");
        assertEq(founderAlloc.founderPlanId(), 5, "Checklist: founderPlanId mismatch");
        assertEq(founderAlloc.founderCount(), 0, "Checklist: founderCount mismatch");
        assertEq(founderAlloc.remainderWallet(), TREASURY_SAFE, "Checklist: remainderWallet mismatch");
        assertTrue(founderAlloc.campaignEndTime() > block.timestamp, "Checklist: campaignEndTime should be in future");
    }

    function testChecklist_TokenDistributionVerification() public {
        assertEq(token.balanceOf(address(rewardsPool)), 400_000_000e18, "Checklist: rewardsPool allocation mismatch");
        assertEq(token.balanceOf(address(founderAlloc)), 25_000_000e18, "Checklist: founderAlloc allocation mismatch");
        
        uint256 sumOfAllBalances = token.balanceOf(address(rewardsPool)) +
            token.balanceOf(address(founderAlloc)) +
            token.balanceOf(TREASURY_SAFE) +
            token.balanceOf(pair) +
            token.balanceOf(DEAD) +
            token.balanceOf(PANCAKESWAP_V2_ROUTER);
        assertEq(sumOfAllBalances, 500_000_000e18, "Checklist: Sum of all allocations should be 500M");
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // PART 7 - PROTOCOL CONSTANTS REFERENCE METICULOUS ASSERTIONS
    // ════════════════════════════════════════════════════════════════════════════════

    function testChecklist_ProtocolConstants() public {
        // AIEFToken constants
        assertEq(token.TOTAL_SUPPLY(), 500_000_000e18, "Constant: TOTAL_SUPPLY mismatch");
        assertEq(token.BURN_FLOOR(), 200_000_000e18, "Constant: BURN_FLOOR mismatch");
        assertEq(token.RESTRICTION_PERIOD(), 180 days, "Constant: RESTRICTION_PERIOD mismatch");
        assertEq(token.SELL_TAX_BPS(), 400, "Constant: SELL_TAX mismatch"); // 4% = 400 BPS
        assertEq(token.SELL_BURN_BPS(), 2500, "Constant: SELL_BURN split mismatch"); // 25% of tax
        assertEq(token.SELL_REWARDS_BPS(), 2500, "Constant: SELL_REWARDS split mismatch");
        assertEq(token.SELL_LP_BPS(), 2500, "Constant: SELL_LP split mismatch");
        assertEq(token.SELL_FOUNDER_BPS(), 2500, "Constant: SELL_FOUNDER split mismatch");
        assertEq(token.TRANSFER_BURN_BPS(), 50, "Constant: TRANSFER_BURN mismatch"); // 0.5% = 50 BPS

        // StakingRewardsPool constants
        assertEq(rewardsPool.LOW_WATER_MARK(), 10_000_000e18, "Constant: LOW_WATER_MARK mismatch");
        assertEq(rewardsPool.MAX_SIGNATURE_VALIDITY(), 1 hours, "Constant: MAX_SIGNATURE_VALIDITY mismatch");
        assertEq(rewardsPool.MAX_CLAIM_AMOUNT(), 50_000e18, "Constant: MAX_CLAIM_AMOUNT mismatch");
        assertEq(rewardsPool.CLAIM_COOLDOWN(), 12 hours, "Constant: CLAIM_COOLDOWN mismatch");

        // StakingContract constants
        assertEq(staking.MIN_STAKE(), 1e18, "Constant: MIN_STAKE mismatch");
        assertEq(staking.MAX_POSITIONS(), 350, "Constant: MAX_POSITIONS mismatch");
        assertEq(staking.MAX_LOCK_PERIOD(), 1825 days, "Constant: MAX_LOCK_PERIOD mismatch");
        
        // Exit deduction tiers (BPS)
        assertEq(staking.T1(), 2000, "Constant: Tier 1 split mismatch"); // 20%
        assertEq(staking.T2(), 1000, "Constant: Tier 2 split mismatch"); // 10%
        assertEq(staking.T3(), 500, "Constant: Tier 3 split mismatch");  // 5%
        assertEq(staking.T4(), 0, "Constant: Tier 4 split mismatch");    // 0%

        // EcosystemPaymentContract constants
        assertEq(ecosystemPayment.DEAD_BPS(), 300, "Constant: DEAD_BPS mismatch"); // 3%
        assertEq(ecosystemPayment.POOL_BPS(), 100, "Constant: POOL_BPS mismatch"); // 1%
        assertEq(ecosystemPayment.TREASURY_BPS(), 100, "Constant: TREASURY_BPS mismatch"); // 1%
        assertEq(ecosystemPayment.PARTNER_BPS(), 9500, "Constant: PARTNER_BPS mismatch"); // 95%

        // DappStakeRouter constants
        assertEq(dappRouter.MAX_DEADLINE_WINDOW(), 30 minutes, "Constant: MAX_DEADLINE_WINDOW mismatch");
        assertEq(dappRouter.ABSOLUTE_MAX_USDT(), 100_000 * 10**18, "Constant: ABSOLUTE_MAX_USDT mismatch");
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // PART 4 - POST-DEPLOYMENT SMOKE TESTS
    // ════════════════════════════════════════════════════════════════════════════════

    // Smoke Test 1: Sell tax split
    function testSmoke_SellTaxSplit() public {
        address buyer = address(0xAAAA);
        address seller = address(0xBBBB);

        // Pre-fund the seller with AIEF from mock treasury
        vm.prank(DEPLOYER_EOA);
        MockGnosisSafe(TREASURY_SAFE).executeCall(
            address(token),
            abi.encodeWithSignature("transfer(address,uint256)", seller, 10_000e18)
        );

        // We register the pair as a Dex Pair
        assertEq(token.dexPair(), pair);

        // Standard transfer (non-dex) to buyer
        vm.prank(seller);
        token.transfer(buyer, 1_000e18);

        // Verify the 0.5% transfer burn (5 AIEF burned, 995 AIEF received)
        assertEq(token.balanceOf(buyer), 995e18, "Smoke 1: transfer burn mismatch");

        // Now simulate a sale to the DEX (transfer to pair)
        uint256 poolBalBefore = token.balanceOf(address(rewardsPool));
        uint256 founderBalBefore = token.balanceOf(FOUNDER_POOL_WALLET);
        uint256 lpBalBefore = token.balanceOf(LP_ACCUMULATOR_WALLET);
        uint256 totalSupBefore = token.totalSupply();

        vm.prank(buyer);
        token.transfer(pair, 500e18); // Sell 500 AIEF

        // 4% sell tax on 500 AIEF = 20 AIEF
        // Splits:
        // - 25% (5 AIEF) -> burn (reduces totalSupply)
        // - 25% (5 AIEF) -> founder pool
        // - 25% (5 AIEF) -> rewards pool
        // - 25% (5 AIEF) -> LP accumulator
        assertEq(token.balanceOf(address(rewardsPool)), poolBalBefore + 5e18, "Smoke 1: rewardsPool tax share mismatch");
        assertEq(token.balanceOf(FOUNDER_POOL_WALLET), founderBalBefore + 5e18, "Smoke 1: founderPool tax share mismatch");
        assertEq(token.balanceOf(LP_ACCUMULATOR_WALLET), lpBalBefore + 5e18, "Smoke 1: lpAccumulator tax share mismatch");
        
        // 5 AIEF (sell tax burn share) + 2.4 AIEF (transfer burn on 96% net remainder) = 7.4 AIEF total burned
        assertEq(token.totalSupply(), totalSupBefore - 7.4e18, "Smoke 1: supply-reducing burn mismatch");
    }

    // Smoke Test 2: DappStakeRouter staking
    function testSmoke_DappStakeRouterStaking() public {
        address user = address(0xCCCCCC);
        uint256 usdtAmount = 100e18;

        // Pre-fund the user with USDT
        MockUSDT(BSC_USDT).mint(user, usdtAmount);

        vm.startPrank(user);
        IERC20(BSC_USDT).approve(address(dappRouter), usdtAmount);

        uint256 positionId = dappRouter.stake(
            usdtAmount,
            1, // minAiefOut
            1, // planId 1 (Standard plan: 60-day lock)
            block.timestamp + 10 minutes
        );

        // Verify position details inside StakingContract
        assertEq(positionId, 0, "Smoke 2: first position should be ID 0");
        assertEq(staking.positionCount(user), 1);

        (uint256 principal, uint8 planId, uint64 stakedAt, uint32 lockPeriod, bool active) = staking.getPosition(user, positionId);
        assertTrue(principal > 0, "Smoke 2: principal should be non-zero");
        assertEq(planId, 1);
        assertEq(stakedAt, block.timestamp);
        assertEq(lockPeriod, 60 days);
        assertTrue(active);

        vm.stopPrank();
    }

    // Smoke Test 3: Direct stake
    function testSmoke_DirectStaking() public {
        address user = address(0xDDDDDD);
        uint256 stakeAmount = 5_000e18;

        // Pre-fund user with AIEF
        vm.prank(DEPLOYER_EOA);
        MockGnosisSafe(TREASURY_SAFE).executeCall(
            address(token),
            abi.encodeWithSignature("transfer(address,uint256)", user, stakeAmount)
        );

        vm.startPrank(user);
        token.approve(address(staking), stakeAmount);

        // Stake into Plan 0 (Flexible: 0-day lock)
        staking.stake(stakeAmount, 0);

        assertEq(staking.positionCount(user), 1);

        (uint256 principal, uint8 planId, , uint32 lockPeriod, bool active) = staking.getPosition(user, 0);
        assertEq(principal, stakeAmount, "Smoke 3: principal mismatch");
        assertEq(planId, 0);
        assertEq(lockPeriod, 0);
        assertTrue(active);

        vm.stopPrank();
    }

    // Smoke Test 4: EIP712 claim
    function testSmoke_EIP712Claim() public {
        vm.warp(block.timestamp + 1 days);
        address user = address(0xEEEEEE);
        uint256 claimAmount = 10_000e18;
        uint256 nonce = 0;
        uint256 issuedAt = block.timestamp;
        uint256 expiry = block.timestamp + 30 minutes;

        // Generate EIP712 Signature
        bytes32 structHash = keccak256(
            abi.encode(
                rewardsPool.CLAIM_TYPEHASH(),
                user,
                claimAmount,
                nonce,
                issuedAt,
                expiry
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("AIEFStakingRewards")),
                keccak256(bytes("1")),
                block.chainid,
                address(rewardsPool)
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // User claims reward
        vm.prank(user);
        rewardsPool.claimReward(claimAmount, nonce, issuedAt, expiry, signature);

        // Verify balance updates
        assertEq(token.balanceOf(user), claimAmount, "Smoke 4: reward payment mismatch");
        assertEq(rewardsPool.userNonce(user), 1, "Smoke 4: nonce should be incremented");
        assertEq(rewardsPool.lastClaimAt(user), block.timestamp, "Smoke 4: lastClaimAt should be updated");
    }

    // Smoke Test 5: Ecosystem payment splits
    function testSmoke_EcosystemPaymentSplits() public {
        address payer = address(0xFFFFFF);
        address partnerKey = address(0x111122223333444455556666777788889999aAaa);
        address payoutWallet = address(0x5555555555555555555555555555555555555555);
        uint256 paymentAmount = 10_000e18;

        // Register partner via OPS_SAFE
        vm.prank(DEPLOYER_EOA);
        MockGnosisSafe(OPS_SAFE).executeCall(
            address(ecosystemPayment),
            abi.encodeWithSignature(
                "registerPartner(address,address,string)",
                partnerKey,
                payoutWallet,
                "Checklist Partner"
            )
        );

        // Pre-fund payer with AIEF
        vm.prank(DEPLOYER_EOA);
        MockGnosisSafe(TREASURY_SAFE).executeCall(
            address(token),
            abi.encodeWithSignature("transfer(address,uint256)", payer, paymentAmount)
        );

        // Approve and process ecosystem payment
        vm.startPrank(payer);
        token.approve(address(ecosystemPayment), paymentAmount);

        uint256 poolBalBefore = token.balanceOf(address(rewardsPool));
        uint256 treasuryBalBefore = token.balanceOf(TREASURY_SAFE);
        uint256 deadBalBefore = token.balanceOf(DEAD);

        ecosystemPayment.processPayment(
            payer,
            partnerKey,
            paymentAmount,
            bytes32(0),
            "Checklist Ecosystem Invoice"
        );

        // Verification of splits:
        // - 3% (300 AIEF) -> DEAD
        // - 1% (100 AIEF) -> StakingRewardsPool
        // - 1% (100 AIEF) -> Treasury Safe
        // - 95% (9,500 AIEF) -> payoutWallet
        assertEq(token.balanceOf(DEAD), deadBalBefore + 300e18, "Smoke 5: DEAD split mismatch");
        assertEq(token.balanceOf(address(rewardsPool)), poolBalBefore + 100e18, "Smoke 5: pool split mismatch");
        assertEq(token.balanceOf(TREASURY_SAFE), treasuryBalBefore + 100e18, "Smoke 5: treasury split mismatch");
        assertEq(token.balanceOf(payoutWallet), 9_500e18, "Smoke 5: partner payout mismatch");

        vm.stopPrank();
    }
}
