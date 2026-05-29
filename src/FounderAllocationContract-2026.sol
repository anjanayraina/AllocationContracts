// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// ════════════════════════════════════════════════════════════════════════════════
//  AIEF — Artificial Intelligence Entropy GamiFi
//  CONTRACT 4 OF 6 — FounderAllocationContract.sol
//
//  Source authority : SC Developer Specification v1.3 (25 May 2026)
//  BRD authority    : Business Requirements Document v1.3
//
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │  Owned by Ops Safe (3-of-5 Gnosis Safe) after deployment.              │
//  │  NOT renounced — Ops Safe controls founder registration.               │
//  │  Ops Safe CANNOT redirect pool tokens or change the staking route.     │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  Network  : BNB Smart Chain (BSC) — Chain ID 56 / Testnet 97
//  Solidity : 0.8.19 pinned (avoids PUSH0 opcode BSC compatibility risk)
//  OZ       : 4.9.6 — pinned, do not upgrade without audit re-review
//
//  ── WHAT THIS CONTRACT DOES ─────────────────────────────────────────────────
//  • Holds the campaign AIEF allocation for a configurable founder/allocation campaign
//  • Registers Ops-approved founders and stakes their allocation directly into
//    StakingContract under the configured founderPlanId
//  • Tokens never reach founder wallets — staked directly from pool into StakingContract
//  • Exposes public on-chain founder registry (registeredFounders, founderInfo)
//  • Transfers remaining balance to remainderWallet when campaign ends (sold-out
//    OR deadline passed)
//
//  ── CAMPAIGN CONFIGURABILITY ─────────────────────────────────────────────────
//  This contract is designed as a reusable campaign module — not a hardcoded
//  founder tool. Each campaign deployment specifies its own:
//    founderPlanId           → any planId registered in StakingContract
//    maxFounders             → seat cap for this campaign
//    maxAllocationPerFounder → AIEF hard cap per participant
//    campaignEndTime         → deadline for seat-based remainder release
//    remainderWallet         → immutable destination for unused allocation
//
//  Examples:
//    Normal Founder Campaign : maxFounders=500, planId=5, cap=50,000 AIEF
//    Super Founder Campaign  : maxFounders=10,  planId=6, cap=500,000 AIEF
//    Strategic Partner Round : maxFounders=50,  planId=7, custom cap
//
//  ── WHAT THIS CONTRACT DOES NOT DO ─────────────────────────────────────────
//  • NO USDT payment verification — off-chain, Ops Safe verified
//  • NO price calculation or oracle — off-chain, Ops Safe calculated
//  • NO vesting schedule — staked directly, lock enforced by StakingContract
//  • NO refund mechanism — payment verification is entirely off-chain
//  • NO founder removal or allocation editing after registration
//  • NO batch registration
//  • NO arbitrary drain or sweep before sold-out or deadline
//
//  ── FOUNDER PRICING MODEL (off-chain — not in this contract) ────────────────
//  First 30 days  : 50,000 AIEF fixed per founder (at $0.02 reference price)
//  After 30 days  : min($1,000 / approvedPriceSnapshot, maxAllocationPerFounder)
//                   Ops Safe calculates off-chain and passes approvedAmount here.
//  Hard cap       : maxAllocationPerFounder per founder regardless of price.
//
//  ── ALL CAMPAIGN PARTICIPANTS ARE EQUAL ─────────────────────────────────────
//  founderNumber (1-based) is recorded for display purposes only. It carries no
//  economic weight, no governance weight, and no tier significance.
//
//  ── REMAINDER RELEASE CONDITIONS ─────────────────────────────────────────────
//  transferRemainder() is callable by Ops Safe when EITHER:
//    (a) all campaign seats are filled (founderCount == maxFounders), OR
//    (b) campaign deadline has passed (block.timestamp >= campaignEndTime)
//  This ensures unused allocation is always recoverable after the campaign,
//  even if not all seats are filled.
//
//  ── DEPLOYMENT CHECKLIST — EXECUTE IN ORDER ─────────────────────────────────
//  1. Register the campaign staking plan in StakingContract:
//       StakingContract.registerPlan(founderPlanId_, PlanConfig({...}))
//     The plan must exist and be active before this contract can be used.
//
//  2. Deploy FounderAllocationContract with all 8 constructor arguments.
//     Verify FounderContractDeployed event on BSCScan — confirms all params.
//
//  3. Transfer campaign AIEF allocation to this contract:
//       token.transfer(address(FounderAllocationContract), allocationAmount)
//     Verify: poolBalance() == allocationAmount
//
//  4. Authorize this contract in StakingContract:
//       StakingContract.setAuthorizedPlanCaller(founderPlanId_, address(this), true)
//     Without this, every registerFounder() reverts "SC: caller not authorized for plan".
//
//  5. FounderAllocationContract must be transfer-burn exempt in AIEFToken:
//       token.setExempt(address(FounderAllocationContract), true, false)
//     burnExempt=true: exact AIEF routed to StakingContract without 0.5% burn.
//     dexExempt=false: this contract never buys from the DEX.
//
//  6. Ops Safe calls registerFounder() after off-chain payment verification.
// ════════════════════════════════════════════════════════════════════════════════

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Minimal interface — only the one function this contract calls
// ─────────────────────────────────────────────────────────────────────────────

interface IStakingContract {
    /// @notice Stake on behalf of a beneficiary. Caller must be authorized
    ///         via StakingContract.setAuthorizedPlanCaller(founderPlanId, address(this), true).
    function stakeFor(
        address beneficiary,
        uint256 amount,
        uint8   planId
    ) external returns (uint256 positionId);
}

// ─────────────────────────────────────────────────────────────────────────────
//  FounderAllocationContract
// ─────────────────────────────────────────────────────────────────────────────

contract FounderAllocationContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── IMMUTABLE STATE ──────────────────────────────────────────────────────

    /// @notice AIEF token contract. Set in constructor — never changeable.
    IERC20 public immutable token;

    /// @notice StakingContract address. Set in constructor — never changeable.
    ///         This contract must be authorized in StakingContract via
    ///         setAuthorizedPlanCaller(founderPlanId, address(this), true).
    IStakingContract public immutable stakingContract;

    /// @notice Ops Safe multisig. The only address that can call registerFounder().
    address public immutable opsSafe;

    /// @notice The StakingContract planId used for all registrations in this campaign.
    ///         Immutable — set at deployment. No plan-ID hardcoding in bytecode.
    ///         The plan must be registered and active in StakingContract before use.
    uint8 public immutable founderPlanId;

    /// @notice Maximum number of participants in this campaign. Hard cap — enforced on-chain.
    ///         Set at deployment — e.g. 500 for the standard founder campaign.
    uint256 public immutable maxFounders;

    /// @notice Hard cap on AIEF allocation per participant for this campaign.
    ///         Ops Safe cannot approve an amount above this regardless of price.
    ///         Set at deployment — e.g. 50,000e18 for the standard founder campaign.
    uint256 public immutable maxAllocationPerFounder;

    /// @notice Campaign deadline. After this timestamp, Ops Safe can call
    ///         transferRemainder() even if not all seats are filled.
    ///         Ensures unused allocation is always recoverable.
    uint256 public immutable campaignEndTime;

    /// @notice Immutable remainder destination. The only address transferRemainder()
    ///         can send to. Set at deployment — Ops Safe cannot redirect to an
    ///         arbitrary address. Typically the Treasury Safe.
    address public immutable remainderWallet;

    // ── MUTABLE STATE ────────────────────────────────────────────────────────

    /// @notice Number of participants registered so far.
    ///         founderCount at registration time becomes that participant's founderNumber.
    uint256 public founderCount;

    /// @notice Cumulative AIEF allocated to all registered participants so far.
    uint256 public totalAllocated;

    /// @notice Tracks registered wallets for duplicate prevention.
    ///         One wallet = one seat. No exceptions.
    mapping(address => bool) public registeredFounders;

    /// @notice On-chain record for each registered participant.
    ///         Enables direct dApp reads without event indexing.
    ///         founderInfo[wallet].founderNumber == 0 means not registered.
    struct FounderInfo {
        uint256 founderNumber;    // 1-based seat number (display only)
        uint256 allocatedAmount;  // AIEF staked for this participant
        uint256 positionId;       // StakingContract position index
        uint64  registeredAt;     // block.timestamp at registration
    }

    mapping(address => FounderInfo) public founderInfo;

    // ── EVENTS ───────────────────────────────────────────────────────────────

    /// @notice Emitted on every successful registration.
    ///         positionId links this event to the StakingContract position.
    ///         Full founder list is built by indexing this event off-chain.
    ///         Individual proof: founderInfo(wallet) public mapping.
    event FounderRegistered(
        address indexed founderWallet,
        uint256 founderNumber,
        uint256 amount,
        uint256 positionId,
        uint64  registeredAt
    );

    /// @notice Emitted in the constructor. Permanent on-chain audit trail of all
    ///         campaign parameters — visible on BSCScan without decoding calldata.
    event FounderContractDeployed(
        address indexed token,
        address indexed stakingContract,
        address indexed opsSafe,
        uint8           founderPlanId,
        uint256         maxFounders,
        uint256         maxAllocationPerFounder,
        uint256         campaignEndTime,
        address         remainderWallet
    );

    /// @notice Emitted when Ops Safe transfers the post-campaign remainder.
    event RemainderTransferred(address indexed destination, uint256 amount);

    // ── MODIFIER ─────────────────────────────────────────────────────────────

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "FAC: only Ops Safe");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploys the campaign contract. All parameters are immutable after deployment.
    ///         See deployment checklist in file header for required post-deployment steps.
    ///
    /// @param token_                  AIEF token contract
    /// @param stakingContract_        StakingContract address
    /// @param opsSafe_                Ops Safe multisig
    /// @param founderPlanId_          StakingContract planId for this campaign
    /// @param maxFounders_            Maximum seats in this campaign (must be > 0)
    /// @param maxAllocationPerFounder_ AIEF hard cap per participant (must be >= 1e18)
    /// @param campaignEndTime_        Deadline timestamp (must be in the future)
    /// @param remainderWallet_        Immutable destination for post-campaign remainder
    constructor(
        address token_,
        address stakingContract_,
        address opsSafe_,
        uint8   founderPlanId_,
        uint256 maxFounders_,
        uint256 maxAllocationPerFounder_,
        uint256 campaignEndTime_,
        address remainderWallet_
    ) {
        require(token_                    != address(0), "FAC: zero token");
        require(stakingContract_          != address(0), "FAC: zero staking contract");
        require(opsSafe_                  != address(0), "FAC: zero ops safe");
        require(remainderWallet_          != address(0), "FAC: zero remainder wallet");
        require(maxFounders_              >  0,          "FAC: zero max founders");
        require(maxAllocationPerFounder_  >= 1e18,       "FAC: invalid allocation cap");
        require(campaignEndTime_          >  block.timestamp, "FAC: invalid campaign end");

        require(token_.code.length           > 0, "FAC: token not a contract");
        require(stakingContract_.code.length > 0, "FAC: staking not a contract");
        require(opsSafe_.code.length         > 0, "FAC: ops safe not a contract");
        require(remainderWallet_.code.length > 0, "FAC: remainder wallet not a contract");

        token                  = IERC20(token_);
        stakingContract        = IStakingContract(stakingContract_);
        opsSafe                = opsSafe_;
        founderPlanId          = founderPlanId_;
        maxFounders            = maxFounders_;
        maxAllocationPerFounder = maxAllocationPerFounder_;
        campaignEndTime        = campaignEndTime_;
        remainderWallet        = remainderWallet_;

        emit FounderContractDeployed(
            token_, stakingContract_, opsSafe_,
            founderPlanId_, maxFounders_, maxAllocationPerFounder_,
            campaignEndTime_, remainderWallet_
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  CORE FUNCTION
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Register a participant and stake their AIEF allocation directly.
    ///
    ///         ── WHAT THIS FUNCTION DOES ─────────────────────────────────────
    ///         Verifies on-chain eligibility, then creates a staking position in
    ///         StakingContract under founderPlanId for the participant wallet.
    ///         Tokens never reach the participant's personal wallet — staked
    ///         directly from this contract's pool into StakingContract.
    ///
    ///         ── WHAT THIS FUNCTION DOES NOT VERIFY ──────────────────────────
    ///         USDT payment: verified off-chain by Ops Safe before this call.
    ///         AIEF price:   calculated off-chain by Ops Safe.
    ///
    ///         ── ON-CHAIN VERIFICATIONS ──────────────────────────────────────
    ///         (1) founderCount < maxFounders         — seat available
    ///         (2) !registeredFounders[founderWallet] — not a duplicate
    ///         (3) approvedAmount >= 1e18             — above minimum stake
    ///             approvedAmount <= maxAllocationPerFounder — within campaign cap
    ///         (4) pool balance >= approvedAmount     — pool is solvent
    ///
    ///         ── CEI PATTERN ─────────────────────────────────────────────────
    ///         All state changes happen BEFORE the external stakeFor() call.
    ///         If stakeFor() reverts, Solidity's atomic revert unwinds all
    ///         state changes — no state is permanently consumed on failure.
    ///         positionId is written after stakeFor() returns (unavoidable —
    ///         positionId only exists after the call) but is also atomically
    ///         reverted if anything reverts after.
    ///
    /// @param founderWallet   Wallet that will own the staking position
    /// @param approvedAmount  AIEF to allocate — pre-calculated off-chain by Ops Safe
    function registerFounder(
        address founderWallet,
        uint256 approvedAmount
    ) external onlyOpsSafe nonReentrant {
        // ── CHECKS ───────────────────────────────────────────────────────────

        require(founderWallet != address(0),           "FAC: zero wallet");
        require(block.timestamp < campaignEndTime,     "FAC: campaign ended");
        require(founderCount < maxFounders,            "FAC: all seats filled");
        require(!registeredFounders[founderWallet],    "FAC: already registered");
        require(approvedAmount >= 1e18,                "FAC: below min stake");
        require(
            approvedAmount <= maxAllocationPerFounder,
            "FAC: above allocation cap"
        );
        require(
            token.balanceOf(address(this)) >= approvedAmount,
            "FAC: insufficient pool balance"
        );

        // ── EFFECTS (before interactions — CEI pattern) ───────────────────────
        registeredFounders[founderWallet] = true;
        founderCount++;
        uint256 thisFounderNumber = founderCount; // 1-based (captured after increment)
        uint64  registeredAt      = uint64(block.timestamp);
        totalAllocated           += approvedAmount;

        founderInfo[founderWallet].founderNumber   = thisFounderNumber;
        founderInfo[founderWallet].allocatedAmount = approvedAmount;
        founderInfo[founderWallet].registeredAt    = registeredAt;

        // ── INTERACTIONS ─────────────────────────────────────────────────────

        // forceApprove: set allowance to exactly approvedAmount.
        // Reset to 0 immediately after stakeFor() — no residual allowance.
        token.forceApprove(address(stakingContract), approvedAmount);

        uint256 positionId = stakingContract.stakeFor(
            founderWallet,
            approvedAmount,
            founderPlanId        // immutable — set at deployment, not hardcoded
        );

        token.forceApprove(address(stakingContract), 0);

        // positionId stored after stakeFor() returns — unavoidable, atomically
        // reverted alongside all other state if anything fails after this point.
        founderInfo[founderWallet].positionId = positionId;

        emit FounderRegistered(
            founderWallet, thisFounderNumber, approvedAmount, positionId, registeredAt
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  REMAINDER TRANSFER
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Transfer any remaining AIEF balance to remainderWallet.
    ///
    ///         ── WHEN THIS CAN BE CALLED ─────────────────────────────────────
    ///         Callable by Ops Safe when EITHER condition is true:
    ///           (a) all campaign seats are filled (founderCount == maxFounders), OR
    ///           (b) campaign deadline has passed (block.timestamp >= campaignEndTime)
    ///         This ensures unused allocation is always recoverable after the
    ///         campaign ends, even if not all seats were filled.
    ///
    ///         ── DESTINATION ─────────────────────────────────────────────────
    ///         remainderWallet is immutable — set at deployment.
    ///         Ops Safe cannot redirect remainder to an arbitrary address.
    ///
    ///         ── CALLING FREQUENCY ───────────────────────────────────────────
    ///         Expected to be called once after the campaign ends.
    ///         Can be called again if additional AIEF is later sent to this
    ///         contract — destination remains immutable.
    function transferRemainder() external onlyOpsSafe nonReentrant {
        require(
            founderCount == maxFounders || block.timestamp >= campaignEndTime,
            "FAC: remainder not releasable"
        );
        uint256 remainder = token.balanceOf(address(this));
        require(remainder > 0, "FAC: no remainder");

        token.safeTransfer(remainderWallet, remainder);
        emit RemainderTransferred(remainderWallet, remainder);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Current AIEF balance held in the campaign pool.
    function poolBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice Number of campaign seats still available.
    function seatsRemaining() external view returns (uint256) {
        return maxFounders - founderCount;
    }

    /// @notice Returns true if the campaign has ended —
    ///         either all seats filled or deadline passed.
    function campaignEnded() external view returns (bool) {
        return founderCount == maxFounders || block.timestamp >= campaignEndTime;
    }

    /// @notice Returns true if the given wallet is a registered participant.
    function isFounder(address wallet) external view returns (bool) {
        return registeredFounders[wallet];
    }

    /// @notice Full registration record for a participant wallet.
    ///         Returns zero-value struct if wallet is not registered
    ///         (founderNumber == 0 indicates not registered).
    function getFounderInfo(address wallet)
        external
        view
        returns (
            uint256 founderNum,
            uint256 allocatedAmount,
            uint256 positionId,
            uint64  registeredAt
        )
    {
        FounderInfo memory f = founderInfo[wallet];
        return (f.founderNumber, f.allocatedAmount, f.positionId, f.registeredAt);
    }
}
