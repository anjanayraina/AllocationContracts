// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract StakingRewardsPool is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    uint256 public constant LOW_WATER_MARK = 10_000_000e18;

    bytes32 public constant CLAIM_TYPEHASH =
        keccak256(
            "Claim(address user,uint256 amount,uint256 nonce,uint256 issuedAt,uint256 expiry)"
        );

    uint256 public constant MAX_SIGNATURE_VALIDITY = 1 hours;

    uint256 public constant MAX_CLAIM_AMOUNT = 50_000e18;

    uint256 public constant CLAIM_COOLDOWN = 12 hours;

    IERC20 public immutable token;

    address public immutable opsSafe;

    address public signer;

    bool public claimsPaused;

    mapping(address => uint256) public userNonce;

    mapping(address => uint256) public lastClaimAt;

    event RewardClaimed(
        address indexed user,
        uint256 amount,
        uint256 nonce,
        uint256 issuedAt,
        uint256 expiry
    );

    event LowWaterMarkTriggered(uint256 remainingBalance);

    event ClaimsPauseStateChanged(bool paused);

    event SignerUpdated(address indexed oldSigner, address indexed newSigner);

    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "SRP: only Ops Safe");
        _;
    }

    constructor(
        address token_,
        address opsSafe_,
        address signer_
    ) EIP712("AIEFStakingRewards", "1") {
        require(token_ != address(0), "SRP: zero token");
        require(opsSafe_ != address(0), "SRP: zero ops safe");
        require(signer_ != address(0), "SRP: zero signer");
        require(token_.code.length > 0, "SRP: token must be a contract");
        require(opsSafe_.code.length > 0, "SRP: ops safe must be a contract");

        token = IERC20(token_);
        opsSafe = opsSafe_;
        signer = signer_;
    }

    function claimReward(
        uint256 amount,
        uint256 nonce,
        uint256 issuedAt,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant {

        require(!claimsPaused, "SRP: claims paused");

        require(issuedAt <= block.timestamp, "SRP: issued in future");

        require(expiry > issuedAt, "SRP: invalid expiry");

        require(
            expiry - issuedAt <= MAX_SIGNATURE_VALIDITY,
            "SRP: expiry window too long"
        );

        require(block.timestamp <= expiry, "SRP: signature expired");

        require(
            block.timestamp >= lastClaimAt[msg.sender] + CLAIM_COOLDOWN,
            "SRP: claim cooldown active"
        );

        require(nonce == userNonce[msg.sender], "SRP: invalid nonce");
        require(amount > 0, "SRP: zero amount");

        require(amount <= MAX_CLAIM_AMOUNT, "SRP: claim too large");

        require(
            token.balanceOf(address(this)) >= amount,
            "SRP: insufficient pool balance"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_TYPEHASH,
                msg.sender,
                amount,
                nonce,
                issuedAt,
                expiry
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        address recovered = ECDSA.recover(digest, signature);
        require(recovered == signer, "SRP: invalid signature");

        userNonce[msg.sender]++;
        lastClaimAt[msg.sender] = block.timestamp;

        token.safeTransfer(msg.sender, amount);

        uint256 remaining = token.balanceOf(address(this));
        if (remaining <= LOW_WATER_MARK) {
            emit LowWaterMarkTriggered(remaining);
        }

        emit RewardClaimed(msg.sender, amount, nonce, issuedAt, expiry);
    }

    function pauseClaims(bool paused) external onlyOpsSafe {
        require(claimsPaused != paused, "SRP: same pause state");
        claimsPaused = paused;
        emit ClaimsPauseStateChanged(paused);
    }

    function updateSigner(address newSigner) external onlyOpsSafe {
        require(newSigner != address(0), "SRP: zero signer");
        require(newSigner != signer, "SRP: same signer");
        address oldSigner = signer;
        signer = newSigner;
        emit SignerUpdated(oldSigner, newSigner);
    }

    function poolBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function nextNonce(address user) external view returns (uint256) {
        return userNonce[user];
    }

    function isLowWater() external view returns (bool) {
        return token.balanceOf(address(this)) <= LOW_WATER_MARK;
    }

    function hashClaim(
        address user,
        uint256 amount,
        uint256 nonce,
        uint256 issuedAt,
        uint256 expiry
    ) external view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(CLAIM_TYPEHASH, user, amount, nonce, issuedAt, expiry)
        );
        return _hashTypedDataV4(structHash);
    }
}
