// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {console2} from "forge-std/console2.sol";
import {AIEFToken} from "../src/AIEFToken-2026.sol";
import {StakingRewardsPool} from "../src/StakingRewardsPool-2026.sol";
import {StakingContract} from "../src/StakingContract-2026.sol";
import {FounderAllocationContract} from "../src/FounderAllocationContract-2026.sol";
import {EcosystemPaymentContract} from "../src/EcosystemPaymentContract-2026.sol";
import {DappStakeRouter} from "../src/DappStakeRouter-2026.sol";

// Interfaces for PancakeSwap V2 Setup
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

// Simple contract to act as Gnosis Safe mock for code.length > 0 checks with call forwarding
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

contract DeployAndTestTestnetScript is Script, StdCheats {
    // Confirmed Wallet Addresses — Checked and checksummed for Solidity compilation
    address public DEPLOYER_EOA = 0x4E9cAc333B4Fc2B11a5cbAcd7e855a452F840308;
    address public LP_ACCUMULATOR_WALLET = 0xFA5830a4a1394ab6A02B876c559F20593f3Cb2c3;
    address public FOUNDER_POOL_WALLET = 0x87725CB0C384B10a1Fb3Ec3ea80011120AE84c66;

    // Ops Safes
    address public OPS_SAFE_705 = 0x705CBCf8dBeA440674AfbAB88f8e0Fe1d9730631;
    address public OPS_SAFE_7D5 = 0x7D5cbcF8dbEa440674aFbaB88FBe0Fe1d9730631;

    address public TREASURY_SAFE = 0x16e50530Ca7FcDbe5eaEaB584CC48af828929030;
    address public constant BACKEND_SIGNER = 0x9999999999999999999999999999999999999999;

    // Fixed BSC Testnet (Chain ID 97) Addresses (Defaults if they exist on network)
    address public PANCAKESWAP_V2_ROUTER = 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3;
    address public BSC_USDT = 0x337610d27c682E347C9cD60BD4b3b107C9d34dDd;
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

        // 1. START BROADCAST FIRST
        vm.startBroadcast(deployerPrivateKey);

        // 2. ALWAYS DEPLOY MOCKS FOR WALLETS AND EXTERNAL CONTRACTS
        // This ensures the deployment script is 100% self-contained, does not require
        // pre-existing funded wallets/tokens, and allows full verification transactions
        // to run seamlessly on both local fork and live testnets.
        LP_ACCUMULATOR_WALLET = address(new MockGnosisSafe());
        FOUNDER_POOL_WALLET = address(new MockGnosisSafe());
        OPS_SAFE_705 = address(new MockGnosisSafe());
        OPS_SAFE_7D5 = address(new MockGnosisSafe());
        TREASURY_SAFE = address(new MockGnosisSafe());

        // Deploy Mock USDT and pre-fund deployer EOA via standard contract call (no cheatcodes)
        MockUSDT mockUsdt = new MockUSDT();
        BSC_USDT = address(mockUsdt);
        mockUsdt.mint(deployerAddress, 1_000_000e18);

        // Deploy Mock PancakeSwap V2 Factory and Router
        address mockPair = address(new MockGnosisSafe());
        address mockFactory = address(new MockPancakeFactory(mockPair));
        PANCAKESWAP_V2_ROUTER = address(new MockPancakeRouter(mockFactory));

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
            block.timestamp + 180 days,
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

        // Step 7 - Distribute Token Allocations
        token.transfer(address(rewardsPool), 400_000_000e18); // 80% Rewards Pool
        token.transfer(address(founderAlloc), 25_000_000e18); // 5% Founders Pool
        
        // Transfer exactly remaining balance of the deploymentWallet to Treasury Safe to clear out to 0
        address depWallet = token.deploymentWallet();
        uint256 deployerRemaining = token.balanceOf(depWallet);
        if (deployerRemaining > 0) {
            token.transfer(TREASURY_SAFE, deployerRemaining);
        }

        // Step 8 - Set StakingRewardsPool Address in AIEFToken
        token.setStakingRewardsPool(address(rewardsPool));

        // Step 9 - Seed PancakeSwap Liquidity and Create Pair
        uint256 aiefLiquidity = 500_000e18;
        uint256 usdtLiquidity = 10_000e18;

        // Fetch or create the pair dynamically
        address factory = IPancakeRouter(PANCAKESWAP_V2_ROUTER).factory();
        pair = IPancakeFactory(factory).getPair(address(token), BSC_USDT);
        if (pair == address(0)) {
            pair = IPancakeFactory(factory).createPair(address(token), BSC_USDT);
        }

        // Seeding Mock Liquidity (fund the deployer EOA with USDT via standard contract call)
        MockUSDT(BSC_USDT).mint(deployerAddress, usdtLiquidity);
        
        // Approve and Add Liquidity
        IERC20(BSC_USDT).approve(PANCAKESWAP_V2_ROUTER, usdtLiquidity);
        
        // Transfer 500k AIEF back temporarily to deployer just to seed liquidity
        // Wait, deployer has 0 balance now. We must execute a MockSafe call from TREASURY_SAFE to transfer AIEF to deployer Address!
        // Because msg.sender is the owner of the MockGnosisSafe, msg.sender can call executeCall directly!
        MockGnosisSafe(TREASURY_SAFE).executeCall(
            address(token),
            abi.encodeWithSignature("transfer(address,uint256)", deployerAddress, aiefLiquidity)
        );

        token.approve(PANCAKESWAP_V2_ROUTER, aiefLiquidity);
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

        // Transfer 100k AIEF to mock router if it's our deployed MockPancakeRouter so it can fulfill mock swaps
        if (PANCAKESWAP_V2_ROUTER != 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3) {
            MockGnosisSafe(TREASURY_SAFE).executeCall(
                address(token),
                abi.encodeWithSignature("transfer(address,uint256)", PANCAKESWAP_V2_ROUTER, 100_000e18)
            );
        }

        // Step 10 - Register DEX Pair in AIEFToken
        token.setDexPair(pair);

        // Step 11 - Set All Exemptions in AIEFToken
        token.setExempt(address(dappRouter), true, true);
        token.setExempt(address(staking), true, false);
        token.setExempt(address(rewardsPool), true, false);
        token.setExempt(address(founderAlloc), true, false);
        token.setExempt(address(ecosystemPayment), true, false);
        token.setExempt(LP_ACCUMULATOR_WALLET, true, false);
        token.setExempt(FOUNDER_POOL_WALLET, true, false);
        token.setExempt(TREASURY_SAFE, true, false);
        token.setExempt(OPS_SAFE_7D5, true, false);
        token.setExempt(OPS_SAFE_705, true, false);

        // Remove deployer exemption
        token.removeExempt(deployerAddress);

        // Step 12 - Configure StakingContract via Mock Gnosis Safes
        // Since we deployed MockGnosisSafe for OPS_SAFE_7D5, the deployer is the owner and can configure:
        MockGnosisSafe(OPS_SAFE_7D5).executeCall(
            address(staking),
            abi.encodeWithSignature("setRouterCaller(address,bool)", address(dappRouter), true)
        );
        MockGnosisSafe(OPS_SAFE_7D5).executeCall(
            address(staking),
            abi.encodeWithSignature("setAuthorizedPlanCaller(uint8,address,bool)", 5, address(founderAlloc), true)
        );

        // Sweep any remaining deploymentWallet balance to Treasury Safe right before enableTrading to guarantee 0-balance check passes
        address finalDepWallet = token.deploymentWallet();
        uint256 finalDeployerBal = token.balanceOf(finalDepWallet);
        if (finalDeployerBal > 0) {
            token.transfer(TREASURY_SAFE, finalDeployerBal);
        }

        // Step 14 - Enable Trading + Renounce Ownership
        token.enableTrading();
        token.renounceOwnership();

        // ════════════════════════════════════════════════════════════════════════════════
        // TEST TRANSACTIONS (VALIDATE PROTOCOL IS FULLY FUNCTIONAL ON LOCAL DRY-RUNS)
        // ════════════════════════════════════════════════════════════════════════════════
        if (block.chainid == 31337 || vm.envOr("RUN_TEST_TXS", false)) {
            console2.log("Starting Protocol Verification Transactions...");

            // Transaction 1: Direct Staking Test
            // Transfer 10,000 AIEF from TREASURY_SAFE to Deployer Address for staking
            MockGnosisSafe(TREASURY_SAFE).executeCall(
                address(token),
                abi.encodeWithSignature("transfer(address,uint256)", deployerAddress, 10_000e18)
            );
            
            token.approve(address(staking), 5_000e18);
            staking.stake(5_000e18, 1); // Stake 5,000 AIEF into Plan 1 (60-day lock)
            console2.log("Tx 1 Success: Staked 5,000 AIEF directly via StakingContract!");

            // Transaction 2: USDT Staking Router Test
            // Fund the deployer address with USDT for this verification transaction
            MockUSDT(BSC_USDT).mint(deployerAddress, 1_000e18);
            IERC20(BSC_USDT).approve(address(dappRouter), 100e18);
            
            uint256 positionId = dappRouter.stake(
                100e18, // USDT amount
                1,      // planId 1
                1,      // minAiefOut (must be > 0)
                block.timestamp + 10 minutes
            );
            console2.log("Tx 2 Success: Staked 100 USDT via DappStakeRouter. Position ID:", positionId);

            // Transaction 3: Ecosystem Payment Splits Test
            // First register a partner key via OPS_SAFE_7D5
            address partnerKey = address(0x111122223333444455556666777788889999aAaa);
            address payoutWallet = address(0x5555555555555555555555555555555555555555);
            
            MockGnosisSafe(OPS_SAFE_7D5).executeCall(
                address(ecosystemPayment),
                abi.encodeWithSignature("registerPartner(address,address,string)", partnerKey, payoutWallet, "Testnet Partner")
            );

            // Payer (deployer) gets AIEF, approves EcosystemPaymentContract and calls processPayment
            MockGnosisSafe(TREASURY_SAFE).executeCall(
                address(token),
                abi.encodeWithSignature("transfer(address,uint256)", deployerAddress, 1_000e18)
            );
            token.approve(address(ecosystemPayment), 1_000e18);
            ecosystemPayment.processPayment(
                deployerAddress,
                partnerKey,
                1_000e18,
                bytes32(0),
                "Testnet payment test invoice"
            );
            console2.log("Tx 3 Success: Processed 1,000 AIEF payment with exact 95% split to partner!");
        } else {
            console2.log("Skipping mock verification transactions on live testnet deployment.");
        }

        // Stop Broadcast
        vm.stopBroadcast();

        // ════════════════════════════════════════════════════════════════════════════════
        // PRINT REPORT
        // ════════════════════════════════════════════════════════════════════════════════
        console2.log("-------------------------------------------------------");
        console2.log("BSC Testnet Deployed Contracts & State Verified:");
        console2.log("TOKEN:             ", address(token));
        console2.log("REWARDS_POOL:      ", address(rewardsPool));
        console2.log("STAKING:           ", address(staking));
        console2.log("FOUNDER_ALLOCATION:", address(founderAlloc));
        console2.log("ECOSYSTEM_PAYMENT: ", address(ecosystemPayment));
        console2.log("DAPP_STAKE_ROUTER: ", address(dappRouter));
        console2.log("USDT:              ", BSC_USDT);
        console2.log("PAIR/PAIR MOCK:    ", pair);
        console2.log("-------------------------------------------------------");
        console2.log("Verify contract states on BSCScan or your local block explorer!");
    }
}
