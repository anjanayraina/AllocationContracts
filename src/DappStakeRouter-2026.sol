// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

interface IStakingContract {
    function stakeFor(
        address beneficiary,
        uint256 amount,
        uint8 planId
    ) external returns (uint256 positionId);

    function isRouterPlanAllowed(uint8 planId) external view returns (bool);
}

contract DappStakeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint16 public constant MIN_SLIPPAGE_BPS = 50;

    uint16 public constant MAX_SLIPPAGE_BPS = 1_000;

    uint16 public constant DEFAULT_SLIPPAGE_BPS = 200;

    uint256 public constant MAX_DEADLINE_WINDOW = 30 minutes;

    IERC20 public immutable token;

    IERC20 public immutable usdt;

    IPancakeRouter public immutable pancakeRouter;

    IStakingContract public immutable stakingContract;

    address public immutable opsSafe;

    uint256 public immutable ABSOLUTE_MAX_USDT;

    uint256 public immutable USDT_UNIT;

    uint256 public minUsdtPerStake;

    uint256 public maxUsdtPerStake;

    uint16 public slippageBps;

    bool public paused;

    event Staked(
        address indexed staker,
        uint256 usdtIn,
        uint256 aiefStaked,
        uint8 planId,
        uint256 positionId
    );

    event SlippageUpdated(uint16 oldBps, uint16 newBps);

    event UsdtLimitsUpdated(uint256 newMin, uint256 newMax);

    event RouterPauseStateChanged(bool paused);

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "DSR: only Ops Safe");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "DSR: paused");
        _;
    }

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

        uint8 decimals = IERC20Metadata(usdt_).decimals();
        uint256 unit = 10 ** uint256(decimals);

        USDT_UNIT = unit;
        ABSOLUTE_MAX_USDT = 100_000 * unit;
        minUsdtPerStake = 1 * unit;
        maxUsdtPerStake = 10_000 * unit;

        token = IERC20(token_);
        usdt = IERC20(usdt_);
        pancakeRouter = IPancakeRouter(pancakeRouter_);
        stakingContract = IStakingContract(stakingContract_);
        opsSafe = opsSafe_;
        slippageBps = DEFAULT_SLIPPAGE_BPS;
    }

    function stake(
        uint256 usdtIn,
        uint8 planId,
        uint256 minAiefOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 positionId) {

        require(usdtIn >= minUsdtPerStake, "DSR: below minimum");
        require(usdtIn <= maxUsdtPerStake, "DSR: above maximum");
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

        uint256 usdtBefore = usdt.balanceOf(address(this));
        uint256 aiefBefore = token.balanceOf(address(this));

        usdt.safeTransferFrom(msg.sender, address(this), usdtIn);
        require(
            usdt.balanceOf(address(this)) == usdtBefore + usdtIn,
            "DSR: USDT not received"
        );

        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(token);

        usdt.forceApprove(address(pancakeRouter), usdtIn);

        pancakeRouter.swapExactTokensForTokens(
            usdtIn,
            minAiefOut,
            path,
            address(this),
            deadline
        );

        uint256 aiefReceived = token.balanceOf(address(this)) - aiefBefore;
        require(aiefReceived > 0, "DSR: zero AIEF received");
        require(aiefReceived >= minAiefOut, "DSR: insufficient AIEF received");

        usdt.forceApprove(address(pancakeRouter), 0);

        token.forceApprove(address(stakingContract), aiefReceived);

        positionId = stakingContract.stakeFor(msg.sender, aiefReceived, planId);

        token.forceApprove(address(stakingContract), 0);

        require(usdt.balanceOf(address(this)) == usdtBefore, "DSR: USDT delta");
        require(
            token.balanceOf(address(this)) == aiefBefore,
            "DSR: AIEF delta"
        );

        emit Staked(msg.sender, usdtIn, aiefReceived, planId, positionId);
    }

    function setSlippage(uint16 newBps) external onlyOpsSafe {
        require(newBps >= MIN_SLIPPAGE_BPS, "DSR: slippage too low");
        require(newBps <= MAX_SLIPPAGE_BPS, "DSR: slippage too high");
        require(newBps != slippageBps, "DSR: same slippage");
        uint16 old = slippageBps;
        slippageBps = newBps;
        emit SlippageUpdated(old, newBps);
    }

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

    function pause(bool paused_) external onlyOpsSafe {
        require(paused != paused_, "DSR: same pause state");
        paused = paused_;
        emit RouterPauseStateChanged(paused_);
    }

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

    function contractBalances()
        external
        view
        returns (uint256 usdtBalance, uint256 aiefBalance)
    {
        return (usdt.balanceOf(address(this)), token.balanceOf(address(this)));
    }
}
