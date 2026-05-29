// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IPancakeRouter {
    /// @dev Standard swap — expects to receive exactly amounts[1].
    ///      Safe here because DappStakeRouter is transfer-burn exempt.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @dev Preview: returns amounts[1] = expected AIEF output for usdtIn.
    ///      Used to compute amountOutMin with slippage applied.
    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

interface IStakingContract {
    /// @dev Creates a staking position for beneficiary. Plan validity enforced by registry.
    ///      DappStakeRouter must be whitelisted in StakingContract.
    function stakeFor(
        address beneficiary,
        uint256 amount,
        uint8 planId
    ) external returns (uint256 positionId);

    /// @dev Returns true if planId exists, is active, and has routerAllowed=true.
    ///      Called before swap — rejects invalid plans without wasting swap gas.
    function isRouterPlanAllowed(uint8 planId) external view returns (bool);
}

// ─────────────────────────────────────────────────────────────────────────────
//  DappStakeRouter
// ─────────────────────────────────────────────────────────────────────────────

contract DappStakeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── CONSTANTS ────────────────────────────────────────────────────────────

    /// @notice Basis-points denominator for slippage calculations.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum slippage Ops Safe can configure. 0.5% floor prevents
    ///         dust slippage values that would cause most swaps to revert.
    uint16 public constant MIN_SLIPPAGE_BPS = 50;

    /// @notice Maximum slippage Ops Safe can configure. 10% ceiling prevents
    ///         accidental configuration that would expose users to large losses.
    uint16 public constant MAX_SLIPPAGE_BPS = 1_000;

    /// @notice Default slippage applied to swaps. 2% is standard for BSC DEX
    ///         swaps with moderate liquidity.
    uint16 public constant DEFAULT_SLIPPAGE_BPS = 200;

    /// @notice Maximum user-supplied deadline window from block.timestamp.
    ///         30 minutes ceiling — prevents near-permanent authorisations.
    ///         The user/dApp supplies the actual deadline in stake().
    uint256 public constant MAX_DEADLINE_WINDOW = 30 minutes;

    // ── IMMUTABLE STATE ──────────────────────────────────────────────────────

    /// @notice AIEF token contract. Immutable.
    IERC20 public immutable token;

    /// @notice BSC USDT contract. Immutable.
    ///         Address: 0x55d398326f99059fF775485246999027B3197955
    IERC20 public immutable usdt;

    /// @notice PancakeSwap V2 Router. Immutable.
    ///         Address: 0x10ED43C718714eb63d5aA57B78B54704E256024E
    IPancakeRouter public immutable pancakeRouter;

    /// @notice StakingContract. Immutable. DappStakeRouter must be whitelisted.
    IStakingContract public immutable stakingContract;

    /// @notice Ops Safe multisig. Immutable.
    address public immutable opsSafe;

    /// @notice Absolute hard ceiling on USDT per transaction — set at construction,
    ///         never changeable. Ops Safe cannot raise maxUsdtPerStake above this.
    ///         = 100,000 × 10^decimals. Protects against misconfiguration.
    uint256 public immutable ABSOLUTE_MAX_USDT;

    /// @notice Derived USDT unit (10^decimals). Used for limit calculations.
    uint256 public immutable USDT_UNIT;

    // ── MUTABLE STATE ────────────────────────────────────────────────────────

    /// @notice Operational minimum USDT per transaction. Ops Safe adjustable.
    ///         Default: 1 × USDT_UNIT (~$1). Floor: 1 × USDT_UNIT.
    uint256 public minUsdtPerStake;

    /// @notice Operational maximum USDT per transaction. Ops Safe adjustable.
    ///         Default: 10,000 × USDT_UNIT (~$10,000). Ceiling: ABSOLUTE_MAX_USDT.
    uint256 public maxUsdtPerStake;

    /// @notice Slippage tolerance used by previewStake() to compute suggestedMin.
    ///         Default: 200 (2%). Range: 50–1000 bps. Configurable by Ops Safe.
    ///         PREVIEW ONLY — this value does not affect stake() execution.
    ///         stake() uses the user-supplied minAiefOut parameter directly.
    uint16 public slippageBps;

    /// @notice When true, stake() reverts. Ops Safe emergency control.
    ///         Does not affect any existing staking positions.
    bool public paused;

    // ── EVENTS ───────────────────────────────────────────────────────────────

    /// @notice Emitted on every successful stake via this router.
    ///         usdtIn: gross USDT pulled from user.
    ///         aiefStaked: AIEF received from swap and staked (balance delta).
    ///         positionId: StakingContract position index for msg.sender.
    event Staked(
        address indexed staker,
        uint256 usdtIn,
        uint256 aiefStaked,
        uint8 planId,
        uint256 positionId
    );

    /// @notice Emitted when Ops Safe updates the slippage tolerance.
    event SlippageUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when Ops Safe updates USDT operational limits.
    event UsdtLimitsUpdated(uint256 newMin, uint256 newMax);

    /// @notice Emitted when Ops Safe pauses or unpauses the router.
    event RouterPauseStateChanged(bool paused);

    // ── MODIFIERS ────────────────────────────────────────────────────────────

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "DSR: only Ops Safe");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "DSR: paused");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploys the router. Called at deployment step 7 (Spec Section 1.2).
    ///
    ///         ⚠ EXEMPTION REQUIREMENT (deployment step 10):
    ///         DappStakeRouter MUST be set in AIEFToken with both exemption flags:
    ///           token.setExempt(address(DappStakeRouter), true, true)
    ///           burnExempt=true: AIEF received from PancakeSwap is not burned
    ///           dexExempt=true:  Can buy from DEX during 180-day restriction
    ///         Without these, the USDT staking route will not work.
    ///
    ///         ⚠ WHITELIST REQUIREMENT:
    ///         DappStakeRouter MUST be set as a routerCaller in StakingContract:
    ///           stakingContract.setRouterCaller(address(DappStakeRouter), true)
    ///         Without this, stakeFor() will revert "SC: caller not authorized for plan".
    ///         Note: the function is setRouterCaller() — NOT setWhitelisted().
    ///
    /// @param token_           AIEF token contract (step 1)
    /// @param usdt_            BSC USDT — 0x55d398326f99059fF775485246999027B3197955
    /// @param pancakeRouter_   PancakeSwap V2 Router — 0x10ED43C718714eb63d5aA57B78B54704E256024E
    /// @param stakingContract_ StakingContract (step 3)
    /// @param opsSafe_         Ops Safe multisig
    constructor(
        address token_,
        address usdt_,
        address pancakeRouter_,
        address stakingContract_,
        address opsSafe_
    ) {
        require(token_ != address(0), "DSR: zero token");
        require(usdt_ != address(0), "DSR: zero usdt");
        require(pancakeRouter_ != address(0), "DSR: zero router");
        require(stakingContract_ != address(0), "DSR: zero staking");
        require(opsSafe_ != address(0), "DSR: zero ops safe");

        require(token_.code.length > 0, "DSR: token not a contract");
        require(usdt_.code.length > 0, "DSR: usdt not a contract");
        require(pancakeRouter_.code.length > 0, "DSR: router not a contract");
        require(
            stakingContract_.code.length > 0,
            "DSR: staking not a contract"
        );
        require(opsSafe_.code.length > 0, "DSR: ops safe not a contract");

        // Derive USDT unit from on-chain decimals — NOT hardcoded.
        // BSC USDT = 18 decimals. Handles any USDT variant correctly.
        uint8 decimals = IERC20Metadata(usdt_).decimals();
        uint256 unit = 10 ** uint256(decimals);

        USDT_UNIT = unit;
        ABSOLUTE_MAX_USDT = 100_000 * unit; // hard ceiling — never changeable
        minUsdtPerStake = 1 * unit; // operational default: ~$1
        maxUsdtPerStake = 10_000 * unit; // operational default: ~$10,000

        token = IERC20(token_);
        usdt = IERC20(usdt_);
        pancakeRouter = IPancakeRouter(pancakeRouter_);
        stakingContract = IStakingContract(stakingContract_);
        opsSafe = opsSafe_;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  CORE FUNCTION
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Swap USDT for AIEF and stake it for msg.sender in one transaction.
    ///
    ///         ── FLOW ────────────────────────────────────────────────────────
    ///         1. Validate inputs (planId via registry, usdtIn range, minAiefOut, deadline)
    ///         2. Snapshot USDT and AIEF balances
    ///         3. Pull usdtIn USDT from msg.sender — verify receipt
    ///         4. Approve PancakeSwap router to spend usdtIn USDT
    ///         5. Execute swap: USDT → AIEF (minAiefOut enforced by router)
    ///         6. Measure actual AIEF received via balance delta
    ///         7. Verify aiefReceived >= minAiefOut (defence-in-depth)
    ///         8. Approve StakingContract to pull received AIEF
    ///         9. Call stakingContract.stakeFor(msg.sender, aiefReceived, planId)
    ///        10. Reset all approvals to 0
    ///        11. Verify balance-delta post-conditions
    ///        12. Emit Staked event
    ///
    ///         ── PLAN VALIDITY ────────────────────────────────────────────────
    ///         Plan validity is delegated to StakingContract.isRouterPlanAllowed().
    ///         No plan IDs are hardcoded here. New plans are supported automatically
    ///         when Ops Safe registers them in StakingContract.
    ///
    ///         ── SLIPPAGE — USER SUPPLIED ─────────────────────────────────────
    ///         minAiefOut must be supplied by the user/dApp. slippageBps in this
    ///         contract is advisory only — used by previewStake() UI helper.
    ///         It does not affect stake() execution.
    ///
    ///         ── DEADLINE — USER SUPPLIED ─────────────────────────────────────
    ///         The user supplies deadline. Capped at block.timestamp +
    ///         MAX_DEADLINE_WINDOW (30 min) to prevent near-permanent authorisations.
    ///
    /// @param usdtIn       Gross USDT — must be in [minUsdtPerStake, maxUsdtPerStake]
    /// @param planId       Plan identifier — validity checked against StakingContract registry
    /// @param minAiefOut   Minimum AIEF to receive — user/dApp computed, on-chain enforced
    /// @param deadline     Transaction deadline — user supplied, max 30 min from now
    /// @return positionId  StakingContract position index for msg.sender
    function stake(
        uint256 usdtIn,
        uint8 planId,
        uint256 minAiefOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 positionId) {
        // ── CHECKS ───────────────────────────────────────────────────────────

        require(usdtIn >= minUsdtPerStake, "DSR: below minimum");
        require(usdtIn <= maxUsdtPerStake, "DSR: above maximum");
        // Plan validity deferred to StakingContract registry — no hardcoded planId ranges.
        // isRouterPlanAllowed() checks: exists=true, active=true, routerAllowed=true.
        // Called before USDT pull so a rejected plan fails cheaply without wasting gas.
        require(
            stakingContract.isRouterPlanAllowed(planId),
            "DSR: plan not router-allowed"
        );
        require(minAiefOut > 0, "DSR: zero min out");
        require(deadline >= block.timestamp, "DSR: deadline expired");
        require(
            deadline <= block.timestamp + MAX_DEADLINE_WINDOW,
            "DSR: deadline too far"
        );

        // ── SNAPSHOT BALANCES (balance-delta post-condition baseline) ─────────
        uint256 usdtBefore = usdt.balanceOf(address(this));
        uint256 aiefBefore = token.balanceOf(address(this));

        // ── PULL USDT FROM CALLER ─────────────────────────────────────────────
        usdt.safeTransferFrom(msg.sender, address(this), usdtIn);
        // Verify this contract received exactly usdtIn.
        // Guards against fee-on-transfer USDT variants that deliver less than requested.
        require(
            usdt.balanceOf(address(this)) == usdtBefore + usdtIn,
            "DSR: USDT not received"
        );

        // ── BUILD SWAP PATH: USDT → AIEF ──────────────────────────────────────
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(token);

        // ── APPROVE ROUTER TO SPEND USDT ─────────────────────────────────────
        usdt.forceApprove(address(pancakeRouter), usdtIn);

        // ── EXECUTE SWAP ──────────────────────────────────────────────────────
        // Standard variant — NOT FeeOnTransfer. DappStakeRouter is
        // isTransferBurnExempt so AIEF received is not subject to the 0.5% burn.
        // minAiefOut is user-supplied — real sandwich protection.
        pancakeRouter.swapExactTokensForTokens(
            usdtIn,
            minAiefOut,
            path,
            address(this),
            deadline
        );

        // ── MEASURE ACTUAL AIEF RECEIVED ──────────────────────────────────────
        uint256 aiefReceived = token.balanceOf(address(this)) - aiefBefore;
        require(aiefReceived > 0, "DSR: zero AIEF received");
        // Defence-in-depth: verify balance delta satisfies the user's minAiefOut.
        // The swap's amountOutMin already enforces this, but an explicit post-swap
        // check provides a clean contract-level error and guards against exotic routers.
        require(aiefReceived >= minAiefOut, "DSR: insufficient AIEF received");

        // ── RESET USDT APPROVAL ───────────────────────────────────────────────
        usdt.forceApprove(address(pancakeRouter), 0);

        // ── APPROVE STAKING CONTRACT TO PULL AIEF ─────────────────────────────
        token.forceApprove(address(stakingContract), aiefReceived);

        // ── STAKE FOR msg.sender ──────────────────────────────────────────────
        positionId = stakingContract.stakeFor(msg.sender, aiefReceived, planId);

        // ── RESET AIEF APPROVAL ───────────────────────────────────────────────
        token.forceApprove(address(stakingContract), 0);

        // ── BALANCE-DELTA POST-CONDITIONS ─────────────────────────────────────
        require(usdt.balanceOf(address(this)) == usdtBefore, "DSR: USDT delta");
        require(
            token.balanceOf(address(this)) == aiefBefore,
            "DSR: AIEF delta"
        );

        emit Staked(msg.sender, usdtIn, aiefReceived, planId, positionId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  ADMIN (Ops Safe only)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Update the slippage tolerance applied to previewStake() suggestions.
    ///         Advisory only — does not affect stake() execution.
    ///         Range: 50–1000 bps (0.5%–10%). Default: 200 bps (2%).
    function setSlippage(uint16 newBps) external onlyOpsSafe {
        require(newBps >= MIN_SLIPPAGE_BPS, "DSR: slippage too low");
        require(newBps <= MAX_SLIPPAGE_BPS, "DSR: slippage too high");
        require(newBps != slippageBps, "DSR: same slippage");
        uint16 old = slippageBps;
        slippageBps = newBps;
        emit SlippageUpdated(old, newBps);
    }

    /// @notice Update operational USDT limits per transaction.
    ///         newMin: floor for acceptable transactions.
    ///         newMax: ceiling — must not exceed ABSOLUTE_MAX_USDT.
    ///         Use this when business package sizes change (e.g. adding a
    ///         $50,000 institutional package) without redeploying the router.
    ///
    /// @param newMin New minimum USDT per transaction (>= 1 × USDT_UNIT)
    /// @param newMax New maximum USDT per transaction (<= ABSOLUTE_MAX_USDT)
    function setUsdtLimits(
        uint256 newMin,
        uint256 newMax
    ) external onlyOpsSafe {
        require(newMin >= USDT_UNIT, "DSR: min below 1 unit");
        require(newMax <= ABSOLUTE_MAX_USDT, "DSR: max above absolute cap");
        require(newMin <= newMax, "DSR: min exceeds max");
        require(
            newMin != minUsdtPerStake || newMax != maxUsdtPerStake,
            "DSR: same limits"
        );
        minUsdtPerStake = newMin;
        maxUsdtPerStake = newMax;
        emit UsdtLimitsUpdated(newMin, newMax);
    }

    /// @notice Pause or unpause the stake() function.
    ///         Emergency control — stops new USDT→stake entries only.
    ///         Has no effect on existing staking positions or unstaking.
    ///
    /// @param paused_ True to pause, false to unpause
    function pause(bool paused_) external onlyOpsSafe {
        require(paused != paused_, "DSR: same pause state");
        paused = paused_;
        emit RouterPauseStateChanged(paused_);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice UI helper — suggests minAiefOut and expected output for a given USDT input.
    ///
    ///         ⚠ ADVISORY ONLY. This function reads live PancakeSwap reserves.
    ///         It does NOT guarantee the execution price of a subsequent stake() call.
    ///         Reserves may change between previewStake() and stake() execution.
    ///         The user/dApp must pass the result as minAiefOut into stake() where
    ///         it is enforced on-chain. This function provides a suggested starting
    ///         point — the user may apply additional tolerance before signing.
    ///
    ///         slippageBps is used here for the suggestedMin calculation only.
    ///         It is NOT the slippage enforced in stake() — that comes from the
    ///         user-supplied minAiefOut parameter.
    ///
    ///         Reverts if usdtIn is outside [minUsdtPerStake, maxUsdtPerStake]
    ///         so the UI never quotes amounts that stake() would reject.
    ///
    /// @param usdtIn   USDT amount to preview — must be in [minUsdtPerStake, maxUsdtPerStake]
    /// @return expectedAIEF  Raw PancakeSwap output at current reserves
    /// @return suggestedMin  expectedAIEF with slippageBps applied — suggested minAiefOut
    function previewStake(
        uint256 usdtIn
    ) external view returns (uint256 expectedAIEF, uint256 suggestedMin) {
        require(usdtIn >= minUsdtPerStake, "DSR: below minimum");
        require(usdtIn <= maxUsdtPerStake, "DSR: above maximum");

        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(token);

        uint256[] memory amounts = pancakeRouter.getAmountsOut(usdtIn, path);
        expectedAIEF = amounts[1];
        suggestedMin =
            (expectedAIEF * (BPS_DENOMINATOR - slippageBps)) /
            BPS_DENOMINATOR;
    }

    /// @notice Returns the current USDT and AIEF balances of this contract.
    ///         Both balances should normally remain unchanged by successful stake()
    ///         calls. A non-zero result usually means tokens were sent directly
    ///         to this contract outside stake().
    function contractBalances()
        external
        view
        returns (uint256 usdtBalance, uint256 aiefBalance)
    {
        return (usdt.balanceOf(address(this)), token.balanceOf(address(this)));
    }
}
