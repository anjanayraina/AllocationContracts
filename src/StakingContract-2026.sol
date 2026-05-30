// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract StakingContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_STAKE = 1e18;
    uint256 public constant MAX_POSITIONS = 350;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint32 public constant MAX_LOCK_PERIOD = uint32(1825 days);

    uint16 public constant T1 = 2000;
    uint16 public constant T2 = 1000;
    uint16 public constant T3 = 500;
    uint16 public constant T4 = 0;

    struct PlanConfig {
        bool exists;
        bool active;
        bool directAllowed;
        bool routerAllowed;
        uint32 lockPeriod;
    }

    mapping(uint8 => PlanConfig) public plans;

    struct Position {
        uint256 principal;
        uint8 planId;
        uint64 stakedAt;
        uint32 lockPeriod;
        bool active;
    }

    IERC20 public immutable token;
    address public immutable rewardsPool;
    address public immutable opsSafe;
    address public immutable founderPoolWallet;
    address public immutable lpAccumulatorWallet;

    bool public newStakesPaused;

    mapping(address => bool) public routerCallers;

    mapping(uint8 => mapping(address => bool)) public authorizedPlanCallers;

    mapping(address => Position[]) public positions;

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "SC: only Ops Safe");
        _;
    }

    modifier whenNewStakesNotPaused() {
        require(!newStakesPaused, "SC: new stakes paused");
        _;
    }

    event Staked(
        address indexed user,
        address indexed caller,
        uint256 positionId,
        uint256 amount,
        uint8 planId,
        uint32 lockPeriod
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
    event AuthorizedPlanCallerUpdated(
        uint8 indexed planId,
        address indexed caller,
        bool approved
    );
    event NewStakesPauseStateChanged(bool paused);

    constructor(
        address token_,
        address rewardsPool_,
        address opsSafe_,
        address founderPoolWallet_,
        address lpAccumulatorWallet_
    ) {
        require(token_ != address(0), "SC: zero token");
        require(rewardsPool_ != address(0), "SC: zero pool");
        require(opsSafe_ != address(0), "SC: zero ops safe");
        require(founderPoolWallet_ != address(0), "SC: zero founder pool");
        require(lpAccumulatorWallet_ != address(0), "SC: zero LP wallet");

        require(token_.code.length > 0, "SC: token not a contract");
        require(rewardsPool_.code.length > 0, "SC: pool not a contract");
        require(opsSafe_.code.length > 0, "SC: ops safe not a contract");
        require(
            founderPoolWallet_.code.length > 0,
            "SC: founder pool not a contract"
        );
        require(
            lpAccumulatorWallet_.code.length > 0,
            "SC: LP wallet not a contract"
        );

        token = IERC20(token_);
        rewardsPool = rewardsPool_;
        opsSafe = opsSafe_;
        founderPoolWallet = founderPoolWallet_;
        lpAccumulatorWallet = lpAccumulatorWallet_;

        _registerPlan(
            0,
            PlanConfig({
                exists: true,
                active: true,
                directAllowed: true,
                routerAllowed: false,
                lockPeriod: 0
            })
        );
        _registerPlan(
            1,
            PlanConfig({
                exists: true,
                active: true,
                directAllowed: true,
                routerAllowed: true,
                lockPeriod: uint32(60 days)
            })
        );
        _registerPlan(
            2,
            PlanConfig({
                exists: true,
                active: true,
                directAllowed: true,
                routerAllowed: true,
                lockPeriod: uint32(120 days)
            })
        );
        _registerPlan(
            3,
            PlanConfig({
                exists: true,
                active: true,
                directAllowed: true,
                routerAllowed: true,
                lockPeriod: uint32(200 days)
            })
        );
        _registerPlan(
            4,
            PlanConfig({
                exists: true,
                active: true,
                directAllowed: true,
                routerAllowed: true,
                lockPeriod: uint32(360 days)
            })
        );
        _registerPlan(
            5,
            PlanConfig({
                exists: true,
                active: true,
                directAllowed: false,
                routerAllowed: false,
                lockPeriod: uint32(360 days)
            })
        );
    }

    function registerPlan(
        uint8 planId,
        PlanConfig calldata cfg
    ) external onlyOpsSafe {
        require(!plans[planId].exists, "SC: plan already registered");
        require(cfg.exists, "SC: exists must be true");
        require(
            cfg.lockPeriod <= MAX_LOCK_PERIOD,
            "SC: lock period exceeds maximum"
        );
        _registerPlan(planId, cfg);
    }

    function deactivatePlan(uint8 planId) external onlyOpsSafe {
        require(plans[planId].exists, "SC: plan not registered");
        require(plans[planId].active, "SC: plan already inactive");
        plans[planId].active = false;
        emit PlanDeactivated(planId);
    }

    function activatePlan(uint8 planId) external onlyOpsSafe {
        require(plans[planId].exists, "SC: plan not registered");
        require(!plans[planId].active, "SC: plan already active");
        plans[planId].active = true;
        emit PlanActivated(planId);
    }

    function setRouterCaller(
        address caller,
        bool approved
    ) external onlyOpsSafe {
        require(caller != address(0), "SC: zero address");
        if (approved) {
            require(
                caller.code.length > 0,
                "SC: only contracts can be router callers"
            );
        }
        routerCallers[caller] = approved;
        emit RouterCallerUpdated(caller, approved);
    }

    function setAuthorizedPlanCaller(
        uint8 planId,
        address caller,
        bool approved
    ) external onlyOpsSafe {
        require(plans[planId].exists, "SC: plan not registered");
        require(caller != address(0), "SC: zero address");
        if (approved) {
            require(
                caller.code.length > 0,
                "SC: only contracts can be authorized"
            );
        }
        authorizedPlanCallers[planId][caller] = approved;
        emit AuthorizedPlanCallerUpdated(planId, caller, approved);
    }

    function pauseNewStakes(bool paused) external onlyOpsSafe {
        require(newStakesPaused != paused, "SC: same pause state");
        newStakesPaused = paused;
        emit NewStakesPauseStateChanged(paused);
    }

    function stake(
        uint256 amount,
        uint8 planId
    ) external nonReentrant whenNewStakesNotPaused {
        _validatePlan(planId, msg.sender, true);
        _stake(msg.sender, msg.sender, amount, planId);
    }

    function stakeFor(
        address beneficiary,
        uint256 amount,
        uint8 planId
    )
        external
        nonReentrant
        whenNewStakesNotPaused
        returns (uint256 positionId)
    {
        _validatePlan(planId, msg.sender, false);
        return _stake(beneficiary, msg.sender, amount, planId);
    }

    function unstake(uint256 positionId) external nonReentrant {
        require(
            positionId < positions[msg.sender].length,
            "SC: invalid position"
        );

        Position storage pos = positions[msg.sender][positionId];
        require(pos.active, "SC: position not active");

        uint256 elapsed = block.timestamp - uint256(pos.stakedAt);
        require(elapsed >= uint256(pos.lockPeriod), "SC: position locked");

        uint256 deduction = _calculateDeduction(elapsed, pos.principal);

        pos.active = false;

        if (deduction > 0) {
            _distributeDeduction(msg.sender, positionId, deduction);
        }

        uint256 returned = pos.principal - deduction;
        token.safeTransfer(msg.sender, returned);

        emit Unstaked(msg.sender, positionId, returned, deduction);
    }

    function _validatePlan(
        uint8 planId,
        address caller,
        bool isDirectStake
    ) internal view {
        PlanConfig memory cfg = plans[planId];
        require(cfg.exists && cfg.active, "SC: plan not active");

        if (isDirectStake) {
            require(cfg.directAllowed, "SC: direct stake not allowed for plan");
        } else {
            bool isRouter = routerCallers[caller] && cfg.routerAllowed;
            bool isAuthorized = authorizedPlanCallers[planId][caller];
            require(
                isRouter || isAuthorized,
                "SC: caller not authorized for plan"
            );
        }
    }

    function _stake(
        address beneficiary,
        address tokenSource,
        uint256 amount,
        uint8 planId
    ) internal returns (uint256 positionId) {
        require(beneficiary != address(0), "SC: zero beneficiary");
        require(amount >= MIN_STAKE, "SC: below minimum");
        require(
            positions[beneficiary].length < MAX_POSITIONS,
            "SC: max positions reached"
        );

        uint32 lockPeriod = plans[planId].lockPeriod;

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(tokenSource, address(this), amount);
        require(
            token.balanceOf(address(this)) == balanceBefore + amount,
            "SC: AIEF received mismatch"
        );

        positionId = positions[beneficiary].length;
        positions[beneficiary].push(
            Position({
                principal: amount,
                planId: planId,
                stakedAt: uint64(block.timestamp),
                lockPeriod: lockPeriod,
                active: true
            })
        );

        emit Staked(
            beneficiary,
            tokenSource,
            positionId,
            amount,
            planId,
            lockPeriod
        );
        return positionId;
    }

    function _registerPlan(uint8 planId, PlanConfig memory cfg) internal {
        plans[planId] = cfg;
        emit PlanRegistered(planId, cfg);
    }

    function _calculateDeduction(
        uint256 elapsed,
        uint256 principal
    ) internal pure returns (uint256) {
        uint16 bps;
        if (elapsed < 60 days) bps = T1;
        else if (elapsed < 120 days) bps = T2;
        else if (elapsed < 200 days) bps = T3;
        else bps = T4;
        return (principal * bps) / BPS_DENOMINATOR;
    }

    function _distributeDeduction(
        address user,
        uint256 positionId,
        uint256 deduction
    ) internal {
        uint256 q = deduction / 4;
        uint256 deadAmount = q;
        uint256 founderAmount = q;
        uint256 poolAmount = q;
        uint256 lpAmount = deduction - deadAmount - founderAmount - poolAmount;

        token.safeTransfer(DEAD, deadAmount);
        token.safeTransfer(founderPoolWallet, founderAmount);
        token.safeTransfer(rewardsPool, poolAmount);
        token.safeTransfer(lpAccumulatorWallet, lpAmount);

        emit DeductionDistributed(
            user,
            positionId,
            deadAmount,
            founderAmount,
            poolAmount,
            lpAmount
        );
    }

    function isRouterPlanAllowed(uint8 planId) external view returns (bool) {
        PlanConfig memory cfg = plans[planId];
        return cfg.exists && cfg.active && cfg.routerAllowed;
    }

    function isDirectPlanAllowed(uint8 planId) external view returns (bool) {
        PlanConfig memory cfg = plans[planId];
        return cfg.exists && cfg.active && cfg.directAllowed;
    }

    function getPlanConfig(
        uint8 planId
    ) external view returns (PlanConfig memory) {
        return plans[planId];
    }

    function positionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function getPosition(
        address user,
        uint256 positionId
    )
        external
        view
        returns (
            uint256 principal,
            uint8 planId,
            uint64 stakedAt,
            uint32 lockPeriod,
            bool active
        )
    {
        require(positionId < positions[user].length, "SC: invalid position");
        Position memory p = positions[user][positionId];
        return (p.principal, p.planId, p.stakedAt, p.lockPeriod, p.active);
    }

    function getActivePositions(
        address user
    )
        external
        view
        returns (Position[] memory activePositions, uint256[] memory activeIds)
    {
        uint256 total = positions[user].length;
        uint256 count = 0;
        for (uint256 i = 0; i < total; i++) {
            if (positions[user][i].active) count++;
        }
        activePositions = new Position[](count);
        activeIds = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < total; i++) {
            if (positions[user][i].active) {
                activePositions[idx] = positions[user][i];
                activeIds[idx] = i;
                idx++;
            }
        }
    }

    function previewDeduction(
        address user,
        uint256 positionId
    ) external view returns (uint256 deduction, uint256 returned) {
        require(positionId < positions[user].length, "SC: invalid position");
        Position memory pos = positions[user][positionId];
        if (!pos.active) return (0, 0);
        uint256 elapsed = block.timestamp - uint256(pos.stakedAt);
        if (elapsed < uint256(pos.lockPeriod)) return (0, 0);
        deduction = _calculateDeduction(elapsed, pos.principal);
        returned = pos.principal - deduction;
    }

    function isUnlocked(
        address user,
        uint256 positionId
    ) external view returns (bool) {
        require(positionId < positions[user].length, "SC: invalid position");
        Position memory pos = positions[user][positionId];
        if (!pos.active) return false;
        return
            block.timestamp >= uint256(pos.stakedAt) + uint256(pos.lockPeriod);
    }
}
