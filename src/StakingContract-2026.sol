// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

// ════════════════════════════════════════════════════════════════════════════════
//  AIEF — Artificial Intelligence Entropy GamiFi
//  CONTRACT 3 OF 6 — StakingContract.sol
//
//  Source authority : SC Developer Specification v1.3 (25 May 2026)
//  BRD authority    : Business Requirements Document v1.3
//
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │  Owned by Ops Safe (3-of-5 Gnosis Safe) after deployment.              │
//  │  NOT renounced — Ops Safe manages plan registry and caller auth.       │
//  │  Ops Safe CANNOT modify locked positions, deduction tiers, or drain.  │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  Network  : BNB Smart Chain (BSC) — Chain ID 56 / Testnet 97
//  Solidity : 0.8.19 pinned (avoids PUSH0 opcode BSC compatibility risk)
//  OZ       : 4.9.6 — pinned
//
//  ── WHAT THIS CONTRACT DOES ─────────────────────────────────────────────────
//  • Maintains a plan registry — the single source of truth for plan validity
//  • Accepts AIEF stakes via three caller paths: direct, router, authorized
//  • Custodies all staked user principal with exact receipt verification
//  • Enforces hard lock periods per position (captured at stake time)
//  • Applies tiered exit deductions on matured positions
//  • Returns net principal on unstake
//
//  ── GENERIC ROUTE AUTHORIZATION MODEL ───────────────────────────────────────
//  StakingContract has NO business-domain knowledge (no "founder", no named
//  special contracts). Routing is controlled by two generic mappings:
//
//    routerCallers[caller]                → can call stakeFor() for routerAllowed plans
//    authorizedPlanCallers[planId][caller] → can call stakeFor() for that specific plan
//
//  FounderAllocationContract is simply set as authorizedPlanCallers[5][founderAddr].
//  Any future special-access contract follows the same pattern without changes here.
//
//  ── PLAN REGISTRY MODEL ─────────────────────────────────────────────────────
//  Plans are data, not code. Ops Safe can add or deactivate plans without
//  redeployment. Deactivating a plan stops new stakes — never affects existing.
//
//  ── LOCK PERIOD CAPTURE — CRITICAL ─────────────────────────────────────────
//  lockPeriod is captured from PlanConfig INTO the Position at stake time.
//  unstake() reads pos.lockPeriod — NOT the current registry value.
//  Future plan changes cannot affect any existing position's lock.
//
//  ── DEDUCTION TIERS — IMMUTABLE (Option A) ──────────────────────────────────
//  T1/T2/T3/T4 are immutable constants. Applied universally by elapsed time.
//  New plans get the same tier structure. Cannot be changed by anyone.
//
//  ── PAUSE DESIGN ────────────────────────────────────────────────────────────
//  newStakesPaused: blocks stake() and stakeFor() only.
//  unstake() has NO pause modifier — always permitted.
//
//  ── TRANSFER-BURN EXEMPTION REQUIRED (deployment step 10) ───────────────────
//  StakingContract MUST be marked transfer-burn exempt in AIEFToken:
//    token.setExempt(address(StakingContract), true, false)
//    burnExempt=true  → exact AIEF amounts received — required for _stake() receipt check
//    dexExempt=false  → StakingContract never buys from DEX; only DappStakeRouter is dexExempt
//  Without burnExempt=true, AIEFToken's 0.5% burn reduces AIEF received from stakers below
//  `amount`. The exact receipt check in _stake() will revert "SC: AIEF received mismatch"
//  on every stake — making the contract non-functional.
//
//  ── POST-DEPLOYMENT WINDOW — PLAN 5 ─────────────────────────────────────────
//  Plan 5 (Founder Bond) is registered in the constructor with directAllowed=false
//  and routerAllowed=false. Between constructor deployment and the required call:
//    setAuthorizedPlanCaller(5, address(FounderAllocationContract), true)
//  plan 5 is active but completely inaccessible — any stakeFor() for plan 5 reverts
//  "SC: caller not authorized for plan". This is safe and intentional but must be
//  executed as an immediate post-deployment step before founder registration begins.
//
//  ── DEPLOYMENT CHECKLIST — VERIFY BEFORE OPENING TO USERS ──────────────────
//  □ StakingContract is transfer-burn exempt in AIEFToken:
//      token.setExempt(address(StakingContract), true, false)
//    Without this, every stake() reverts "SC: AIEF received mismatch".
//
//  □ DappStakeRouter is set as a routerCaller:
//      StakingContract.setRouterCaller(address(DappStakeRouter), true)
//    Without this, all USDT→stake router flows revert.
//
//  □ FounderAllocationContract is authorized for the founder planId only:
//      StakingContract.setAuthorizedPlanCaller(5, address(FounderAllocationContract), true)
//    Verify planId=5 specifically — do not authorize it for any other planId.
//
//  □ Verify all four constructor wallet addresses are correct deployed contracts:
//      rewardsPool         → StakingRewardsPool contract
//      founderPoolWallet   → Founder Pool Gnosis Safe
//      lpAccumulatorWallet → LP Accumulator Gnosis Safe
//      opsSafe             → Ops Safe Gnosis Safe (3-of-5)
//    All four have code.length > 0 guards in the constructor — EOAs will revert.
//    Verify each address on BSCScan before deployment, not after.
// ════════════════════════════════════════════════════════════════════════════════

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract StakingContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── CONSTANTS ────────────────────────────────────────────────────────────

    uint256 public constant MIN_STAKE       = 1e18;
    uint256 public constant MAX_POSITIONS   = 350;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Maximum lockPeriod any externally registered plan may specify (5 years).
    ///         Guards against accidentally trapping users in a near-infinite lock.
    uint32 public constant MAX_LOCK_PERIOD = uint32(1825 days);

    /// @notice Exit deduction tiers — immutable. Applied by elapsed time from stakedAt.
    ///         elapsed <  60d  → T1 = 20%
    ///         elapsed  60–120d → T2 = 10%
    ///         elapsed 120–200d → T3 =  5%
    ///         elapsed >= 200d  → T4 =  0% (free exit)
    uint16 public constant T1 = 2000;
    uint16 public constant T2 = 1000;
    uint16 public constant T3 =  500;
    uint16 public constant T4 =    0;

    // ── PLAN REGISTRY ────────────────────────────────────────────────────────

    /// @notice Configuration for a staking plan.
    ///         No founderOnly field — restricted access is handled generically
    ///         via authorizedPlanCallers[planId][caller].
    struct PlanConfig {
        bool    exists;        // registered in the registry
        bool    active;        // accepts new stakes (deactivatable; never affects existing)
        bool    directAllowed; // stake() callable by user directly
        bool    routerAllowed; // stakeFor() callable by routerCallers
        uint32  lockPeriod;    // seconds — captured into Position at stake time
    }

    mapping(uint8 => PlanConfig) public plans;

    // ── POSITION STRUCT ──────────────────────────────────────────────────────

    /// @notice On-chain record of a single staking position.
    ///         lockPeriod captured at stake time — immutable for position's life.
    struct Position {
        uint256 principal;   // AIEF staked in wei
        uint8   planId;      // plan identifier at stake time
        uint64  stakedAt;    // block.timestamp at stake
        uint32  lockPeriod;  // captured from PlanConfig at stake time
        bool    active;      // false after unstake
    }

    // ── STATE VARIABLES ──────────────────────────────────────────────────────

    IERC20 public immutable token;
    address public immutable rewardsPool;
    address public immutable opsSafe;
    /// @notice Founder Pool Wallet — receives 25% of every exit deduction.
    ///         Dedicated Gnosis Safe — separate from Treasury Safe.
    ///         Accumulates founder revenue share for off-chain distribution.
    address public immutable founderPoolWallet;
    address public immutable lpAccumulatorWallet;

    bool public newStakesPaused;

    /// @notice Addresses authorised to call stakeFor() for routerAllowed plans.
    ///         DappStakeRouter is added here. Only contracts accepted (code.length > 0).
    mapping(address => bool) public routerCallers;

    /// @notice Per-plan per-caller authorization for stakeFor().
    ///         authorizedPlanCallers[planId][caller] = true gives `caller` the right
    ///         to call stakeFor() for that specific planId regardless of routerAllowed.
    ///         Used for: FounderAllocationContract on plan 5, any future special-access
    ///         contracts. No business-domain names or special branches needed here.
    mapping(uint8 => mapping(address => bool)) public authorizedPlanCallers;

    /// @notice All staking positions per wallet. Append-only.
    mapping(address => Position[]) public positions;

    // ── MODIFIERS ────────────────────────────────────────────────────────────

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "SC: only Ops Safe");
        _;
    }

    modifier whenNewStakesNotPaused() {
        require(!newStakesPaused, "SC: new stakes paused");
        _;
    }

    // ── EVENTS ───────────────────────────────────────────────────────────────

    event Staked(
        address indexed user,
        address indexed caller,
        uint256 positionId,
        uint256 amount,
        uint8   planId,
        uint32  lockPeriod
    );

    event Unstaked(
        address indexed user,
        uint256 positionId,
        uint256 returned,
        uint256 deduction
    );

    event DeductionDistributed(
        address indexed user,
        uint256 positionId,
        uint256 deadAmount,
        uint256 founderAmount,
        uint256 poolAmount,
        uint256 lpAmount
    );

    event PlanRegistered(uint8 indexed planId, PlanConfig config);
    event PlanDeactivated(uint8 indexed planId);
    event PlanActivated(uint8 indexed planId);
    event RouterCallerUpdated(address indexed caller, bool approved);
    event AuthorizedPlanCallerUpdated(uint8 indexed planId, address indexed caller, bool approved);
    event NewStakesPauseStateChanged(bool paused);

    // ─────────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploys and registers all initial plans.
    ///         Caller authorization (routerCallers, authorizedPlanCallers) is
    ///         configured post-deployment via admin functions.
    ///
    ///         Post-deployment configuration required:
    ///           setRouterCaller(address(DappStakeRouter), true)
    ///           setAuthorizedPlanCaller(5, address(FounderAllocationContract), true)
    ///
    ///         ⚠ TRANSFER-BURN EXEMPTION (deployment step 10):
    ///           token.setExempt(address(StakingContract), true, false)
    ///         Required or every stake reverts "SC: AIEF received mismatch".
    ///
    ///         ⚠ lpAccumulatorWallet_ must be a deployed contract (Gnosis Safe).
    ///         Confirm before mainnet deploy (open item O21).
    constructor(
        address token_,
        address rewardsPool_,
        address opsSafe_,
        address founderPoolWallet_,
        address lpAccumulatorWallet_
    ) {
        require(token_               != address(0), "SC: zero token");
        require(rewardsPool_         != address(0), "SC: zero pool");
        require(opsSafe_             != address(0), "SC: zero ops safe");
        require(founderPoolWallet_   != address(0), "SC: zero founder pool");
        require(lpAccumulatorWallet_ != address(0), "SC: zero LP wallet");

        require(token_.code.length               > 0, "SC: token not a contract");
        require(rewardsPool_.code.length         > 0, "SC: pool not a contract");
        require(opsSafe_.code.length             > 0, "SC: ops safe not a contract");
        require(founderPoolWallet_.code.length   > 0, "SC: founder pool not a contract");
        require(lpAccumulatorWallet_.code.length > 0, "SC: LP wallet not a contract");

        token               = IERC20(token_);
        rewardsPool         = rewardsPool_;
        opsSafe             = opsSafe_;
        founderPoolWallet   = founderPoolWallet_;
        lpAccumulatorWallet = lpAccumulatorWallet_;

        // ── Register initial 6 plans ─────────────────────────────────────────
        // Plan 0 — Flexible: direct only, no lock
        _registerPlan(0, PlanConfig({
            exists: true, active: true,
            directAllowed: true, routerAllowed: false,
            lockPeriod: 0
        }));
        // Plan 1 — Standard: direct + router, 60-day lock
        _registerPlan(1, PlanConfig({
            exists: true, active: true,
            directAllowed: true, routerAllowed: true,
            lockPeriod: uint32(60 days)
        }));
        // Plan 2 — Growth: direct + router, 120-day lock
        _registerPlan(2, PlanConfig({
            exists: true, active: true,
            directAllowed: true, routerAllowed: true,
            lockPeriod: uint32(120 days)
        }));
        // Plan 3 — Power: direct + router, 200-day lock
        _registerPlan(3, PlanConfig({
            exists: true, active: true,
            directAllowed: true, routerAllowed: true,
            lockPeriod: uint32(200 days)
        }));
        // Plan 4 — Elite: direct + router, 360-day lock
        _registerPlan(4, PlanConfig({
            exists: true, active: true,
            directAllowed: true, routerAllowed: true,
            lockPeriod: uint32(360 days)
        }));
        // Plan 5 — Founder Bond: no direct, no router — access via authorizedPlanCallers only.
        // Post-deployment: setAuthorizedPlanCaller(5, address(FounderAllocationContract), true)
        _registerPlan(5, PlanConfig({
            exists: true, active: true,
            directAllowed: false, routerAllowed: false,
            lockPeriod: uint32(360 days)
        }));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  PLAN REGISTRY MANAGEMENT (Ops Safe only)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Register a new plan.
    ///         Existing plan config cannot be overwritten — once a planId is
    ///         registered, its lockPeriod and routing flags are permanent.
    ///         Use deactivatePlan/activatePlan to control availability.
    ///
    ///         Admin policy: if package terms need to change in future, register
    ///         a new planId with the updated parameters. Never edit an existing
    ///         plan — users who staked under the original terms must be able to
    ///         verify those terms remain unchanged on-chain.
    ///
    ///         Plans with directAllowed=false and routerAllowed=false are valid —
    ///         they are accessed via authorizedPlanCallers set post-registration.
    function registerPlan(uint8 planId, PlanConfig calldata cfg)
        external onlyOpsSafe
    {
        require(!plans[planId].exists,      "SC: plan already registered");
        require(cfg.exists,                 "SC: exists must be true");
        require(cfg.lockPeriod <= MAX_LOCK_PERIOD, "SC: lock period exceeds maximum");
        _registerPlan(planId, cfg);
    }

    /// @notice Deactivate a plan — new stakes rejected, existing positions unaffected.
    function deactivatePlan(uint8 planId) external onlyOpsSafe {
        require(plans[planId].exists, "SC: plan not registered");
        require(plans[planId].active, "SC: plan already inactive");
        plans[planId].active = false;
        emit PlanDeactivated(planId);
    }

    /// @notice Re-activate a previously deactivated plan.
    function activatePlan(uint8 planId) external onlyOpsSafe {
        require(plans[planId].exists,  "SC: plan not registered");
        require(!plans[planId].active, "SC: plan already active");
        plans[planId].active = true;
        emit PlanActivated(planId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  CALLER AUTHORIZATION (Ops Safe only)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Add or remove an address from the routerCallers whitelist.
    ///         routerCallers may call stakeFor() for any plan with routerAllowed=true.
    ///         Only deployed contracts accepted (code.length > 0) when approving.
    ///
    ///         Example: setRouterCaller(address(DappStakeRouter), true)
    function setRouterCaller(address caller, bool approved) external onlyOpsSafe {
        require(caller != address(0), "SC: zero address");
        if (approved) {
            require(caller.code.length > 0, "SC: only contracts can be router callers");
        }
        routerCallers[caller] = approved;
        emit RouterCallerUpdated(caller, approved);
    }

    /// @notice Authorize or revoke a specific caller for a specific planId.
    ///         authorizedPlanCallers[planId][caller] grants stakeFor() access
    ///         for that plan regardless of routerAllowed or routerCallers.
    ///
    ///         This is how restricted plans (e.g. plan 5) are made accessible:
    ///           setAuthorizedPlanCaller(5, address(FounderAllocationContract), true)
    ///         Any future special-access contract follows the same pattern.
    ///         Only deployed contracts accepted (code.length > 0) when approving.
    function setAuthorizedPlanCaller(uint8 planId, address caller, bool approved)
        external onlyOpsSafe
    {
        require(plans[planId].exists, "SC: plan not registered");
        require(caller != address(0), "SC: zero address");
        if (approved) {
            require(caller.code.length > 0, "SC: only contracts can be authorized");
        }
        authorizedPlanCallers[planId][caller] = approved;
        emit AuthorizedPlanCallerUpdated(planId, caller, approved);
    }

    /// @notice Pause or unpause new stake creation.
    ///         ⚠ NEVER affects unstake() — matured principal withdrawal is always permitted.
    function pauseNewStakes(bool paused) external onlyOpsSafe {
        require(newStakesPaused != paused, "SC: same pause state");
        newStakesPaused = paused;
        emit NewStakesPauseStateChanged(paused);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  STAKING — PUBLIC ENTRY POINTS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Stake AIEF directly. Plan must have directAllowed=true.
    function stake(uint256 amount, uint8 planId)
        external nonReentrant whenNewStakesNotPaused
    {
        _validatePlan(planId, msg.sender, true);
        _stake(msg.sender, msg.sender, amount, planId);
    }

    /// @notice Stake on behalf of a beneficiary.
    ///         Caller must be either a routerCaller (for routerAllowed plans) or
    ///         an authorizedPlanCaller for the specific planId.
    ///         Returns positionId so caller can include it in its own event.
    function stakeFor(address beneficiary, uint256 amount, uint8 planId)
        external nonReentrant whenNewStakesNotPaused
        returns (uint256 positionId)
    {
        _validatePlan(planId, msg.sender, false);
        return _stake(beneficiary, msg.sender, amount, planId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  UNSTAKING — NEVER PAUSABLE
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Unstake a matured position and return principal (minus any deduction).
    ///
    ///         !! NO PAUSE MODIFIER — this function must NEVER be blocked !!
    ///         Reads pos.lockPeriod from the stored position — NOT the registry.
    ///         Plan config changes never affect existing positions.
    function unstake(uint256 positionId) external nonReentrant {
        require(
            positionId < positions[msg.sender].length,
            "SC: invalid position"
        );

        Position storage pos = positions[msg.sender][positionId];
        require(pos.active, "SC: position not active");

        uint256 elapsed = block.timestamp - uint256(pos.stakedAt);
        require(
            elapsed >= uint256(pos.lockPeriod),
            "SC: position locked"
        );

        uint256 deduction = _calculateDeduction(elapsed, pos.principal);

        // CEI: mark inactive before transfers
        pos.active = false;

        if (deduction > 0) {
            _distributeDeduction(msg.sender, positionId, deduction);
        }

        uint256 returned = pos.principal - deduction;
        token.safeTransfer(msg.sender, returned);

        emit Unstaked(msg.sender, positionId, returned, deduction);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  INTERNAL — PLAN VALIDATION
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Validate plan availability and caller authorization.
    ///         No business-domain logic (no "founder", no named contracts).
    ///
    ///         Direct stake: plan must have directAllowed=true.
    ///         stakeFor():   caller must be a routerCaller (for routerAllowed plans)
    ///                       OR an authorizedPlanCaller for this specific planId.
    function _validatePlan(
        uint8   planId,
        address caller,
        bool    isDirectStake
    ) internal view {
        PlanConfig memory cfg = plans[planId];
        require(cfg.exists && cfg.active, "SC: plan not active");

        if (isDirectStake) {
            require(cfg.directAllowed, "SC: direct stake not allowed for plan");
        } else {
            bool isRouter     = routerCallers[caller] && cfg.routerAllowed;
            bool isAuthorized = authorizedPlanCallers[planId][caller];
            require(isRouter || isAuthorized, "SC: caller not authorized for plan");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  INTERNAL — STAKE LOGIC
    // ─────────────────────────────────────────────────────────────────────────

    function _stake(
        address beneficiary,
        address tokenSource,
        uint256 amount,
        uint8   planId
    ) internal returns (uint256 positionId) {
        require(beneficiary != address(0), "SC: zero beneficiary");
        require(amount >= MIN_STAKE,       "SC: below minimum");
        require(
            positions[beneficiary].length < MAX_POSITIONS,
            "SC: max positions reached"
        );

        // Capture lockPeriod into position — immutable for life of position.
        // Subsequent registry changes cannot affect this position's lock.
        uint32 lockPeriod = plans[planId].lockPeriod;

        // Exact receipt check: verify this contract received exactly `amount` AIEF.
        // If StakingContract is not transfer-burn exempt in AIEFToken, the 0.5%
        // burn reduces what we receive, corrupting position accounting.
        // See header for exemption requirement.
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(tokenSource, address(this), amount);
        require(
            token.balanceOf(address(this)) == balanceBefore + amount,
            "SC: AIEF received mismatch"
        );

        positionId = positions[beneficiary].length;
        positions[beneficiary].push(Position({
            principal:  amount,
            planId:     planId,
            stakedAt:   uint64(block.timestamp),
            lockPeriod: lockPeriod,
            active:     true
        }));

        emit Staked(beneficiary, tokenSource, positionId, amount, planId, lockPeriod);
        return positionId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  INTERNAL — PLAN REGISTRATION
    // ─────────────────────────────────────────────────────────────────────────

    function _registerPlan(uint8 planId, PlanConfig memory cfg) internal {
        plans[planId] = cfg;
        emit PlanRegistered(planId, cfg);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  INTERNAL — EXIT DEDUCTION LOGIC
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Immutable deduction tiers — cannot be changed by anyone.
    ///         Applied universally to all plans by elapsed time from stakedAt.
    function _calculateDeduction(uint256 elapsed, uint256 principal)
        internal pure returns (uint256)
    {
        uint16 bps;
        if      (elapsed <  60  days) bps = T1;
        else if (elapsed <  120 days) bps = T2;
        else if (elapsed <  200 days) bps = T3;
        else                          bps = T4;
        return (principal * bps) / BPS_DENOMINATOR;
    }

    /// @notice Equal 4-way split. lpAmount absorbs remainder — no dust trapped.
    function _distributeDeduction(
        address user,
        uint256 positionId,
        uint256 deduction
    ) internal {
        uint256 q              = deduction / 4;
        uint256 deadAmount     = q;
        uint256 founderAmount  = q;
        uint256 poolAmount     = q;
        uint256 lpAmount       = deduction - deadAmount - founderAmount - poolAmount;

        token.safeTransfer(DEAD,                deadAmount);
        token.safeTransfer(founderPoolWallet,   founderAmount);
        token.safeTransfer(rewardsPool,         poolAmount);
        token.safeTransfer(lpAccumulatorWallet, lpAmount);

        emit DeductionDistributed(user, positionId, deadAmount, founderAmount, poolAmount, lpAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns true if planId exists, is active, and has routerAllowed=true.
    ///         Used by DappStakeRouter pre-flight check before executing swap.
    function isRouterPlanAllowed(uint8 planId) external view returns (bool) {
        PlanConfig memory cfg = plans[planId];
        return cfg.exists && cfg.active && cfg.routerAllowed;
    }

    /// @notice Returns true if planId exists, is active, and has directAllowed=true.
    function isDirectPlanAllowed(uint8 planId) external view returns (bool) {
        PlanConfig memory cfg = plans[planId];
        return cfg.exists && cfg.active && cfg.directAllowed;
    }

    /// @notice Full plan configuration for a given planId.
    function getPlanConfig(uint8 planId) external view returns (PlanConfig memory) {
        return plans[planId];
    }

    /// @notice Total number of positions for a wallet (including closed ones).
    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    /// @notice Full details of a single position.
    function getPosition(address user, uint256 positionId)
        external view
        returns (
            uint256 principal,
            uint8   planId,
            uint64  stakedAt,
            uint32  lockPeriod,
            bool    active
        )
    {
        require(positionId < positions[user].length, "SC: invalid position");
        Position memory p = positions[user][positionId];
        return (p.principal, p.planId, p.stakedAt, p.lockPeriod, p.active);
    }

    /// @notice Returns all active positions for a wallet.
    ///         Capped at MAX_POSITIONS (350) — safe for view calls.
    function getActivePositions(address user)
        external view
        returns (Position[] memory activePositions, uint256[] memory activeIds)
    {
        uint256 total = positions[user].length;
        uint256 count = 0;
        for (uint256 i = 0; i < total; i++) {
            if (positions[user][i].active) count++;
        }
        activePositions = new Position[](count);
        activeIds       = new uint256[](count);
        uint256 idx     = 0;
        for (uint256 i = 0; i < total; i++) {
            if (positions[user][i].active) {
                activePositions[idx] = positions[user][i];
                activeIds[idx]       = i;
                idx++;
            }
        }
    }

    /// @notice Preview the deduction for a position if unstaked now.
    ///         Reverts with "SC: invalid position" if positionId is out of bounds.
    ///         Returns (0, 0) if position is locked or already inactive.
    function previewDeduction(address user, uint256 positionId)
        external view
        returns (uint256 deduction, uint256 returned)
    {
        require(positionId < positions[user].length, "SC: invalid position");
        Position memory pos = positions[user][positionId];
        if (!pos.active) return (0, 0);
        uint256 elapsed = block.timestamp - uint256(pos.stakedAt);
        if (elapsed < uint256(pos.lockPeriod)) return (0, 0);
        deduction = _calculateDeduction(elapsed, pos.principal);
        returned  = pos.principal - deduction;
    }

    /// @notice Returns true if a position is past its lock period and can be unstaked.
    function isUnlocked(address user, uint256 positionId)
        external view returns (bool)
    {
        require(positionId < positions[user].length, "SC: invalid position");
        Position memory pos = positions[user][positionId];
        if (!pos.active) return false;
        return block.timestamp >= uint256(pos.stakedAt) + uint256(pos.lockPeriod);
    }
}
