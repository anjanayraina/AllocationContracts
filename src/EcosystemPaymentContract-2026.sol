// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// ════════════════════════════════════════════════════════════════════════════════
//  AIEF — Artificial Intelligence Entropy GamiFi
//  CONTRACT 5 OF 6 — EcosystemPaymentContract.sol
//
//  Source authority : SC Developer Specification v1.3 (25 May 2026)
//  BRD authority    : Business Requirements Document v1.3
//
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │  Owned by Ops Safe (3-of-5 Gnosis Safe) after deployment.              │
//  │  NOT renounced — Ops Safe manages partner registry.                    │
//  │  Ops Safe CANNOT change fee rates or redirect existing payments.       │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  Network  : BNB Smart Chain (BSC) — Chain ID 56 / Testnet 97
//  Solidity : 0.8.19 pinned (avoids PUSH0 opcode BSC compatibility risk)
//  OZ       : 4.9.6 — pinned, do not upgrade without audit re-review
//
//  ── DEPLOYMENT CHECKLIST — VERIFY BEFORE REGISTERING FIRST PARTNER ──────────
//  □ EcosystemPaymentContract MUST be transfer-burn exempt in AIEFToken:
//      token.setExempt(address(EcosystemPaymentContract), true, false)
//    burnExempt=true: exact AIEF amounts distributed — no 0.5% burn on inbound
//                     or outbound transfers through this contract.
//    dexExempt=false: this contract never buys from the DEX.
//    Without this, processPayment() will revert on the first payment —
//    the inbound safeTransferFrom delivers less than `amount`, causing the
//    distribution transfers to revert from insufficient balance.
//
//  □ Verify all four constructor addresses are correct deployed contracts:
//      token        → AIEFToken contract
//      rewardsPool  → StakingRewardsPool contract
//      treasurySafe → Treasury Safe Gnosis Safe
//      opsSafe      → Ops Safe Gnosis Safe (3-of-5)
//    All four have code.length > 0 checks — EOAs will revert at deployment.
//
//  ── DESIGN SCOPE — V1 CURATED PAYMENT RAIL ──────────────────────────────────
//  This contract represents the curated verified-partner payment rail for launch.
//  Partner registration is Ops Safe-controlled — partners cannot self-register.
//  Ops Safe can deactivate partners at any time. The payment split is fixed.
//  This design is intentional for v1: a controlled, auditable partner set with
//  no governance complexity, no staking requirements, and no open onboarding.
//
//  This does not prevent the protocol from deploying a separate open or
//  community-governed payment contract later. Future payment rails may be
//  deployed independently without changing or replacing this contract.
//
//  ── WHAT THIS CONTRACT DOES ─────────────────────────────────────────────────
//  • Accepts AIEF payments from payers on behalf of registered partners.
//    The payer must call processPayment() directly from their own wallet —
//    no third-party submission is permitted (Option A authorisation model).
//  • Splits every payment atomically into four destinations in a single tx:
//      3%  → DEAD address    (DEAD routing — permanent, non-supply-reducing)
//      1%  → StakingRewardsPool (tops up staker yield)
//      1%  → Treasury Safe   (protocol treasury)
//      95% → Partner wallet  (remainder — absorbs integer division dust)
//  • Maintains a partner registry: register, activate/deactivate, update wallet
//  • Tracks cumulative volume and dead-routing totals for transparency
//  • Holds ZERO AIEF balance during normal operation — processPayment() does
//    not retain any of the payment amount. Under normal usage the contract
//    balance remains zero between transactions. If tokens are sent directly
//    to this contract outside processPayment(), contractBalance() may become
//    non-zero. Such tokens are not recoverable — there is no sweep function.
//
//  ── WHAT THIS CONTRACT DOES NOT DO ─────────────────────────────────────────
//  • NO token custody — zero balance between transactions
//  • NO adjustable fee rates — all splits are immutable constants
//  • NO revenue sharing beyond the fixed split above
//  • NO payment batching — each payment is one atomic transaction
//  • NO refunds or chargebacks
//  • NO USD pricing or oracle
//
//  ── FEE SPLIT ARITHMETIC ────────────────────────────────────────────────────
//  deadAmount    = amount × 300  / 10,000  (3.00% exactly)
//  poolAmount    = amount × 100  / 10,000  (1.00% exactly)
//  treasuryAmt   = amount × 100  / 10,000  (1.00% exactly)
//  partnerAmount = amount - deadAmount - poolAmount - treasuryAmt  (remainder)
//
//  The remainder pattern for partnerAmount guarantees the full input amount
//  is distributed — no dust is ever stranded in the contract. On typical
//  payment sizes the partner receives exactly 95%. On edge-case small amounts
//  where integer division produces dust, the partner receives slightly more
//  (never less) than 95%.
//
//  ── DEAD ROUTING TERMINOLOGY ────────────────────────────────────────────────
//  The 3% DEAD share uses safeTransfer(DEAD, deadAmount).
//  This does NOT reduce totalSupply(). AIEFToken has no external burnFrom().
//  Correct : "routes to DEAD wallet"
//  Incorrect: "burns tokens"
//  The BurnFloorReached state in AIEFToken is unaffected by this transfer.
// ════════════════════════════════════════════════════════════════════════════════

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  EcosystemPaymentContract
// ─────────────────────────────────────────────────────────────────────────────

contract EcosystemPaymentContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── CONSTANTS ────────────────────────────────────────────────────────────

    /// @notice Permanent DEAD address for DEAD-routing transfers.
    ///         Tokens sent here are permanently inaccessible — no private key.
    ///         DEAD routing does NOT reduce totalSupply().
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Basis-points denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Fee split in basis points. All four sum to exactly 10,000.
    ///         PARTNER_BPS is declared for transparency — partnerAmount uses
    ///         remainder arithmetic in practice to absorb integer division dust.
    uint16 public constant DEAD_BPS     =  300; // 3%  → DEAD routing
    uint16 public constant POOL_BPS     =  100; // 1%  → StakingRewardsPool
    uint16 public constant TREASURY_BPS =  100; // 1%  → Treasury Safe
    uint16 public constant PARTNER_BPS  = 9_500; // 95% → partner (remainder)

    /// @notice Maximum byte length for on-chain partner name.
    ///         Prevents arbitrarily large strings bloating BSCScan and event logs.
    uint256 public constant MAX_NAME_LENGTH     = 64;

    /// @notice Maximum byte length for processPayment() metadata field.
    ///         Metadata is stored in the event log only — this caps event size.
    uint256 public constant MAX_METADATA_LENGTH = 256;

    // ── PARTNER STRUCT ───────────────────────────────────────────────────────

    /// @notice On-chain record for a registered ecosystem partner.
    struct Partner {
        address payoutWallet;  // destination for 95% of every payment
        bool    active;        // Ops Safe can pause/resume per partner
        string  name;          // human-readable name — on-chain, BSCScan visible
        uint256 totalVolume;   // cumulative AIEF processed for this partner
        uint64  registeredAt;  // block.timestamp at registration
    }

    // ── IMMUTABLE STATE ──────────────────────────────────────────────────────

    /// @notice AIEF token contract. Immutable — set once in constructor.
    IERC20 public immutable token;

    /// @notice StakingRewardsPool — receives 1% of every payment. Immutable.
    address public immutable rewardsPool;

    /// @notice Treasury Safe — receives 1% of every payment. Immutable.
    address public immutable treasurySafe;

    /// @notice Ops Safe — the only address that can manage the partner registry.
    address public immutable opsSafe;

    // ── MUTABLE STATE ────────────────────────────────────────────────────────

    /// @notice All registered partners, keyed by their identifying address.
    ///         partnerKey is typically the partner's contract or admin address.
    mapping(address => Partner) public partners;

    /// @notice Ordered list of all registered partner keys.
    ///         Used for enumeration — not required for payment processing.
    address[] public partnerList;

    /// @notice Cumulative AIEF volume processed across all partners.
    uint256 public totalVolume;

    /// @notice Cumulative AIEF routed to DEAD address across all payments.
    ///         Purely informational — does not affect totalSupply().
    uint256 public totalDeadRouted;

    // ── EVENTS ───────────────────────────────────────────────────────────────

    /// @notice Emitted on every successful payment.
    ///         All five amounts sum to grossAmount. serviceId and metadata
    ///         are partner-defined and opaque to this contract — stored in
    ///         the event log only for partner and backend indexing.
    event PaymentProcessed(
        address indexed payer,
        address indexed partnerKey,
        uint256 grossAmount,
        uint256 partnerAmount,
        uint256 poolAmount,
        uint256 treasuryAmount,
        uint256 deadAmount,
        bytes32 serviceId,
        string  metadata
    );

    /// @notice Emitted when a new partner is registered.
    event PartnerRegistered(
        address indexed partnerKey,
        address         payoutWallet,
        string          name,
        uint64          registeredAt
    );

    /// @notice Emitted when a partner's active status changes.
    event PartnerUpdated(address indexed partnerKey, bool active);

    /// @notice Emitted when a partner's payout wallet is updated.
    event PartnerWalletUpdated(
        address indexed partnerKey,
        address         oldWallet,
        address         newWallet
    );

    // ── MODIFIER ─────────────────────────────────────────────────────────────

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "EPC: only Ops Safe");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploys the contract. Called at deployment step 6 (Spec Section 1.2).
    ///         No tokens are transferred to this contract — it holds zero balance.
    ///
    ///         ⚠ TRANSFER-BURN EXEMPTION REQUIRED (deployment step 10):
    ///         EcosystemPaymentContract MUST be marked transfer-burn exempt in
    ///         AIEFToken before any payments are processed:
    ///           token.setExempt(address(EcosystemPaymentContract), true, false)
    ///         This exemption is required on both inbound and outbound transfers
    ///         so EPC receives and distributes the exact gross amount.
    ///         Without this exemption, AIEFToken's 0.5% transfer burn applies to
    ///         the inbound safeTransferFrom — EPC receives less than `amount`.
    ///         When it then attempts to distribute exactly `amount` across four
    ///         destinations, the final safeTransfer will revert from insufficient
    ///         balance. The result is processPayment() failing entirely, not just
    ///         paying slightly wrong percentages. All payment functionality
    ///         depends on this exemption being set before the first payment.
    ///
    /// @param token_        AIEF token contract (deployed at step 1)
    /// @param rewardsPool_  StakingRewardsPool address (deployed at step 2)
    /// @param treasurySafe_ Treasury Safe multisig
    /// @param opsSafe_      Ops Safe multisig
    constructor(
        address token_,
        address rewardsPool_,
        address treasurySafe_,
        address opsSafe_
    ) {
        require(token_        != address(0), "EPC: zero token");
        require(rewardsPool_  != address(0), "EPC: zero pool");
        require(treasurySafe_ != address(0), "EPC: zero treasury");
        require(opsSafe_      != address(0), "EPC: zero ops safe");

        require(token_.code.length        > 0, "EPC: token not a contract");
        require(rewardsPool_.code.length  > 0, "EPC: pool not a contract");
        require(treasurySafe_.code.length > 0, "EPC: treasury not a contract");
        require(opsSafe_.code.length      > 0, "EPC: ops safe not a contract");

        token        = IERC20(token_);
        rewardsPool  = rewardsPool_;
        treasurySafe = treasurySafe_;
        opsSafe      = opsSafe_;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  CORE PAYMENT FUNCTION
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Process an AIEF payment for an ecosystem partner service.
    ///
    ///         ── INTEGRATION PATTERN ─────────────────────────────────────────
    ///         1. End user calls token.approve(EcosystemPaymentContract, amount)
    ///            IMPORTANT: approve exactly `amount` — not more, not unlimited.
    ///            This contract enforces an exact allowance check (see below).
    ///         2. End user calls processPayment() directly from their own wallet.
    ///            msg.sender must equal payer — no third-party submission.
    ///         3. This contract verifies allowance == amount, then pulls it
    ///         4. Splits atomically — all four transfers in one transaction
    ///         5. Contract balance returns to zero
    ///
    ///         ── WHO CAN CALL processPayment() ───────────────────────────────
    ///         Only the payer themselves. require(msg.sender == payer).
    ///         This is the simplest, safest, and most auditable authorisation
    ///         model. The payer wallet signs and submits the transaction directly.
    ///         Partner dApps build the UI and construct calldata, but the user's
    ///         wallet broadcasts. No third party can exercise a user's allowance.
    ///         This is the standard model used by Uniswap, OpenSea, and 1inch.
    ///
    ///         ── WHY payer IS EXPLICIT RATHER THAN msg.sender ────────────────
    ///         Under this model both are identical. The explicit `payer` parameter
    ///         is kept for event log clarity — PaymentProcessed records who paid,
    ///         making the event self-contained for backend indexing without needing
    ///         to correlate against msg.sender from the transaction receipt.
    ///
    ///         ── EXACT ALLOWANCE REQUIRED ────────────────────────────────────
    ///         payer must approve exactly `amount` — not more, not unlimited.
    ///         Each payment requires a fresh exact approval — per-transaction consent.
    ///
    ///         ── SPLIT ARITHMETIC ────────────────────────────────────────────
    ///         deadAmount    = amount × 3%   (constant)
    ///         poolAmount    = amount × 1%   (constant)
    ///         treasuryAmt   = amount × 1%   (constant)
    ///         partnerAmount = remainder      (absorbs integer dust — never less than 95%)
    ///
    /// @param payer       Wallet paying for the service — must equal msg.sender
    /// @param partnerKey  Registered partner identifier address
    /// @param amount      Gross AIEF amount — must be > 0
    /// @param serviceId   Partner-defined service identifier (opaque to contract)
    /// @param metadata    Human-readable description — stored in event log only
    function processPayment(
        address        payer,
        address        partnerKey,
        uint256        amount,
        bytes32        serviceId,
        string calldata metadata
    ) external nonReentrant {
        // ── CHECKS ───────────────────────────────────────────────────────────

        require(payer      != address(0),       "EPC: zero payer");
        require(msg.sender == payer,            "EPC: caller must be payer");
        require(partnerKey != address(0),       "EPC: zero partner key");
        require(amount     >  0,                "EPC: zero amount");
        require(partners[partnerKey].active,    "EPC: partner not active");
        require(
            bytes(metadata).length <= MAX_METADATA_LENGTH,
            "EPC: metadata too long"
        );

        Partner storage p = partners[partnerKey];

        // ── PULL PAYMENT ─────────────────────────────────────────────────────
        // Exact allowance: payer must have approved exactly `amount` for this call.
        // Each payment requires a fresh exact approval — per-transaction consent.
        // Residual allowances cannot be reused across multiple payments.
        require(
            token.allowance(payer, address(this)) == amount,
            "EPC: exact allowance required"
        );

        // Pull full amount from payer. After this transfer, the contract holds
        // exactly `amount` AIEF — immediately distributed in the steps below.
        token.safeTransferFrom(payer, address(this), amount);

        // ── CALCULATE SPLITS ─────────────────────────────────────────────────
        uint256 deadAmount    = (amount * DEAD_BPS)     / BPS_DENOMINATOR; // 3%
        uint256 poolAmount    = (amount * POOL_BPS)     / BPS_DENOMINATOR; // 1%
        uint256 treasuryAmt   = (amount * TREASURY_BPS) / BPS_DENOMINATOR; // 1%
        uint256 partnerAmount = amount - deadAmount - poolAmount - treasuryAmt; // ~95% + dust

        // ── DISTRIBUTE ATOMICALLY ─────────────────────────────────────────────
        // All four transfers happen in the same transaction. If any reverts,
        // the entire transaction reverts — no partial distribution possible.
        token.safeTransfer(DEAD,              deadAmount);   // DEAD routing (3%)
        token.safeTransfer(rewardsPool,       poolAmount);   // StakingRewardsPool (1%)
        token.safeTransfer(treasurySafe,      treasuryAmt);  // Treasury Safe (1%)
        token.safeTransfer(p.payoutWallet,    partnerAmount);// Partner (95% + dust)

        // ── UPDATE STATE ─────────────────────────────────────────────────────
        // After all transfers complete — contract balance is now zero.
        p.totalVolume    += amount;
        totalVolume      += amount;
        totalDeadRouted  += deadAmount;

        emit PaymentProcessed(
            payer,
            partnerKey,
            amount,
            partnerAmount,
            poolAmount,
            treasuryAmt,
            deadAmount,
            serviceId,
            metadata
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  PARTNER REGISTRY (Ops Safe only)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Register a new ecosystem partner.
    ///         partnerKey is the partner's identifying address — mapping key.
    ///
    /// @param partnerKey   Unique identifier address for this partner
    /// @param payoutWallet Where the partner's 95% share is sent
    /// @param name         Human-readable partner name — stored on-chain (max 64 bytes)
    function registerPartner(
        address         partnerKey,
        address         payoutWallet,
        string calldata name
    ) external onlyOpsSafe {
        require(partnerKey   != address(0),              "EPC: zero partner key");
        require(payoutWallet != address(0),              "EPC: zero payout wallet");
        require(payoutWallet != DEAD,                    "EPC: dead payout wallet");
        require(bytes(name).length > 0,                  "EPC: empty name");
        require(bytes(name).length <= MAX_NAME_LENGTH,   "EPC: name too long");
        require(!partners[partnerKey].active &&
                partners[partnerKey].registeredAt == 0,  "EPC: already registered");

        uint64 registeredAt = uint64(block.timestamp);
        partners[partnerKey] = Partner({
            payoutWallet: payoutWallet,
            active:       true,
            name:         name,
            totalVolume:  0,
            registeredAt: registeredAt
        });
        partnerList.push(partnerKey);

        emit PartnerRegistered(partnerKey, payoutWallet, name, registeredAt);
    }

    /// @notice Activate or deactivate a registered partner.
    ///         Deactivated partners cannot receive payments — processPayment()
    ///         reverts if partner is inactive. Does not delete the partner record.
    ///
    /// @param partnerKey  Partner to update
    /// @param active      True to activate, false to deactivate
    function setPartnerActive(address partnerKey, bool active) external onlyOpsSafe {
        require(partners[partnerKey].registeredAt > 0,  "EPC: partner not registered");
        require(partners[partnerKey].active != active,  "EPC: same status");
        partners[partnerKey].active = active;
        emit PartnerUpdated(partnerKey, active);
    }

    /// @notice Update the payout wallet for a registered partner.
    ///         Used when a partner rotates their receiving address.
    ///         Partner must be registered (registeredAt > 0).
    ///
    /// @param partnerKey  Partner to update
    /// @param newWallet   New payout wallet address
    function updatePartnerWallet(
        address partnerKey,
        address newWallet
    ) external onlyOpsSafe {
        require(partners[partnerKey].registeredAt > 0, "EPC: partner not registered");
        require(newWallet != address(0),                "EPC: zero wallet");
        require(newWallet != DEAD,                      "EPC: dead payout wallet");
        require(newWallet != partners[partnerKey].payoutWallet, "EPC: same wallet");

        address oldWallet = partners[partnerKey].payoutWallet;
        partners[partnerKey].payoutWallet = newWallet;

        emit PartnerWalletUpdated(partnerKey, oldWallet, newWallet);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total number of registered partners (including inactive).
    function partnerCount() external view returns (uint256) {
        return partnerList.length;
    }

    /// @notice Returns true if a partner is registered and currently active.
    function isActivePartner(address partnerKey) external view returns (bool) {
        return partners[partnerKey].active;
    }

    /// @notice Full partner record for a given key.
    function getPartner(address partnerKey)
        external
        view
        returns (
            address payoutWallet,
            bool    active,
            string memory name,
            uint256 volume,
            uint64  registeredAt
        )
    {
        Partner memory p = partners[partnerKey];
        return (p.payoutWallet, p.active, p.name, p.totalVolume, p.registeredAt);
    }

    /// @notice Current AIEF balance of this contract.
    ///         Should be zero under normal operation. A non-zero balance
    ///         usually means tokens were sent directly to this contract
    ///         outside of processPayment(). Such tokens are not recoverable.
    function contractBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
