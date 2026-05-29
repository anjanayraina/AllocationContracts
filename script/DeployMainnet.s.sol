// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {StakingRewardsPool} from "../src/StakingRewardsPool-2026.sol";
import {StakingContract} from "../src/StakingContract-2026.sol";
import {
    FounderAllocationContract
} from "../src/FounderAllocationContract-2026.sol";
import {
    EcosystemPaymentContract
} from "../src/EcosystemPaymentContract-2026.sol";
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
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);
}

contract DeployMainnetScript is Script {
    // ════════════════════════════════════════════════════════════════════════════════
    // PART 1 - ADDRESSES & PREREQUISITES (BSC MAINNET SPECIFIC)
    // ════════════════════════════════════════════════════════════════════════════════

    // 1.1 Confirmed Wallet Addresses (Mainnet Addresses)
    address public constant DEPLOYER_EOA =
        0x4E9cAC333B4Fc2b11a5cbACd7e855a452f84D308;
    address public constant LP_ACCUMULATOR_WALLET =
        0xfa5B3Da4A1394ab6a02b876C559F20593f3CB2C3;
    address public constant FOUNDER_POOL_WALLET =
        0x87725cB0c384b1Da1Fb3EC3EABD0f1120ae84c66;
    address public constant OPS_SAFE =
        0x7D5cbcF8dbEa440674aFbaB88FBe0Fe1d9730631;
    address public constant TREASURY_SAFE = 0x16e50530cA7fCdBe5eAeab584CC48AF82d920C30;

    // 1.2 Fixed BSC Addresses (Mainnet Constants)
    address public constant PANCAKESWAP_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant BSC_USDT =
        0x55d398326f99059fF775485246999027B3197955;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Deployed Contracts (States populated during run)
    AIEFToken public token;
    StakingRewardsPool public rewardsPool;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;
    EcosystemPaymentContract public ecosystemPayment;
    DappStakeRouter public dappRouter;
    address public pair;

    function run() public {
        address BACKEND_SIGNER = vm.envOr("BACKEND_SIGNER", address(0));
        require(
            BACKEND_SIGNER != address(0),
            "Prerequisite Error: BACKEND_SIGNER environment variable not set in .env!"
        );

        // Strict prerequisite checks for mainnet: verification of correct code presence
        require(
            LP_ACCUMULATOR_WALLET.code.length > 0,
            "Prerequisite: LP_ACCUMULATOR_WALLET must have code"
        );
        require(
            FOUNDER_POOL_WALLET.code.length > 0,
            "Prerequisite: FOUNDER_POOL_WALLET must have code"
        );
        require(
            OPS_SAFE.code.length > 0,
            "Prerequisite: OPS_SAFE must have code"
        );
        require(
            TREASURY_SAFE.code.length > 0,
            "Prerequisite: TREASURY_SAFE must have code"
        );
        require(
            PANCAKESWAP_V2_ROUTER.code.length > 0,
            "Prerequisite: PANCAKESWAP_V2_ROUTER must have code"
        );
        require(
            BSC_USDT.code.length > 0,
            "Prerequisite: BSC_USDT must have code"
        );

        // Start broadcasting from EOA key supplied via command line
        vm.startBroadcast();

        // Safety assertion that active sender is indeed DEPLOYER_EOA
        require(
            msg.sender == DEPLOYER_EOA,
            "Deployer EOA mismatch! Active deployer key is not DEPLOYER_EOA"
        );

        console2.log("=== MAINNET MODE: Deployer EOA matched and verified ===");
        _deploy(DEPLOYER_EOA, BACKEND_SIGNER);

        vm.stopBroadcast();

        // Run post-deployment checks (Step 12 is false since it is run post-deploy manually via OPS_SAFE)
        _postDeploymentChecks(BACKEND_SIGNER, false);
        _logResults(BACKEND_SIGNER);
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // SHARED DEPLOYMENT LOGIC (Steps 1–14)
    // ════════════════════════════════════════════════════════════════════════════════
    function _deploy(address deployerAddress, address BACKEND_SIGNER) internal {
        // Step 1 — Deploy AIEFToken
        token = new AIEFToken(FOUNDER_POOL_WALLET, LP_ACCUMULATOR_WALLET);

        // Step 2 — Deploy StakingRewardsPool
        rewardsPool = new StakingRewardsPool(
            address(token),
            OPS_SAFE,
            BACKEND_SIGNER
        );

        // Step 3 — Deploy StakingContract
        staking = new StakingContract(
            address(token),
            address(rewardsPool),
            OPS_SAFE,
            FOUNDER_POOL_WALLET,
            LP_ACCUMULATOR_WALLET
        );

        // Step 4 — Deploy FounderAllocationContract
        founderAlloc = new FounderAllocationContract(
            address(token),
            address(staking),
            OPS_SAFE,
            5, // founderPlanId
            500, // maxFounders
            50_000e18, // maxAllocationPerFounder (50,000 AIEF)
            block.timestamp + 180 days, // campaignEndTime (6 months post-deploy recommended)
            TREASURY_SAFE // remainderWallet
        );

        // Step 5 — Deploy EcosystemPaymentContract
        ecosystemPayment = new EcosystemPaymentContract(
            address(token),
            address(rewardsPool),
            TREASURY_SAFE,
            OPS_SAFE
        );

        // Step 6 — Deploy DappStakeRouter
        dappRouter = new DappStakeRouter(
            address(token),
            BSC_USDT,
            PANCAKESWAP_V2_ROUTER,
            address(staking),
            OPS_SAFE
        );

        // Step 8 — Set StakingRewardsPool Address in AIEFToken
        token.setStakingRewardsPool(address(rewardsPool));

        // Step 9 — Seed PancakeSwap Liquidity and Create Pair
        uint256 aiefLiquidity = 500_000e18;
        uint256 usdtLiquidity = 10_000e18;

        token.approve(PANCAKESWAP_V2_ROUTER, aiefLiquidity);

        // Fetch or create the DEX pair dynamically on the network
        address factory = IPancakeRouter(PANCAKESWAP_V2_ROUTER).factory();
        pair = IPancakeFactory(factory).getPair(address(token), BSC_USDT);
        if (pair == address(0)) {
            pair = IPancakeFactory(factory).createPair(
                address(token),
                BSC_USDT
            );
        }

        // Approve and Add Liquidity (fails if Deployer EOA has insufficient USDT)
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

        // Step 7 — Distribute Token Allocations
        token.transfer(address(rewardsPool), 400_000_000e18); // 80% — Rewards Pool
        token.transfer(address(founderAlloc), 25_000_000e18); // 5%  — Founders Pool

        // Transfer exactly remaining deployer balance to Treasury Safe to guarantee 0-balance check passes
        uint256 deployerRemaining = token.balanceOf(deployerAddress);
        if (deployerRemaining > 0) {
            token.transfer(TREASURY_SAFE, deployerRemaining);
        }

        // Step 10 — Register DEX Pair in AIEFToken
        token.setDexPair(pair);

        // Step 11 — Set All Exemptions in AIEFToken (Must be set BEFORE enableTrading())
        token.setExempt(address(dappRouter), true, true); // burnExempt=true, dexExempt=true
        token.setExempt(address(staking), true, false); // burnExempt=true, dexExempt=false
        token.setExempt(address(rewardsPool), true, false);
        token.setExempt(address(founderAlloc), true, false);
        token.setExempt(address(ecosystemPayment), true, false);
        token.setExempt(LP_ACCUMULATOR_WALLET, true, false);
        token.setExempt(FOUNDER_POOL_WALLET, true, false);
        token.setExempt(TREASURY_SAFE, true, false);
        token.setExempt(OPS_SAFE, true, false);

        // Remove deployer exemption — must be the last exemption call
        token.removeExempt(deployerAddress);

        // ════════════════════════════════════════════════════════════════════════════════
        // PART 3 - PRE-FLIGHT VERIFICATION CHECKLIST
        // ════════════════════════════════════════════════════════════════════════════════

        // Token Contract Assertions
        require(
            token.totalSupply() == 500_000_000e18,
            "Assert: totalSupply is 500M"
        );
        require(
            token.tradingEnabled() == false,
            "Assert: tradingEnabled is false"
        );
        require(
            token.rewardsPool() == address(rewardsPool),
            "Assert: rewardsPool is correct"
        );
        require(token.dexPair() == pair, "Assert: dexPair is correct");
        require(
            token.founderPoolWallet() == FOUNDER_POOL_WALLET,
            "Assert: founderPoolWallet is correct"
        );
        require(
            token.lpAccumulatorWallet() == LP_ACCUMULATOR_WALLET,
            "Assert: lpAccumulatorWallet is correct"
        );

        // Exemption Assertions
        require(
            token.isTransferBurnExempt(address(dappRouter)) == true,
            "Assert: dappRouter transferBurnExempt"
        );
        require(
            token.isDexRestrictionExempt(address(dappRouter)) == true,
            "Assert: dappRouter dexRestrictionExempt"
        );
        require(
            token.isTransferBurnExempt(address(staking)) == true,
            "Assert: staking transferBurnExempt"
        );
        require(
            token.isDexRestrictionExempt(address(staking)) == false,
            "Assert: staking dexRestrictionExempt"
        );
        require(
            token.isTransferBurnExempt(address(rewardsPool)) == true,
            "Assert: rewardsPool transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(address(founderAlloc)) == true,
            "Assert: founderAlloc transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(address(ecosystemPayment)) == true,
            "Assert: ecosystemPayment transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(LP_ACCUMULATOR_WALLET) == true,
            "Assert: LP accumulator transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(FOUNDER_POOL_WALLET) == true,
            "Assert: Founder Pool transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(TREASURY_SAFE) == true,
            "Assert: Treasury Safe transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(OPS_SAFE) == true,
            "Assert: Ops Safe transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(deployerAddress) == false,
            "Assert: Deployer not burn exempt"
        );
        require(
            token.isDexRestrictionExempt(deployerAddress) == false,
            "Assert: Deployer not dex exempt"
        );
        require(
            token.balanceOf(deployerAddress) == 0,
            "Assert: Deployer EOA balance is 0"
        );

        // StakingRewardsPool Assertions
        require(
            rewardsPool.poolBalance() == 400_000_000e18,
            "Assert: rewards pool balance is 400M"
        );
        require(
            rewardsPool.signer() == BACKEND_SIGNER,
            "Assert: backend signer is correct"
        );
        require(
            rewardsPool.claimsPaused() == false,
            "Assert: claims not paused"
        );

        // StakingContract General Assertions
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
        require(
            staking.newStakesPaused() == false,
            "Assert: staking stakes not paused"
        );

        // FounderAllocationContract Assertions
        require(
            founderAlloc.poolBalance() == 25_000_000e18,
            "Assert: founder allocation pool balance is 25M"
        );
        require(
            founderAlloc.maxFounders() == 500,
            "Assert: maxFounders is 500"
        );
        require(founderAlloc.founderPlanId() == 5, "Assert: planId is 5");
        require(
            founderAlloc.founderCount() == 0,
            "Assert: founderCount starts at 0"
        );
        require(
            founderAlloc.remainderWallet() == TREASURY_SAFE,
            "Assert: remainderWallet is correct"
        );
        require(
            founderAlloc.campaignEndTime() > block.timestamp,
            "Assert: campaignEndTime is in future"
        );

        // Token Distribution Assertions
        require(
            token.balanceOf(address(rewardsPool)) == 400_000_000e18,
            "Assert: token balance rewards pool"
        );
        require(
            token.balanceOf(address(founderAlloc)) == 25_000_000e18,
            "Assert: token balance founder alloc"
        );

        // Sum of all key token holdings: 400M (Rewards) + 25M (Founders) + 75M (Treasury Safe / LP liquidity) == 500M
        require(
            token.balanceOf(address(rewardsPool)) +
                token.balanceOf(address(founderAlloc)) +
                token.balanceOf(TREASURY_SAFE) +
                token.balanceOf(pair) ==
                500_000_000e18,
            "Assert: Sum of all holdings is 500M"
        );

        // ════════════════════════════════════════════════════════════════════════════════
        // STEP 14 - POINT OF NO RETURN: enableTrading + renounceOwnership
        // ════════════════════════════════════════════════════════════════════════════════
        token.enableTrading();
        token.renounceOwnership();

        // Verify immediately
        require(
            token.tradingEnabled() == true,
            "Assert: tradingEnabled after call"
        );
        require(token.owner() == address(0), "Assert: owner is renounced");
        require(
            token.restrictionEndTime() > block.timestamp,
            "Assert: dex restriction window active"
        );
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // POST-DEPLOYMENT VERIFICATION (runs after enableTrading + renounceOwnership)
    // Validates the final IRREVERSIBLE on-chain state. All checks here confirm the
    // deployment is correct and cannot be undone.
    // ════════════════════════════════════════════════════════════════════════════════
    function _postDeploymentChecks(
        address BACKEND_SIGNER,
        bool checkStep12
    ) internal view {
        console2.log(
            "======================================================================="
        );
        console2.log("POST-DEPLOYMENT VERIFICATION CHECKS");
        console2.log(
            "======================================================================="
        );

        // ── 1. Contract Bytecode Verification ────────────────────────────────
        // Every deployed address must contain bytecode on-chain.
        require(
            address(token).code.length > 0,
            "PostCheck: AIEFToken has no code"
        );
        require(
            address(rewardsPool).code.length > 0,
            "PostCheck: StakingRewardsPool has no code"
        );
        require(
            address(staking).code.length > 0,
            "PostCheck: StakingContract has no code"
        );
        require(
            address(founderAlloc).code.length > 0,
            "PostCheck: FounderAllocationContract has no code"
        );
        require(
            address(ecosystemPayment).code.length > 0,
            "PostCheck: EcosystemPaymentContract has no code"
        );
        require(
            address(dappRouter).code.length > 0,
            "PostCheck: DappStakeRouter has no code"
        );
        require(pair.code.length > 0, "PostCheck: DEX Pair has no code");
        console2.log("  [PASS] All 7 contract addresses contain bytecode");

        // ── 2. Ownership & Trading (irreversible) ────────────────────────────
        require(
            token.owner() == address(0),
            "PostCheck: ownership not renounced"
        );
        require(
            token.tradingEnabled() == true,
            "PostCheck: trading not enabled"
        );
        require(
            token.restrictionEndTime() > block.timestamp,
            "PostCheck: restriction window already expired"
        );
        require(
            token.restrictionEndTime() <= block.timestamp + 180 days + 60,
            "PostCheck: restriction window unreasonably far in future"
        );
        console2.log(
            "  [PASS] Ownership renounced, trading enabled, restriction window active"
        );

        // ── 3. One-Time Setters Are Locked ───────────────────────────────────
        // After deployment, rewardsPool and dexPair are set and can never change.
        require(
            token.rewardsPool() != address(0),
            "PostCheck: rewardsPool not set"
        );
        require(
            token.rewardsPool() == address(rewardsPool),
            "PostCheck: rewardsPool address mismatch"
        );
        require(token.dexPair() != address(0), "PostCheck: dexPair not set");
        require(token.dexPair() == pair, "PostCheck: dexPair address mismatch");
        console2.log("  [PASS] One-time setters locked (rewardsPool, dexPair)");

        // ── 4. Immutable Constructor References ──────────────────────────────
        require(
            token.founderPoolWallet() == FOUNDER_POOL_WALLET,
            "PostCheck: founderPoolWallet mismatch"
        );
        require(
            token.lpAccumulatorWallet() == LP_ACCUMULATOR_WALLET,
            "PostCheck: lpAccumulatorWallet mismatch"
        );
        require(
            token.deploymentWallet() == DEPLOYER_EOA,
            "PostCheck: deploymentWallet mismatch"
        );
        console2.log("  [PASS] Immutable constructor references correct");

        // ── 5. Deployer EOA Is Permanently Clean ─────────────────────────────
        require(
            token.balanceOf(DEPLOYER_EOA) == 0,
            "PostCheck: deployer still holds AIEF"
        );
        require(
            token.isTransferBurnExempt(DEPLOYER_EOA) == false,
            "PostCheck: deployer still burn exempt"
        );
        require(
            token.isDexRestrictionExempt(DEPLOYER_EOA) == false,
            "PostCheck: deployer still dex exempt"
        );
        console2.log("  [PASS] Deployer EOA clean (0 balance, no exemptions)");

        // ── 6. Frozen Exemption State ────────────────────────────────────────
        // After enableTrading(), setExempt/removeExempt revert permanently.
        // DappStakeRouter: sole address with BOTH exemptions
        require(
            token.isTransferBurnExempt(address(dappRouter)),
            "PostCheck: dappRouter not burn exempt"
        );
        require(
            token.isDexRestrictionExempt(address(dappRouter)),
            "PostCheck: dappRouter not dex exempt"
        );
        // Protocol contracts: burn exempt only, NOT dex exempt
        require(
            token.isTransferBurnExempt(address(staking)),
            "PostCheck: staking not burn exempt"
        );
        require(
            !token.isDexRestrictionExempt(address(staking)),
            "PostCheck: staking incorrectly dex exempt"
        );
        require(
            token.isTransferBurnExempt(address(rewardsPool)),
            "PostCheck: rewardsPool not burn exempt"
        );
        require(
            token.isTransferBurnExempt(address(founderAlloc)),
            "PostCheck: founderAlloc not burn exempt"
        );
        require(
            token.isTransferBurnExempt(address(ecosystemPayment)),
            "PostCheck: ecosystemPayment not burn exempt"
        );
        // Multisig wallets: burn exempt only
        require(
            token.isTransferBurnExempt(LP_ACCUMULATOR_WALLET),
            "PostCheck: LP wallet not burn exempt"
        );
        require(
            token.isTransferBurnExempt(FOUNDER_POOL_WALLET),
            "PostCheck: founder wallet not burn exempt"
        );
        require(
            token.isTransferBurnExempt(TREASURY_SAFE),
            "PostCheck: treasury not burn exempt"
        );
        require(
            token.isTransferBurnExempt(OPS_SAFE),
            "PostCheck: ops safe not burn exempt"
        );
        console2.log(
            "  [PASS] All exemptions frozen and correct (10 exempt, deployer removed)"
        );

        // ── 7. Token Supply & Distribution Accounting ────────────────────────
        require(
            token.totalSupply() == 500_000_000e18,
            "PostCheck: totalSupply wrong"
        );
        require(
            token.balanceOf(address(rewardsPool)) == 400_000_000e18,
            "PostCheck: rewardsPool balance wrong"
        );
        require(
            token.balanceOf(address(founderAlloc)) == 25_000_000e18,
            "PostCheck: founderAlloc balance wrong"
        );
        // Full accounting: every token is accounted for
        uint256 accountedTokens = token.balanceOf(address(rewardsPool)) +
            token.balanceOf(address(founderAlloc)) +
            token.balanceOf(TREASURY_SAFE) +
            token.balanceOf(pair);
        require(
            accountedTokens == 500_000_000e18,
            "PostCheck: token accounting mismatch - lost tokens"
        );
        console2.log(
            "  [PASS] Token distribution: 400M rewards + 25M founders + treasury + LP = 500M"
        );

        // ── 8. StakingRewardsPool Operational State ──────────────────────────
        require(
            rewardsPool.poolBalance() == 400_000_000e18,
            "PostCheck: rewardsPool poolBalance mismatch"
        );
        require(
            rewardsPool.signer() == BACKEND_SIGNER,
            "PostCheck: rewardsPool signer wrong"
        );
        require(
            rewardsPool.claimsPaused() == false,
            "PostCheck: rewardsPool claims are paused"
        );
        console2.log(
            "  [PASS] StakingRewardsPool: 400M funded, signer set, claims active"
        );

        // ── 9. StakingContract Operational State ─────────────────────────────
        require(
            staking.newStakesPaused() == false,
            "PostCheck: staking is paused"
        );
        {
            (, bool a0, bool d0, , uint32 lp0) = staking.plans(0);
            require(a0, "PostCheck: Plan 0 inactive");
            require(d0, "PostCheck: Plan 0 not direct");
            require(lp0 == 0, "PostCheck: Plan 0 lock period wrong");
        }
        {
            (, bool a1, bool d1, , uint32 lp1) = staking.plans(1);
            require(a1, "PostCheck: Plan 1 inactive");
            require(d1, "PostCheck: Plan 1 not direct");
            require(lp1 == 60 days, "PostCheck: Plan 1 lock period wrong");
        }
        {
            (, bool a2, bool d2, , uint32 lp2) = staking.plans(2);
            require(a2, "PostCheck: Plan 2 inactive");
            require(d2, "PostCheck: Plan 2 not direct");
            require(lp2 == 120 days, "PostCheck: Plan 2 lock period wrong");
        }
        {
            (, bool a3, bool d3, , uint32 lp3) = staking.plans(3);
            require(a3, "PostCheck: Plan 3 inactive");
            require(d3, "PostCheck: Plan 3 not direct");
            require(lp3 == 200 days, "PostCheck: Plan 3 lock period wrong");
        }
        {
            (, bool a4, bool d4, , uint32 lp4) = staking.plans(4);
            require(a4, "PostCheck: Plan 4 inactive");
            require(d4, "PostCheck: Plan 4 not direct");
            require(lp4 == 360 days, "PostCheck: Plan 4 lock period wrong");
        }
        {
            (, bool a5, bool d5, bool r5, uint32 lp5) = staking.plans(5);
            require(a5, "PostCheck: Plan 5 inactive");
            require(!d5, "PostCheck: Plan 5 direct should be disabled");
            require(!r5, "PostCheck: Plan 5 router should be disabled");
            require(lp5 == 360 days, "PostCheck: Plan 5 lock period wrong");
        }
        console2.log("  [PASS] StakingContract: 6 plans correct, not paused");

        // ── 10. Founder Allocation Contract State ────────────────────────────
        require(
            founderAlloc.poolBalance() == 25_000_000e18,
            "PostCheck: founderAlloc poolBalance wrong"
        );
        require(
            founderAlloc.maxFounders() == 500,
            "PostCheck: maxFounders wrong"
        );
        require(
            founderAlloc.founderPlanId() == 5,
            "PostCheck: founderPlanId wrong"
        );
        require(
            founderAlloc.founderCount() == 0,
            "PostCheck: founderCount not 0"
        );
        require(
            founderAlloc.remainderWallet() == TREASURY_SAFE,
            "PostCheck: remainderWallet wrong"
        );
        require(
            founderAlloc.campaignEndTime() > block.timestamp,
            "PostCheck: campaign already expired"
        );
        console2.log(
            "  [PASS] FounderAllocationContract: 25M funded, 500 slots, campaign active"
        );

        // ── 11. Step 12 Verification (fork mode only) ───────────────────────
        if (checkStep12) {
            require(
                staking.routerCallers(address(dappRouter)) == true,
                "PostCheck: dappRouter not set as routerCaller"
            );
            require(
                staking.authorizedPlanCallers(5, address(founderAlloc)) == true,
                "PostCheck: founderAlloc not authorized for Plan 5"
            );
            console2.log(
                "  [PASS] Step 12: routerCaller and authorizedPlanCaller configured"
            );
        } else {
            console2.log(
                "  [SKIP] Step 12: must be configured via OPS_SAFE multisig post-deploy"
            );
        }

        console2.log(
            "======================================================================="
        );
        console2.log("POST-DEPLOYMENT VERIFICATION: ALL CHECKS PASSED");
        console2.log(
            "======================================================================="
        );
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // POST-DEPLOYMENT LOGGING
    // ════════════════════════════════════════════════════════════════════════════════
    function _logResults(address BACKEND_SIGNER) internal view {
        console2.log(
            "======================================================================="
        );
        console2.log(
            "AIEF PROTOCOL - BSC MAINNET DEPLOYMENT COMPLETED SUCCESSFULLY"
        );
        console2.log(
            "======================================================================="
        );
        console2.log("Deployed Contract Addresses:");
        console2.log("TOKEN:             ", address(token));
        console2.log("REWARDS_POOL:      ", address(rewardsPool));
        console2.log("STAKING:           ", address(staking));
        console2.log("FOUNDER_ALLOCATION:", address(founderAlloc));
        console2.log("ECOSYSTEM_PAYMENT: ", address(ecosystemPayment));
        console2.log("DAPP_STAKE_ROUTER: ", address(dappRouter));
        console2.log("PAIR:              ", pair);
        console2.log(
            "======================================================================="
        );
        console2.log(
            "ATTENTION: YOU MUST NOW EXECUTE THESE STEP 12 CONFIGURATIONS"
        );
        console2.log("VIA YOUR OPS SAFE MULTISIG (address: %s):", OPS_SAFE);
        console2.log(
            "-----------------------------------------------------------------------"
        );
        console2.log("1. Call on StakingContract (%s):", address(staking));
        console2.log(
            "   Method: setRouterCaller(%s, true)",
            address(dappRouter)
        );
        console2.log("2. Call on StakingContract (%s):", address(staking));
        console2.log(
            "   Method: setAuthorizedPlanCaller(5, %s, true)",
            address(founderAlloc)
        );
        console2.log(
            "======================================================================="
        );
        console2.log(
            "ABI-Encoded Constructor Arguments for BSCScan Verification:"
        );
        console2.log(
            "-----------------------------------------------------------------------"
        );

        console2.log("1. AIEFToken:");
        console2.logBytes(
            abi.encode(FOUNDER_POOL_WALLET, LP_ACCUMULATOR_WALLET)
        );

        console2.log("2. StakingRewardsPool:");
        console2.logBytes(abi.encode(address(token), OPS_SAFE, BACKEND_SIGNER));

        console2.log("3. StakingContract:");
        console2.logBytes(
            abi.encode(
                address(token),
                address(rewardsPool),
                OPS_SAFE,
                FOUNDER_POOL_WALLET,
                LP_ACCUMULATOR_WALLET
            )
        );

        console2.log("4. FounderAllocationContract:");
        console2.logBytes(
            abi.encode(
                address(token),
                address(staking),
                OPS_SAFE,
                uint8(5),
                uint256(500),
                uint256(50_000e18),
                block.timestamp + 180 days,
                TREASURY_SAFE
            )
        );

        console2.log("5. EcosystemPaymentContract:");
        console2.logBytes(
            abi.encode(
                address(token),
                address(rewardsPool),
                TREASURY_SAFE,
                OPS_SAFE
            )
        );

        console2.log("6. DappStakeRouter:");
        console2.logBytes(
            abi.encode(
                address(token),
                BSC_USDT,
                PANCAKESWAP_V2_ROUTER,
                address(staking),
                OPS_SAFE
            )
        );
        console2.log(
            "======================================================================="
        );
    }
}
