// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IStakingContract {
    function stakeFor(
        address beneficiary,
        uint256 amount,
        uint8 planId
    ) external returns (uint256 positionId);
}

contract FounderAllocationContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    IStakingContract public immutable stakingContract;

    address public immutable opsSafe;

    uint8 public immutable founderPlanId;

    uint256 public immutable maxFounders;

    uint256 public immutable maxAllocationPerFounder;

    uint256 public immutable campaignEndTime;

    address public immutable remainderWallet;

    uint256 public founderCount;

    uint256 public totalAllocated;

    mapping(address => bool) public registeredFounders;

    struct FounderInfo {
        uint256 founderNumber;
        uint256 allocatedAmount;
        uint256 positionId;
        uint64 registeredAt;
    }

    mapping(address => FounderInfo) public founderInfo;

    event FounderRegistered(
        address indexed founderWallet,
        uint256 founderNumber,
        uint256 amount,
        uint256 positionId,
        uint64 registeredAt
    );

    event FounderContractDeployed(
        address indexed token,
        address indexed stakingContract,
        address indexed opsSafe,
        uint8 founderPlanId,
        uint256 maxFounders,
        uint256 maxAllocationPerFounder,
        uint256 campaignEndTime,
        address remainderWallet
    );

    event RemainderTransferred(address indexed destination, uint256 amount);

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "FAC: only Ops Safe");
        _;
    }

    constructor(
        address token_,
        address stakingContract_,
        address opsSafe_,
        uint8 founderPlanId_,
        uint256 maxFounders_,
        uint256 maxAllocationPerFounder_,
        uint256 campaignEndTime_,
        address remainderWallet_
    ) {
        require(token_ != address(0), "FAC: zero token");
        require(stakingContract_ != address(0), "FAC: zero staking contract");
        require(opsSafe_ != address(0), "FAC: zero ops safe");
        require(remainderWallet_ != address(0), "FAC: zero remainder wallet");
        require(maxFounders_ > 0, "FAC: zero max founders");
        require(
            maxAllocationPerFounder_ >= 1e18,
            "FAC: invalid allocation cap"
        );
        require(
            campaignEndTime_ > block.timestamp,
            "FAC: invalid campaign end"
        );

        require(token_.code.length > 0, "FAC: token not a contract");
        require(
            stakingContract_.code.length > 0,
            "FAC: staking not a contract"
        );
        require(opsSafe_.code.length > 0, "FAC: ops safe not a contract");
        require(
            remainderWallet_.code.length > 0,
            "FAC: remainder wallet not a contract"
        );

        token = IERC20(token_);
        stakingContract = IStakingContract(stakingContract_);
        opsSafe = opsSafe_;
        founderPlanId = founderPlanId_;
        maxFounders = maxFounders_;
        maxAllocationPerFounder = maxAllocationPerFounder_;
        campaignEndTime = campaignEndTime_;
        remainderWallet = remainderWallet_;

        emit FounderContractDeployed(
            token_,
            stakingContract_,
            opsSafe_,
            founderPlanId_,
            maxFounders_,
            maxAllocationPerFounder_,
            campaignEndTime_,
            remainderWallet_
        );
    }

    function registerFounder(
        address founderWallet,
        uint256 approvedAmount
    ) external onlyOpsSafe nonReentrant {

        require(founderWallet != address(0), "FAC: zero wallet");
        require(block.timestamp < campaignEndTime, "FAC: campaign ended");
        require(founderCount < maxFounders, "FAC: all seats filled");
        require(!registeredFounders[founderWallet], "FAC: already registered");
        require(approvedAmount >= 1e18, "FAC: below min stake");
        require(
            approvedAmount <= maxAllocationPerFounder,
            "FAC: above allocation cap"
        );
        require(
            token.balanceOf(address(this)) >= approvedAmount,
            "FAC: insufficient pool balance"
        );

        registeredFounders[founderWallet] = true;
        founderCount++;
        uint256 thisFounderNumber = founderCount;
        uint64 registeredAt = uint64(block.timestamp);
        totalAllocated += approvedAmount;

        founderInfo[founderWallet].founderNumber = thisFounderNumber;
        founderInfo[founderWallet].allocatedAmount = approvedAmount;
        founderInfo[founderWallet].registeredAt = registeredAt;

        token.forceApprove(address(stakingContract), approvedAmount);

        uint256 positionId = stakingContract.stakeFor(
            founderWallet,
            approvedAmount,
            founderPlanId
        );

        token.forceApprove(address(stakingContract), 0);

        founderInfo[founderWallet].positionId = positionId;

        emit FounderRegistered(
            founderWallet,
            thisFounderNumber,
            approvedAmount,
            positionId,
            registeredAt
        );
    }

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

    function poolBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function seatsRemaining() external view returns (uint256) {
        return maxFounders - founderCount;
    }

    function campaignEnded() external view returns (bool) {
        return
            founderCount == maxFounders || block.timestamp >= campaignEndTime;
    }

    function isFounder(address wallet) external view returns (bool) {
        return registeredFounders[wallet];
    }

    function getFounderInfo(
        address wallet
    )
        external
        view
        returns (
            uint256 founderNum,
            uint256 allocatedAmount,
            uint256 positionId,
            uint64 registeredAt
        )
    {
        FounderInfo memory f = founderInfo[wallet];
        return (
            f.founderNumber,
            f.allocatedAmount,
            f.positionId,
            f.registeredAt
        );
    }
}
