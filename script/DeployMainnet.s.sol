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

// Simple contract to act as Gnosis Safe mock for code.length > 0 checks
contract MockGnosisSafe {}

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

contract MockPancakeRouter {
    address public immutable factoryAddr;
    constructor(address _factory) {
        factoryAddr = _factory;
    }
    function factory() external view returns (address) {
        return factoryAddr;
    }
    function addLiquidity(
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    ) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }
}

contract DeployMainnetScript is Script {
    // ════════════════════════════════════════════════════════════════════════════════
    // PART 1 - ADDRESSES & PREREQUISITES (BSC MAINNET SPECIFIC)
    // ════════════════════════════════════════════════════════════════════════════════

    // 1.1 Confirmed Wallet Addresses (Mainnet Addresses)
    address public constant DEPLOYER_EOA = 0x4E9cAC333B4Fc2b11a5cbACd7e855a452f84D308;
    address public constant LP_ACCUMULATOR_WALLET = 0xfa5B3Da4A1394ab6a02b876C559F20593f3CB2C3;
    address public constant FOUNDER_POOL_WALLET = 0x87725cB0c384b1Da1Fb3EC3EABD0f1120ae84c66;
    address public constant OPS_SAFE = 0x7D5cbcF8dbEa440674aFbaB88FBe0Fe1d9730631;
    address public constant TREASURY_SAFE = 0x16e50530CA7fcDbE5EAeAB584Cc48AF828920c30;

    // 1.2 Fixed BSC Addresses (Mainnet Constants)
    address public constant PANCAKESWAP_V2_ROUTER = 0x10eD43C718714eb63D5aA57878854764e256024E;
    address public constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Deployed Contracts (States populated during run)
    AIEFToken public token;
    StakingRewardsPool public rewardsPool;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;
    EcosystemPaymentContract public ecosystemPayment;
    DappStakeRouter public dappRouter;
    address public pair;

    /// @dev Fetch private key securely from environmental variables.
    ///      Falls back to a standard local Key with clear warnings if none specified.
    function getPrivateKey() internal view returns (uint256) {
        string memory pkStr = vm.envOr("PRIVATE_KEY", string(""));
        if (bytes(pkStr).length == 0) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Standard local key
        }
        bytes memory pkBytes = bytes(pkStr);
        if (pkBytes.length >= 2 && pkBytes[0] == "0" && pkBytes[1] == "x") {
            return uint256(vm.parseBytes32(pkStr));
        } else {
            return uint256(vm.parseBytes32(string(abi.encodePacked("0x", pkStr))));
        }
    }

    /// @dev Fetch backend signer address dynamically from environmental variables or fail gracefully.
    function getBackendSigner() internal view returns (address) {
        address signer = vm.envOr("BACKEND_SIGNER", address(0));
        if (signer == address(0)) {
            // Default dummy for safety/compilation but will log a visual warning
            return address(0x9999999999999999999999999999999999999999);
        }
        return signer;
    }

    function run() public {
        uint256 deployerPrivateKey = getPrivateKey();
        address derivedDeployer = vm.addr(deployerPrivateKey);

        bool isLocalFork = (derivedDeployer != DEPLOYER_EOA);

        address BACKEND_SIGNER = getBackendSigner();
        if (BACKEND_SIGNER == address(0x9999999999999999999999999999999999999999)) {
            console2.log("WARNING: Using default dummy BACKEND_SIGNER (Open Item O10 is unresolved!).");
            console2.log("To resolve, supply 'BACKEND_SIGNER=0x...' in your environment variables.");
        }

        if (isLocalFork) {
            console2.log("=== FORK MODE: Private key does not match DEPLOYER_EOA ===");
            console2.log("Derived deployer: ", derivedDeployer);
            console2.log("Expected deployer:", DEPLOYER_EOA);
            _runFork(BACKEND_SIGNER);
        } else {
            console2.log("=== MAINNET MODE: Deployer EOA matched ===");
            _runMainnet(deployerPrivateKey, BACKEND_SIGNER);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // FORK MODE — uses vm.startPrank so vm.etch state is visible to all calls
    // ════════════════════════════════════════════════════════════════════════════════
    function _runFork(address BACKEND_SIGNER) internal {
        // 1. Prepare mock bytecodes for addresses that don't exist on the fork
        bytes memory mockCode = hex"6080604052348015600f57600080fd5b50603f80601d6000396000f3fe6080604052600080fdfea2646970667358221220bfde0ad71a812df93f0b2f56b0c2a5c1387d559868dbb9fa54a4ba6d2de9632864736f6c63430008130033";
        if (LP_ACCUMULATOR_WALLET.code.length == 0) vm.etch(LP_ACCUMULATOR_WALLET, mockCode);
        if (FOUNDER_POOL_WALLET.code.length == 0) vm.etch(FOUNDER_POOL_WALLET, mockCode);
        if (OPS_SAFE.code.length == 0) vm.etch(OPS_SAFE, mockCode);
        if (TREASURY_SAFE.code.length == 0) vm.etch(TREASURY_SAFE, mockCode);

        // 2. Mock PancakeSwap Router + Factory if not on fork
        if (PANCAKESWAP_V2_ROUTER.code.length == 0) {
            console2.log("Mocking PancakeSwap Router and Factory...");
            MockGnosisSafe mockPair = new MockGnosisSafe();
            MockPancakeFactory mockFactory = new MockPancakeFactory(address(mockPair));
            MockPancakeRouter mockRouter = new MockPancakeRouter(address(mockFactory));
            // Etch bytecodes onto the constant addresses
            vm.etch(PANCAKESWAP_V2_ROUTER, address(mockRouter).code);
            address fAddr = mockRouter.factory();
            vm.etch(fAddr, address(mockFactory).code);
        }

        // 3. Fund DEPLOYER_EOA with BNB + USDT
        vm.deal(DEPLOYER_EOA, 100 ether);
        address usdtWhale = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
        vm.prank(usdtWhale);
        IERC20(BSC_USDT).transfer(DEPLOYER_EOA, 10_000e18);
        console2.log("Funded DEPLOYER_EOA with USDT from Binance Whale.");

        // 4. Impersonate DEPLOYER_EOA for the entire deployment (NOT broadcast)
        vm.startPrank(DEPLOYER_EOA);

        _deploy(DEPLOYER_EOA, BACKEND_SIGNER);

        vm.stopPrank();

        // 5. Step 12 — OPS_SAFE configuration (only possible in fork mode via prank)
        vm.startPrank(OPS_SAFE);
        staking.setRouterCaller(address(dappRouter), true);
        staking.setAuthorizedPlanCaller(5, address(founderAlloc), true);
        vm.stopPrank();
        console2.log("Step 12: OPS_SAFE configurations applied via prank.");

        _logResults(BACKEND_SIGNER);
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // MAINNET MODE — uses vm.startBroadcast with real private key
    // ════════════════════════════════════════════════════════════════════════════════
    function _runMainnet(uint256 deployerPrivateKey, address BACKEND_SIGNER) internal {
        // Strict prerequisite checks for mainnet
        require(LP_ACCUMULATOR_WALLET.code.length > 0, "Prerequisite: LP_ACCUMULATOR_WALLET must have code");
        require(FOUNDER_POOL_WALLET.code.length > 0, "Prerequisite: FOUNDER_POOL_WALLET must have code");
        require(OPS_SAFE.code.length > 0, "Prerequisite: OPS_SAFE must have code");
        require(TREASURY_SAFE.code.length > 0, "Prerequisite: TREASURY_SAFE must have code");
        require(PANCAKESWAP_V2_ROUTER.code.length > 0, "Prerequisite: PANCAKESWAP_V2_ROUTER must have code");
        require(BSC_USDT.code.length > 0, "Prerequisite: BSC_USDT must have code");

        vm.startBroadcast(deployerPrivateKey);

        _deploy(DEPLOYER_EOA, BACKEND_SIGNER);

        vm.stopBroadcast();

        _logResults(BACKEND_SIGNER);
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // SHARED DEPLOYMENT LOGIC (Steps 1–14)
    // ════════════════════════════════════════════════════════════════════════════════
    function _deploy(address deployerAddress, address BACKEND_SIGNER) internal {
        // Step 1 — Deploy AIEFToken
        token = new AIEFToken(
            FOUNDER_POOL_WALLET,
            LP_ACCUMULATOR_WALLET
        );

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
            pair = IPancakeFactory(factory).createPair(address(token), BSC_USDT);
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
        token.setExempt(address(staking), true, false);   // burnExempt=true, dexExempt=false
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
        require(token.totalSupply() == 500_000_000e18, "Assert: totalSupply is 500M");
        require(token.tradingEnabled() == false, "Assert: tradingEnabled is false");
        require(token.rewardsPool() == address(rewardsPool), "Assert: rewardsPool is correct");
        require(token.dexPair() == pair, "Assert: dexPair is correct");
        require(token.founderPoolWallet() == FOUNDER_POOL_WALLET, "Assert: founderPoolWallet is correct");
        require(token.lpAccumulatorWallet() == LP_ACCUMULATOR_WALLET, "Assert: lpAccumulatorWallet is correct");
        
        // Exemption Assertions
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
        require(token.isTransferBurnExempt(OPS_SAFE) == true, "Assert: Ops Safe transferBurnExempt");
        require(token.isTransferBurnExempt(deployerAddress) == false, "Assert: Deployer not burn exempt");
        require(token.isDexRestrictionExempt(deployerAddress) == false, "Assert: Deployer not dex exempt");
        require(token.balanceOf(deployerAddress) == 0, "Assert: Deployer EOA balance is 0");

        // StakingRewardsPool Assertions
        require(rewardsPool.poolBalance() == 400_000_000e18, "Assert: rewards pool balance is 400M");
        require(rewardsPool.signer() == BACKEND_SIGNER, "Assert: backend signer is correct");
        require(rewardsPool.claimsPaused() == false, "Assert: claims not paused");

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

        // Verify immediately
        require(token.tradingEnabled() == true, "Assert: tradingEnabled after call");
        require(token.owner() == address(0), "Assert: owner is renounced");
        require(token.restrictionEndTime() > block.timestamp, "Assert: dex restriction window active");
    }

    // ════════════════════════════════════════════════════════════════════════════════
    // POST-DEPLOYMENT LOGGING
    // ════════════════════════════════════════════════════════════════════════════════
    function _logResults(address BACKEND_SIGNER) internal view {
        console2.log("=======================================================================");
        console2.log("AIEF PROTOCOL - BSC MAINNET DEPLOYMENT COMPLETED SUCCESSFULLY");
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
        console2.log("VIA YOUR OPS SAFE MULTISIG (address: %s):", OPS_SAFE);
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
        console2.logBytes(abi.encode(address(token), OPS_SAFE, BACKEND_SIGNER));

        console2.log("3. StakingContract:");
        console2.logBytes(abi.encode(address(token), address(rewardsPool), OPS_SAFE, FOUNDER_POOL_WALLET, LP_ACCUMULATOR_WALLET));

        console2.log("4. FounderAllocationContract:");
        console2.logBytes(abi.encode(address(token), address(staking), OPS_SAFE, uint8(5), uint256(500), uint256(50_000e18), block.timestamp + 180 days, TREASURY_SAFE));

        console2.log("5. EcosystemPaymentContract:");
        console2.logBytes(abi.encode(address(token), address(rewardsPool), TREASURY_SAFE, OPS_SAFE));

        console2.log("6. DappStakeRouter:");
        console2.logBytes(abi.encode(address(token), BSC_USDT, PANCAKESWAP_V2_ROUTER, address(staking), OPS_SAFE));
        console2.log("=======================================================================");
    }
}
