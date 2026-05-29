// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {StakingRewardsPool} from "../src/StakingRewardsPool-2026.sol";
import {StakingContract} from "../src/StakingContract-2026.sol";
import {FounderAllocationContract} from "../src/FounderAllocationContract-2026.sol";
import {EcosystemPaymentContract} from "../src/EcosystemPaymentContract-2026.sol";
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

contract DeployTestnetScript is Script {
    // 1.1 Confirmed Wallet Addresses — Checked and checksummed for Solidity compilation
    address public constant DEPLOYER_EOA = 0x4E9cAc333B4Fc2B11a5cbAcd7e855a452F840308;
    address public constant LP_ACCUMULATOR_WALLET = 0xFA5830a4a1394ab6A02B876c559F20593f3Cb2c3;
    address public constant FOUNDER_POOL_WALLET = 0x87725CB0C384B10a1Fb3Ec3ea80011120AE84c66;
    
    // Ops Safes (Step-by-step uses two slightly different hex due to OCR errors)
    address public constant OPS_SAFE_705 = 0x705CBCf8dBeA440674AfbAB88f8e0Fe1d9730631; // Primary & Part 6 (40-digit version)
    address public constant OPS_SAFE_7D5 = 0x7D5cbcF8dbEa440674aFbaB88FBe0Fe1d9730631; // Steps 3, 4, 5, 11, 15

    address public constant TREASURY_SAFE = 0x16e50530Ca7FcDbe5eaEaB584CC48af828929030;
    address public constant BACKEND_SIGNER = 0x9999999999999999999999999999999999999999; // Placeholder Open Item 010

    // 1.2 Fixed BSC Testnet (Chain ID 97) Addresses
    // Official PancakeSwap V2 Router on BSC Testnet
    address public constant PANCAKESWAP_V2_ROUTER = 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3;
    // Common Mock USDT Contract on BSC Testnet
    address public constant BSC_USDT = 0x337610d27c682E347C9cD60BD4b3b107C9d34dDd;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Contracts
    AIEFToken public token;
    StakingRewardsPool public rewardsPool;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;
    EcosystemPaymentContract public ecosystemPayment;
    DappStakeRouter public dappRouter;
    address public pair;

    function run() public {
        // Ensure we broadcast using actual private key loaded from environment
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        require(deployerPrivateKey != 0, "DeployTestnet: PRIVATE_KEY env var not set");
        address deployerAddress = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ════════════════════════════════════════════════════════════════════════════════
        // PART 2 - DEPLOYMENT SEQUENCE (NO VM CHEATCODES / PRANKS FOR LIVE TESTNET)
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

        // Step 5 - Deploy EcosystemPaymentContract
        ecosystemPayment = new EcosystemPaymentContract(
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

        // Step 8 - Set StakingRewardsPool Address in AIEFToken
        token.setStakingRewardsPool(address(rewardsPool));

        // Step 9 - Seed PancakeSwap Liquidity and Create Pair
        // Add liquidity via PancakeSwap V2 (500k AIEF + 10,000 USDT to establish launch price)
        // Note: Payer/Deployer EOA must already hold the required USDT on Testnet to execute this step!
        uint256 aiefLiquidity = 500_000e18;
        uint256 usdtLiquidity = 10_000e18;

        token.approve(PANCAKESWAP_V2_ROUTER, aiefLiquidity);
        
        // Fetch or create the DEX pair dynamically on the testnet
        address factory = IPancakeRouter(PANCAKESWAP_V2_ROUTER).factory();
        pair = IPancakeFactory(factory).getPair(address(token), BSC_USDT);
        if (pair == address(0)) {
            pair = IPancakeFactory(factory).createPair(address(token), BSC_USDT);
        }

        // Standard PancakeSwap V2 liquidity seeding (fails if EOA has insufficient USDT)
        IERC20(BSC_USDT).approve(PANCAKESWAP_V2_ROUTER, usdtLiquidity);
        IPancakeRouter(PANCAKESWAP_V2_ROUTER).addLiquidity(
            address(token),
            BSC_USDT,
            aiefLiquidity,
            usdtLiquidity,
            0,
            0,
            deployerAddress,
            block.timestamp + 10 minutes
        );

        // Step 7 - Distribute Token Allocations
        token.transfer(address(rewardsPool), 400_000_000e18); // 80% Rewards Pool
        token.transfer(address(founderAlloc), 25_000_000e18); // 5% Founders Pool
        
        // Transfer exactly remaining deployer balance to Treasury Safe
        // This clears out Deployer's balance to exactly zero as strictly required!
        uint256 deployerRemaining = token.balanceOf(deployerAddress);
        if (deployerRemaining > 0) {
            token.transfer(TREASURY_SAFE, deployerRemaining);
        }

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
        token.removeExempt(deployerAddress);

        // Note: Step 12 requires calls from the OPS_SAFE multisig. Since EOA cannot
        // call these, we log them for manual execution post-deployment (see console outputs).

        // ════════════════════════════════════════════════════════════════════════════════
        // PART 3 - PRE-FLIGHT VERIFICATION CHECKLIST (Excluding Safe role states)
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
        require(token.isTransferBurnExempt(deployerAddress) == false, "Assert: Deployer not burn exempt");
        require(token.isDexRestrictionExempt(deployerAddress) == false, "Assert: Deployer not dex exempt");
        require(token.balanceOf(deployerAddress) == 0, "Assert: Deployer EOA balance is 0");

        // StakingRewardsPool Assertions
        require(rewardsPool.poolBalance() == 400_000_000e18, "Assert: rewards pool balance is 400M");
        require(rewardsPool.signer() == BACKEND_SIGNER, "Assert: backend signer is correct");
        require(rewardsPool.claimsPaused() == false, "Assert: claims not paused");

        // StakingContract General Assertions (Toggles set by Ops Safe checked later)
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

        // Note: Step 15 ownership transfers for ownable contracts are skipped since core AIEF Protocol
        // contracts do not inherit Ownable and are permanently governed by the immutable constructor params.

        vm.stopBroadcast();

        // ════════════════════════════════════════════════════════════════════════════════
        // POST-DEPLOYMENT VERIFICATION & LOGGING
        // ════════════════════════════════════════════════════════════════════════════════
        
        console2.log("=======================================================================");
        console2.log("BSC TESTNET DEPLOYMENT COMPLETED SUCCESSFULLY");
        console2.log("=======================================================================");
        console2.log("Deployed Contract Addresses:");
        console2.log("TOKEN:             ", address(token));
        console2.log("REWARDS_POOL:      ", address(rewardsPool));
        console2.log("STAKING:           ", address(staking));
        console2.log("FOUNDER_ALLOCATION:", address(founderAlloc));
        console2.log("ECOSYSTEM_PAYMENT: ", address(ecosystemPayment));
        console2.log("DAPP_STAKE_ROUTER: ", address(dappRouter));
        console2.log("PAIR:              ", pair);
        console2.log("=======================================================================");
        console2.log("ATTENTION: YOU MUST NOW EXECUTE THESE STEP 12 CONFIGURATIONS");
        console2.log("VIA YOUR OPS SAFE MULTISIG (address: %s):", OPS_SAFE_7D5);
        console2.log("-----------------------------------------------------------------------");
        console2.log("1. Call on StakingContract (%s):", address(staking));
        console2.log("   Method: setRouterCaller(%s, true)", address(dappRouter));
        console2.log("2. Call on StakingContract (%s):", address(staking));
        console2.log("   Method: setAuthorizedPlanCaller(5, %s, true)", address(founderAlloc));
        console2.log("=======================================================================");
        console2.log("ABI-Encoded Constructor Arguments for BSCScan Verification:");
        console2.log("-----------------------------------------------------------------------");
        
        console2.log("1. AIEFToken:");
        console2.logBytes(abi.encode(FOUNDER_POOL_WALLET, LP_ACCUMULATOR_WALLET));
        
        console2.log("2. StakingRewardsPool:");
        console2.logBytes(abi.encode(address(token), OPS_SAFE_705, BACKEND_SIGNER));
        
        console2.log("3. StakingContract:");
        console2.logBytes(abi.encode(address(token), address(rewardsPool), OPS_SAFE_7D5, FOUNDER_POOL_WALLET, LP_ACCUMULATOR_WALLET));
        
        console2.log("4. FounderAllocationContract:");
        console2.logBytes(abi.encode(address(token), address(staking), OPS_SAFE_7D5, uint8(5), uint256(500), uint256(50_000e18), block.timestamp + 180 days, TREASURY_SAFE));
        
        console2.log("5. EcosystemPaymentContract:");
        console2.logBytes(abi.encode(address(token), address(rewardsPool), TREASURY_SAFE, OPS_SAFE_7D5));
        
        console2.log("6. DappStakeRouter:");
        console2.logBytes(abi.encode(address(token), BSC_USDT, PANCAKESWAP_V2_ROUTER, address(staking), OPS_SAFE_705));
        console2.log("=======================================================================");
    }
}
