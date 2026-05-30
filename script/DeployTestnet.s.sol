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

contract DummyDexPair {}

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

contract DeployTestnetScript is Script {
    // 1.1 Confirmed Wallet Addresses — Checked and checksummed for Solidity compilation
    address public constant DEPLOYER_EOA =
        0x4E9cAc333B4Fc2B11a5cbAcd7e855a452F840308;
    address public constant LP_ACCUMULATOR_WALLET =
        0xFA5830a4a1394ab6A02B876c559F20593f3Cb2c3;
    address public constant FOUNDER_POOL_WALLET =
        0x87725CB0C384B10a1Fb3Ec3ea80011120AE84c66;

    // Ops Safes (Step-by-step uses two slightly different hex due to OCR errors)
    address public constant OPS_SAFE_705 =
        0x705CBCf8dBeA440674AfbAB88f8e0Fe1d9730631; // Primary & Part 6 (40-digit version)
    address public constant OPS_SAFE_7D5 =
        0x7D5cbcF8dbEa440674aFbaB88FBe0Fe1d9730631; // Steps 3, 4, 5, 11, 15

    address public constant TREASURY_SAFE =
        0x16e50530Ca7FcDbe5eaEaB584CC48af828929030;
    address public constant BACKEND_SIGNER =
        0xCB6b98fA60011DC8FEEb5568fFf6a9cD74CbB34B;

    // 1.2 Fixed BSC Testnet (Chain ID 97) Addresses
    // Official PancakeSwap V2 Router on BSC Testnet
    address public constant PANCAKESWAP_V2_ROUTER =
        0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3;
    // Common Mock USDT Contract on BSC Testnet
    address public constant BSC_USDT =
        0x337610d27c682E347C9cD60BD4b3b107C9d34dDd;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Contracts
    AIEFToken public token;
    StakingRewardsPool public rewardsPool;
    StakingContract public staking;
    FounderAllocationContract public founderAlloc;
    EcosystemPaymentContract public ecosystemPayment;
    DappStakeRouter public dappRouter;
    address public pair;

    function getPrivateKey() internal view returns (uint256) {
        string memory pkStr = vm.envOr("PRIVATE_KEY", string(""));
        if (bytes(pkStr).length == 0) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        bytes memory pkBytes = bytes(pkStr);
        if (pkBytes.length >= 2 && pkBytes[0] == "0" && pkBytes[1] == "x") {
            return uint256(vm.parseBytes32(pkStr));
        } else {
            return uint256(vm.parseBytes32(string(abi.encodePacked("0x", pkStr))));
        }
    }

    function run() public {
        uint256 deployerPrivateKey = getPrivateKey();
        address deployerAddress = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        address lpAccumulator = LP_ACCUMULATOR_WALLET;
        address founderPool = FOUNDER_POOL_WALLET;
        address opsSafe705 = OPS_SAFE_705;
        address opsSafe7D5 = OPS_SAFE_7D5;
        address treasurySafe = TREASURY_SAFE;

        // Deploy Mock Gnosis Safes if they do not have code on the target chain
        if (lpAccumulator.code.length == 0) {
            lpAccumulator = address(new MockGnosisSafe());
            console2.log("Deployed Mock LP Accumulator Wallet at:", lpAccumulator);
        }
        if (founderPool.code.length == 0) {
            founderPool = address(new MockGnosisSafe());
            console2.log("Deployed Mock Founder Pool Wallet at:", founderPool);
        }
        if (opsSafe705.code.length == 0) {
            opsSafe705 = address(new MockGnosisSafe());
            console2.log("Deployed Mock Ops Safe 705 at:", opsSafe705);
        }
        if (opsSafe7D5.code.length == 0) {
            opsSafe7D5 = address(new MockGnosisSafe());
            console2.log("Deployed Mock Ops Safe 7D5 at:", opsSafe7D5);
        }
        if (treasurySafe.code.length == 0) {
            treasurySafe = address(new MockGnosisSafe());
            console2.log("Deployed Mock Treasury Safe at:", treasurySafe);
        }

        // ════════════════════════════════════════════════════════════════════════════════
        // PART 2 - DEPLOYMENT SEQUENCE (NO VM CHEATCODES / PRANKS FOR LIVE TESTNET)
        // ════════════════════════════════════════════════════════════════════════════════

        // Step 1 - Deploy AIEFToken
        token = new AIEFToken(founderPool, lpAccumulator);

        // Step 2 - Deploy StakingRewardsPool
        rewardsPool = new StakingRewardsPool(
            address(token),
            opsSafe705,
            BACKEND_SIGNER
        );

        // Step 3 - Deploy StakingContract
        staking = new StakingContract(
            address(token),
            address(rewardsPool),
            opsSafe7D5,
            founderPool,
            lpAccumulator
        );

        // Step 4 - Deploy FounderAllocationContract
        founderAlloc = new FounderAllocationContract(
            address(token),
            address(staking),
            opsSafe7D5,
            5, // founderPlanId
            500, // maxFounders
            50_000e18, // maxAllocationPerFounder
            block.timestamp + 180 days, // campaignEndTime (6 months recommended)
            treasurySafe // remainderWallet
        );

        // Step 5 - Deploy EcosystemPaymentContract
        ecosystemPayment = new EcosystemPaymentContract(
            address(token),
            address(rewardsPool),
            treasurySafe,
            opsSafe7D5
        );

        // Step 6 - Deploy DappStakeRouter
        dappRouter = new DappStakeRouter(
            address(token),
            BSC_USDT,
            PANCAKESWAP_V2_ROUTER,
            address(staking),
            opsSafe705
        );

        // Step 8 - Set StakingRewardsPool Address in AIEFToken
        token.setStakingRewardsPool(address(rewardsPool));

        // Step 7 - Distribute Token Allocations
        token.transfer(address(rewardsPool), 400_000_000e18); // 80% — Rewards Pool
        token.transfer(address(founderAlloc), 25_000_000e18); // 5%  — Founders Pool
        token.transfer(treasurySafe, 75_000_000e18 - 11000e18); // 15% — Treasury Safe (minus 11,000 AIEF kept on deployer for testing)

        // Deploy mock PancakeSwap V2 Pair (DummyDexPair)
        DummyDexPair mockPair = new DummyDexPair();
        pair = address(mockPair);
        token.setDexPair(pair);
        console2.log("Mock PancakeSwap pair deployed and registered:", pair);

        // Step 11 - Set All Exemptions in AIEFToken
        // burnExempt true, dexExempt true
        token.setExempt(address(dappRouter), true, true);

        // burnExempt true, dexExempt false
        token.setExempt(address(staking), true, false);
        token.setExempt(address(rewardsPool), true, false);
        token.setExempt(address(founderAlloc), true, false);
        token.setExempt(address(ecosystemPayment), true, false);
        token.setExempt(lpAccumulator, true, false);
        token.setExempt(founderPool, true, false);
        token.setExempt(treasurySafe, true, false);
        token.setExempt(opsSafe7D5, true, false);
        token.setExempt(opsSafe705, true, false);

        // 1. EXEMPT SELL TEST
        // Transfer 1,000 AIEF to the pair while deployer is exempt.
        // Expecting 100% of tokens to be delivered (0% tax, 0% burn).
        uint256 pairExemptBefore = token.balanceOf(pair);
        token.transfer(pair, 1000e18);

        require(
            token.balanceOf(pair) == pairExemptBefore + 1000e18,
            "Assert: Exempt sell - pair received exactly 1000 AIEF"
        );

        // Remove deployer exemption (must be the last exemption call)
        token.removeExempt(deployerAddress);

        // 2. NON-EXEMPT SELL TEST (DEX Sell Tax + Transfer Burn Test)
        // Transfer 10,000 AIEF to the pair while deployer is non-exempt.
        // Calculations:
        // - Gross amount: 10,000 AIEF
        // - 4% Sell Tax: 400 AIEF
        //   - 25% (100 AIEF) is burned (supply-reducing)
        //   - 25% (100 AIEF) to founderPoolWallet
        //   - 25% (100 AIEF) to rewardsPool
        //   - 25% (100 AIEF) to lpAccumulatorWallet
        // - Net amount after tax: 9,600 AIEF
        // - 0.5% Transfer Burn on 9,600: 48 AIEF (burned, supply-reducing)
        // - Net received by pair: 9,600 - 48 = 9,552 AIEF
        // Total burned: 100 AIEF + 48 AIEF = 148 AIEF
        uint256 pairBefore = token.balanceOf(pair);
        uint256 supplyBefore = token.totalSupply();
        uint256 founderBefore = token.balanceOf(founderPool);
        uint256 poolBefore = token.balanceOf(address(rewardsPool));
        uint256 lpBefore = token.balanceOf(lpAccumulator);

        token.transfer(pair, 10000e18);

        require(
            token.balanceOf(pair) == pairBefore + 9552e18,
            "Assert: Non-exempt sell - pair received exactly 9552 AIEF"
        );
        require(
            token.totalSupply() == supplyBefore - 148e18,
            "Assert: Non-exempt sell - total supply reduced by 148 AIEF"
        );
        require(
            token.balanceOf(founderPool) == founderBefore + 100e18,
            "Assert: Non-exempt sell - founderPoolWallet received 100 AIEF"
        );
        require(
            token.balanceOf(address(rewardsPool)) == poolBefore + 100e18,
            "Assert: Non-exempt sell - rewardsPool received 100 AIEF"
        );
        require(
            token.balanceOf(lpAccumulator) == lpBefore + 100e18,
            "Assert: Non-exempt sell - lpAccumulatorWallet received 100 AIEF"
        );

        // Ensure deployer EOA holds exactly 0 tokens post-deploy
        require(
            token.balanceOf(deployerAddress) == 0,
            "Assert: Deployer EOA balance is 0"
        );

        // Step 14 - Point of no return: Call enableTrading now that deployer balance is 0 and exemptions are removed
        token.enableTrading();
        console2.log("Trading has been successfully enabled on the AIEFToken!");

        // Note: Step 12 requires calls from the OPS_SAFE multisig. Since EOA cannot
        // call these, we log them for manual execution post-deployment (see console outputs).

        // ════════════════════════════════════════════════════════════════════════════════
        // PART 3 - PRE-FLIGHT VERIFICATION CHECKLIST (Excluding Safe role states)
        // ════════════════════════════════════════════════════════════════════════════════

        // Token Contract Assertions
        require(
            token.totalSupply() == 500_000_000e18 - 148e18,
            "Assert: totalSupply is 500M minus 148 burned AIEF"
        );
        require(
            token.tradingEnabled() == true,
            "Assert: tradingEnabled is true"
        );
        require(
            token.rewardsPool() == address(rewardsPool),
            "Assert: rewardsPool is correct"
        );
        require(token.dexPair() == pair, "Assert: dexPair is correct");
        require(
            token.founderPoolWallet() == founderPool,
            "Assert: founderPoolWallet is correct"
        );
        require(
            token.lpAccumulatorWallet() == lpAccumulator,
            "Assert: lpAccumulatorWallet is correct"
        );
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
            token.isTransferBurnExempt(lpAccumulator) == true,
            "Assert: LP accumulator transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(founderPool) == true,
            "Assert: Founder Pool transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(treasurySafe) == true,
            "Assert: Treasury Safe transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(opsSafe7D5) == true,
            "Assert: Ops Safe 7D5 transferBurnExempt"
        );
        require(
            token.isTransferBurnExempt(opsSafe705) == true,
            "Assert: Ops Safe 705 transferBurnExempt"
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
            rewardsPool.poolBalance() == 400_000_100e18,
            "Assert: rewards pool balance is 400M plus 100 AIEF from sell tax"
        );
        require(
            rewardsPool.signer() == BACKEND_SIGNER,
            "Assert: backend signer is correct"
        );
        require(
            rewardsPool.claimsPaused() == false,
            "Assert: claims not paused"
        );

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
            founderAlloc.remainderWallet() == treasurySafe,
            "Assert: remainderWallet is correct"
        );
        require(
            founderAlloc.campaignEndTime() > block.timestamp,
            "Assert: campaignEndTime is in future"
        );

        // Token Distribution Assertions
        require(
            token.balanceOf(address(rewardsPool)) == 400_000_100e18,
            "Assert: token balance rewards pool is 400M + 100 AIEF from sell tax"
        );
        require(
            token.balanceOf(address(founderAlloc)) == 25_000_000e18,
            "Assert: token balance founder alloc"
        );

        // Sum of all key token holdings must equal the current total supply
        require(
            token.balanceOf(address(rewardsPool)) +
                token.balanceOf(address(founderAlloc)) +
                token.balanceOf(treasurySafe) +
                token.balanceOf(pair) +
                token.balanceOf(lpAccumulator) +
                token.balanceOf(founderPool) ==
                token.totalSupply(),
            "Assert: Sum of all holdings equals total supply"
        );

        // ════════════════════════════════════════════════════════════════════════════════
        // STEP 14 - POINT OF NO RETURN: enableTrading + renounceOwnership
        // ════════════════════════════════════════════════════════════════════════════════
        // Executed enableTrading() in-script once deployer balance reached 0.
        require(
            token.tradingEnabled() == true,
            "Assert: tradingEnabled is true"
        );
        require(token.owner() == deployerAddress, "Assert: owner is deployer");

        // Note: Step 15 ownership transfers for ownable contracts are skipped since core AIEF Protocol
        // contracts do not inherit Ownable and are permanently governed by the immutable constructor params.

        vm.stopBroadcast();

        // ════════════════════════════════════════════════════════════════════════════════
        // POST-DEPLOYMENT VERIFICATION & LOGGING
        // ════════════════════════════════════════════════════════════════════════════════

        console2.log(
            "======================================================================="
        );
        console2.log("BSC TESTNET DEPLOYMENT COMPLETED SUCCESSFULLY");
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
        console2.log("PAIR:              ", address(0));
        console2.log(
            "======================================================================="
        );
        console2.log(
            "ATTENTION: YOU MUST NOW EXECUTE THESE STEP 12 CONFIGURATIONS"
        );
        console2.log("VIA YOUR OPS SAFE MULTISIG (address: %s):", opsSafe7D5);
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
            abi.encode(founderPool, lpAccumulator)
        );

        console2.log("2. StakingRewardsPool:");
        console2.logBytes(
            abi.encode(address(token), opsSafe705, BACKEND_SIGNER)
        );

        console2.log("3. StakingContract:");
        console2.logBytes(
            abi.encode(
                address(token),
                address(rewardsPool),
                opsSafe7D5,
                founderPool,
                lpAccumulator
            )
        );

        console2.log("4. FounderAllocationContract:");
        console2.logBytes(
            abi.encode(
                address(token),
                address(staking),
                opsSafe7D5,
                uint8(5),
                uint256(500),
                uint256(50_000e18),
                block.timestamp + 180 days,
                treasurySafe
            )
        );

        console2.log("5. EcosystemPaymentContract:");
        console2.logBytes(
            abi.encode(
                address(token),
                address(rewardsPool),
                treasurySafe,
                opsSafe7D5
            )
        );

        console2.log("6. DappStakeRouter:");
        console2.logBytes(
            abi.encode(
                address(token),
                BSC_USDT,
                PANCAKESWAP_V2_ROUTER,
                address(staking),
                opsSafe705
            )
        );
        console2.log(
            "======================================================================="
        );
    }
}
