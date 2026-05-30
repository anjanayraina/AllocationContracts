// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract EcosystemPaymentContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint16 public constant DEAD_BPS = 300;
    uint16 public constant POOL_BPS = 100;
    uint16 public constant TREASURY_BPS = 100;
    uint16 public constant PARTNER_BPS = 9_500;

    uint256 public constant MAX_NAME_LENGTH = 64;

    uint256 public constant MAX_METADATA_LENGTH = 256;

    struct Partner {
        address payoutWallet;
        bool active;
        string name;
        uint256 totalVolume;
        uint64 registeredAt;
    }

    IERC20 public immutable token;

    address public immutable rewardsPool;

    address public immutable treasurySafe;

    address public immutable opsSafe;

    mapping(address => Partner) public partners;

    address[] public partnerList;

    uint256 public totalVolume;

    uint256 public totalDeadRouted;

    event PaymentProcessed(
        address indexed payer,
        address indexed partnerKey,
        uint256 grossAmount,
        uint256 partnerAmount,
        uint256 poolAmount,
        uint256 treasuryAmount,
        uint256 deadAmount,
        bytes32 serviceId,
        string metadata
    );

    event PartnerRegistered(
        address indexed partnerKey,
        address payoutWallet,
        string name,
        uint64 registeredAt
    );

    event PartnerUpdated(address indexed partnerKey, bool active);

    event PartnerWalletUpdated(
        address indexed partnerKey,
        address oldWallet,
        address newWallet
    );

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "EPC: only Ops Safe");
        _;
    }

    constructor(
        address token_,
        address rewardsPool_,
        address treasurySafe_,
        address opsSafe_
    ) {
        require(token_ != address(0), "EPC: zero token");
        require(rewardsPool_ != address(0), "EPC: zero pool");
        require(treasurySafe_ != address(0), "EPC: zero treasury");
        require(opsSafe_ != address(0), "EPC: zero ops safe");

        require(token_.code.length > 0, "EPC: token not a contract");
        require(rewardsPool_.code.length > 0, "EPC: pool not a contract");
        require(treasurySafe_.code.length > 0, "EPC: treasury not a contract");
        require(opsSafe_.code.length > 0, "EPC: ops safe not a contract");

        token = IERC20(token_);
        rewardsPool = rewardsPool_;
        treasurySafe = treasurySafe_;
        opsSafe = opsSafe_;
    }

    function processPayment(
        address payer,
        address partnerKey,
        uint256 amount,
        bytes32 serviceId,
        string calldata metadata
    ) external nonReentrant {

        require(payer != address(0), "EPC: zero payer");
        require(msg.sender == payer, "EPC: caller must be payer");
        require(partnerKey != address(0), "EPC: zero partner key");
        require(amount > 0, "EPC: zero amount");
        require(partners[partnerKey].active, "EPC: partner not active");
        require(
            bytes(metadata).length <= MAX_METADATA_LENGTH,
            "EPC: metadata too long"
        );

        Partner storage p = partners[partnerKey];

        require(
            token.allowance(payer, address(this)) == amount,
            "EPC: exact allowance required"
        );

        token.safeTransferFrom(payer, address(this), amount);

        uint256 deadAmount = (amount * DEAD_BPS) / BPS_DENOMINATOR;
        uint256 poolAmount = (amount * POOL_BPS) / BPS_DENOMINATOR;
        uint256 treasuryAmt = (amount * TREASURY_BPS) / BPS_DENOMINATOR;
        uint256 partnerAmount = amount - deadAmount - poolAmount - treasuryAmt;

        token.safeTransfer(DEAD, deadAmount);
        token.safeTransfer(rewardsPool, poolAmount);
        token.safeTransfer(treasurySafe, treasuryAmt);
        token.safeTransfer(p.payoutWallet, partnerAmount);

        p.totalVolume += amount;
        totalVolume += amount;
        totalDeadRouted += deadAmount;

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

    function registerPartner(
        address partnerKey,
        address payoutWallet,
        string calldata name
    ) external onlyOpsSafe {
        require(partnerKey != address(0), "EPC: zero partner key");
        require(payoutWallet != address(0), "EPC: zero payout wallet");
        require(payoutWallet != DEAD, "EPC: dead payout wallet");
        require(bytes(name).length > 0, "EPC: empty name");
        require(bytes(name).length <= MAX_NAME_LENGTH, "EPC: name too long");
        require(
            !partners[partnerKey].active &&
                partners[partnerKey].registeredAt == 0,
            "EPC: already registered"
        );

        uint64 registeredAt = uint64(block.timestamp);
        partners[partnerKey] = Partner({
            payoutWallet: payoutWallet,
            active: true,
            name: name,
            totalVolume: 0,
            registeredAt: registeredAt
        });
        partnerList.push(partnerKey);

        emit PartnerRegistered(partnerKey, payoutWallet, name, registeredAt);
    }

    function setPartnerActive(
        address partnerKey,
        bool active
    ) external onlyOpsSafe {
        require(
            partners[partnerKey].registeredAt > 0,
            "EPC: partner not registered"
        );
        require(partners[partnerKey].active != active, "EPC: same status");
        partners[partnerKey].active = active;
        emit PartnerUpdated(partnerKey, active);
    }

    function updatePartnerWallet(
        address partnerKey,
        address newWallet
    ) external onlyOpsSafe {
        require(
            partners[partnerKey].registeredAt > 0,
            "EPC: partner not registered"
        );
        require(newWallet != address(0), "EPC: zero wallet");
        require(newWallet != DEAD, "EPC: dead payout wallet");
        require(
            newWallet != partners[partnerKey].payoutWallet,
            "EPC: same wallet"
        );

        address oldWallet = partners[partnerKey].payoutWallet;
        partners[partnerKey].payoutWallet = newWallet;

        emit PartnerWalletUpdated(partnerKey, oldWallet, newWallet);
    }

    function partnerCount() external view returns (uint256) {
        return partnerList.length;
    }

    function isActivePartner(address partnerKey) external view returns (bool) {
        return partners[partnerKey].active;
    }

    function getPartner(
        address partnerKey
    )
        external
        view
        returns (
            address payoutWallet,
            bool active,
            string memory name,
            uint256 volume,
            uint64 registeredAt
        )
    {
        Partner memory p = partners[partnerKey];
        return (
            p.payoutWallet,
            p.active,
            p.name,
            p.totalVolume,
            p.registeredAt
        );
    }

    function contractBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
