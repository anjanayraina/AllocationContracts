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

// Simple contract to act as Gnosis Safe mock for code.length > 0 checks
contract MockGnosisSafe {}

// Step 5 - EcosystemPaymentContract (Mock definition since it's not in the codebase)
contract MockEcosystemPaymentContract {
    address public immutable token;
    address public immutable rewardsPool;
    address public immutable treasurySafe;
    address public immutable opsSafe;
    address public owner;

    constructor(
        address token_,
        address rewardsPool_,
        address treasurySafe_,
        address opsSafe_
    ) {
        token = token_;
        rewardsPool = rewardsPool_;
        treasurySafe = treasurySafe_;
        opsSafe = opsSafe_;
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "Ownable: caller is not the owner");
        owner = newOwner;
    }
}

contract DeployLocalForkScript is Script {
    // 1.1 Confirmed Wallet Addresses & Cleansed Hex equivalents
    address public constant DEPLOYER_EOA = 0x4E9CAC333B4Fc2b11a5cbACd7e855a452f840308;
    address public constant LP_ACCUMULATOR_WALLET = 0xfa5830a4A1394ab6a02b876C559F20593f3CB2C3;
    address public constant FOUNDER_POOL_WALLET = 0x87725c88c384b1D1Fb3EC3EABD6f1120ae84c66;
    
    // Ops Safes (Step-by-step uses two slightly different hex due to OCR errors)
    address public constant OPS_SAFE_705 = 0x705cbcF8dbEa446674aFbaB88FBeFe1d9730631; // Primary & Part 6
    address public constant OPS_SAFE_7D5 = 0x7D5cbcF8dbEa440674aFbaB88FBe0Fe1d9730631; // Steps 3, 4, 5, 11, 15

    address public constant TREASURY_SAFE = 0x16e50530cA7fCdBe5eAeab584CC48AF828929030;
    address public constant BACKEND_SIGNER = 0x9999999999999999999999999999999999999999; // Placeholder Open Item 010

    // 1.2 Fixed BSC Addresses (BSC Mainnet Fork Compatibility)
    address public constant PANCAKESWAP_V2_ROUTER = 0x10ED43C718714eb63d5aA57878854764E256024E;
    address public constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Contracts
    AIEFToken public token;
    StakingRewardsPool public rewardsPool;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;
    MockEcosystemPaymentContract public ecosystemPayment;
    DappStakeRouter public dappRouter;
    address public pair;

    function run() public {
        // Setup local fork environment via vm.etch to satisfy .code.length > 0 checks
        // for safes that are required to be contracts in the constructors.
        bytes memory mockCode = address(new MockGnosisSafe()).code;
        
        vm.etch(LP_ACCUMULATOR_WALLET, mockCode);
        vm.etch(FOUNDER_POOL_WALLET, mockCode);
        vm.etch(OPS_SAFE_705, mockCode);
        vm.etch(OPS_SAFE_7D5, mockCode);
        vm.etch(TREASURY_SAFE, mockCode);

        // Ensure we broadcast under deployer EOA address/private key
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        
        vm.startBroadcast(deployerPrivateKey);

        // ════════════════════════════════════════════════════════════════════════════════
        // PART 2 - DEPLOYMENT SEQUENCE
        // ════════════════════════════════════════════════════════════════════════════════

        // Step 1 - Deploy AIEFToken
        token = new AIEFToken(
            FOUNDER_POOL_WALLET,
            LP_ACCUMULATOR_WALLET
        );

        // Step 2 - Deploy StakingRewardsPool
        rewardsPool = new StakingRewardsPool(
            address(token),
            OPS_SAFE_705,
            BACKEND_SIGNER
        );

        // Step 3 - Deploy StakingContract
        staking = new StakingContract(
            address(token),
            address(rewardsPool),
            OPS_SAFE_7D5,
            FOUNDER_POOL_WALLET,
            LP_ACCUMULATOR_WALLET
        );

        // Step 4 - Deploy FounderAllocationContract
        founderAlloc = new FounderAllocationContract(
            address(token),
            address(staking),
            OPS_SAFE_7D5,
            5, // founderPlanId
            500, // maxFounders
            50_000e18, // maxAllocationPerFounder
            block.timestamp + 180 days, // campaignEndTime (6 months recommended)
            TREASURY_SAFE // remainderWallet
        );

        // Step 5 - Deploy EcosystemPaymentContract (Mocked)
        ecosystemPayment = new MockEcosystemPaymentContract(
            address(token),
            address(rewardsPool),
            TREASURY_SAFE,
            OPS_SAFE_7D5
        );

        // Step 6 - Deploy DappStakeRouter
        dappRouter = new DappStakeRouter(
            address(token),
            BSC_USDT,
            PANCAKESWAP_V2_ROUTER,
            address(staking),
            OPS_SAFE_705
        );

        // Step 7 - Distribute Token Allocations
        token.transfer(address(rewardsPool), 400_000_000e18); // 80% Rewards Pool
        token.transfer(address(founderAlloc), 25_000_000e18); // 5% Founders Pool
        
        // Transfer exactly remaining deployer balance to Treasury Safe
        uint256 deployerRemaining = token.balanceOf(msg.sender);
        if (deployerRemaining > 0) {
            token.transfer(TREASURY_SAFE, deployerRemaining);
        }

        // Step 8 - Set StakingRewardsPool Address in AIEFToken
        token.setStakingRewardsPool(address(rewardsPool));

        // Step 9 - Seed PancakeSwap Liquidity and Create Pair
        // Add liquidity via PancakeSwap V2 (500k AIEF + 10,000 USDT to establish launch price)
        uint256 aiefLiquidity = 500_000e18;
        uint256 usdtLiquidity = 10_000e18;

        token.approve(PANCAKESWAP_V2_ROUTER, aiefLiquidity);
        
        // We deal USDT to broadcast EOA so it can add liquidity on the local fork
        // For local fork test/simulation, we fetch / create the pair dynamically
        address factory = IPancakeRouter(PANCAKESWAP_V2_ROUTER).factory();
        pair = IPancakeFactory(factory).getPair(address(token), BSC_USDT);
        if (pair == address(0)) {
            pair = IPancakeFactory(factory).createPair(address(token), BSC_USDT);
        }

        // If local fork has USDT for msg.sender, we approve and add liquidity
        // Otherwise, in standard script runs, this would proceed or simulate
        // Let's do a safe transfer/approval check:
        vm.stopBroadcast();
        deal(BSC_USDT, msg.sender, usdtLiquidity);
        vm.startBroadcast(deployerPrivateKey);

        IERC20(BSC_USDT).approve(PANCAKESWAP_V2_ROUTER, usdtLiquidity);
        IPancakeRouter(PANCAKESWAP_V2_ROUTER).addLiquidity(
            address(token),
            BSC_USDT,
            aiefLiquidity,
            usdtLiquidity,
            0,
            0,
            msg.sender,
            block.timestamp + 10 minutes
        );

        // Step 10 - Register DEX Pair in AIEFToken
        token.setDexPair(pair);

        // Step 11 - Set All Exemptions in AIEFToken
        // burnExempt true, dexExempt true
        token.setExempt(address(dappRouter), true, true);

        // burnExempt true, dexExempt false
        token.setExempt(address(staking), true, false);
        token.setExempt(address(rewardsPool), true, false);
        token.setExempt(address(founderAlloc), true, false);
        token.setExempt(address(ecosystemPayment), true, false);
        token.setExempt(LP_ACCUMULATOR_WALLET, true, false);
        token.setExempt(FOUNDER_POOL_WALLET, true, false);
        token.setExempt(TREASURY_SAFE, true, false);
        token.setExempt(OPS_SAFE_7D5, true, false);
        token.setExempt(OPS_SAFE_705, true, false);

        // Remove deployer exemption (must be the last exemption call)
        token.removeExempt(msg.sender);

        // Step 12 - Configure StakingContract
        vm.stopBroadcast();
        // Since step 12 requires OPS_SAFE caller, we prank OPS_SAFE on fork:
        vm.startPrank(OPS_SAFE_7D5);
        staking.setRouterCaller(address(dappRouter), true);
        staking.setAuthorizedPlanCaller(5, address(founderAlloc), true);
        vm.stopPrank();

        // Resume Deployer EOA broadcasting
        vm.startBroadcast(deployerPrivateKey);

        // ════════════════════════════════════════════════════════════════════════════════
        // PART 3 - PRE-FLIGHT VERIFICATION CHECKLIST (Scripted Assertions)
        // ════════════════════════════════════════════════════════════════════════════════
        
        // Token Contract Assertions
        require(token.totalSupply() == 500_000_000e18, "Assert: totalSupply is 500M");
        require(token.tradingEnabled() == false, "Assert: tradingEnabled is false");
        require(token.rewardsPool() == address(rewardsPool), "Assert: rewardsPool is correct");
        require(token.dexPair() == pair, "Assert: dexPair is correct");
        require(token.founderPoolWallet() == FOUNDER_POOL_WALLET, "Assert: founderPoolWallet is correct");
        require(token.lpAccumulatorWallet() == LP_ACCUMULATOR_WALLET, "Assert: lpAccumulatorWallet is correct");
        require(token.isTransferBurnExempt(address(dappRouter)) == true, "Assert: dappRouter transferBurnExempt");
        require(token.isDexRestrictionExempt(address(dappRouter)) == true, "Assert: dappRouter dexRestrictionExempt");
        require(token.isTransferBurnExempt(address(staking)) == true, "Assert: staking transferBurnExempt");
        require(token.isDexRestrictionExempt(address(staking)) == false, "Assert: staking dexRestrictionExempt");
        require(token.isTransferBurnExempt(address(rewardsPool)) == true, "Assert: rewardsPool transferBurnExempt");
        require(token.isTransferBurnExempt(address(founderAlloc)) == true, "Assert: founderAlloc transferBurnExempt");
        require(token.isTransferBurnExempt(address(ecosystemPayment)) == true, "Assert: ecosystemPayment transferBurnExempt");
        require(token.isTransferBurnExempt(LP_ACCUMULATOR_WALLET) == true, "Assert: LP accumulator transferBurnExempt");
        require(token.isTransferBurnExempt(FOUNDER_POOL_WALLET) == true, "Assert: Founder Pool transferBurnExempt");
        require(token.isTransferBurnExempt(TREASURY_SAFE) == true, "Assert: Treasury Safe transferBurnExempt");
        require(token.isTransferBurnExempt(OPS_SAFE_7D5) == true, "Assert: Ops Safe 7D5 transferBurnExempt");
        require(token.isTransferBurnExempt(OPS_SAFE_705) == true, "Assert: Ops Safe 705 transferBurnExempt");
        require(token.isTransferBurnExempt(msg.sender) == false, "Assert: Deployer not burn exempt");
        require(token.isDexRestrictionExempt(msg.sender) == false, "Assert: Deployer not dex exempt");
        require(token.balanceOf(msg.sender) == 0, "Assert: Deployer EOA balance is 0");

        // StakingRewardsPool Assertions
        require(rewardsPool.poolBalance() == 400_000_000e18, "Assert: rewards pool balance is 400M");
        require(rewardsPool.signer() == BACKEND_SIGNER, "Assert: backend signer is correct");
        require(rewardsPool.claimsPaused() == false, "Assert: claims not paused");

        // StakingContract Assertions
        require(staking.routerCallers(address(dappRouter)) == true, "Assert: dappRouter approved routerCaller");
        require(staking.authorizedPlanCallers(5, address(founderAlloc)) == true, "Assert: founderAlloc authorized for Plan 5");
        
        {
            (, bool active0, , , ) = staking.plans(0);
            require(active0 == true, "Assert: Plan 0 is active");
        }
        {
            (, bool active1, , , ) = staking.plans(1);
            require(active1 == true, "Assert: Plan 1 is active");
        }
        {
            (, bool active2, , , ) = staking.plans(2);
            require(active2 == true, "Assert: Plan 2 is active");
        }
        {
            (, bool active3, , , ) = staking.plans(3);
            require(active3 == true, "Assert: Plan 3 is active");
        }
        {
            (, bool active4, , , ) = staking.plans(4);
            require(active4 == true, "Assert: Plan 4 is active");
        }
        {
            (, bool active5, bool direct5, bool router5, ) = staking.plans(5);
            require(active5 == true, "Assert: Plan 5 is active");
            require(direct5 == false, "Assert: Plan 5 direct stake disabled");
            require(router5 == false, "Assert: Plan 5 router stake disabled");
        }
        require(staking.newStakesPaused() == false, "Assert: staking stakes not paused");

        // FounderAllocationContract Assertions
        require(founderAlloc.poolBalance() == 25_000_000e18, "Assert: founder allocation pool balance is 25M");
        require(founderAlloc.maxFounders() == 500, "Assert: maxFounders is 500");
        require(founderAlloc.founderPlanId() == 5, "Assert: planId is 5");
        require(founderAlloc.founderCount() == 0, "Assert: founderCount starts at 0");
        require(founderAlloc.remainderWallet() == TREASURY_SAFE, "Assert: remainderWallet is correct");
        require(founderAlloc.campaignEndTime() > block.timestamp, "Assert: campaignEndTime is in future");

        // Token Distribution Assertions
        require(token.balanceOf(address(rewardsPool)) == 400_000_000e18, "Assert: token balance rewards pool");
        require(token.balanceOf(address(founderAlloc)) == 25_000_000e18, "Assert: token balance founder alloc");
        
        // Sum of all key token holdings: 400M (Rewards) + 25M (Founders) + 75M (Treasury Safe / LP liquidity) == 500M
        require(
            token.balanceOf(address(rewardsPool)) +
            token.balanceOf(address(founderAlloc)) +
            token.balanceOf(TREASURY_SAFE) +
            token.balanceOf(pair) == 500_000_000e18,
            "Assert: Sum of all holdings is 500M"
        );

        // ════════════════════════════════════════════════════════════════════════════════
        // STEP 14 - POINT OF NO RETURN: enableTrading + renounceOwnership
        // ════════════════════════════════════════════════════════════════════════════════
        token.enableTrading();
        token.renounceOwnership();

        // Post-enable checks inside the same script
        require(token.tradingEnabled() == true, "Assert: tradingEnabled after call");
        require(token.owner() == address(0), "Assert: owner is renounced");
        require(token.restrictionEndTime() > block.timestamp, "Assert: dex restriction window active");

        // Step 15 - Transfer Ownership of Remaining Contracts
        rewardsPool.transferOwnership(OPS_SAFE_705);
        staking.transferOwnership(OPS_SAFE_7D5);
        founderAlloc.transferOwnership(OPS_SAFE_705);
        ecosystemPayment.transferOwnership(OPS_SAFE_7D5);
        dappRouter.transferOwnership(OPS_SAFE_7D5);

        vm.stopBroadcast();

        // ════════════════════════════════════════════════════════════════════════════════
        // PART 4 - POST-DEPLOYMENT VERIFICATION
        // ════════════════════════════════════════════════════════════════════════════════
        
        // Print final deployed addresses for registration in contract register
        console2.log("-----------------------------------------");
        console2.log("AIEF Protocol Deployed Addresses:");
        console2.log("TOKEN:             ", address(token));
        console2.log("REWARDS_POOL:      ", address(rewardsPool));
        console2.log("STAKING:           ", address(staking));
        console2.log("FOUNDER_ALLOCATION:", address(founderAlloc));
        console2.log("ECOSYSTEM_PAYMENT: ", address(ecosystemPayment));
        console2.log("DAPP_STAKE_ROUTER: ", address(dappRouter));
        console2.log("PAIR:              ", pair);
        console2.log("-----------------------------------------");
    }
}
