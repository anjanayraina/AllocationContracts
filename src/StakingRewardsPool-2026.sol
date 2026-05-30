// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract StakingRewardsPool is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;


    /// @notice Alert threshold. When pool balance falls at or below this value,
    ///         LowWaterMarkTriggered is emitted. Withdrawals are NEVER blocked.
    ///         Backend monitoring listens for this event and alerts the ops team.
    uint256 public constant LOW_WATER_MARK = 10_000_000e18;

    /// @notice EIP-712 type hash for the Claim struct.
    ///         Matches exactly:
    ///           Claim(address user,uint256 amount,uint256 nonce,uint256 issuedAt,uint256 expiry)
    ///         Field order must match abi.encode order in claimReward() exactly.
    ///         Any change to field names, types, or order invalidates all existing signatures.
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256(
            "Claim(address user,uint256 amount,uint256 nonce,uint256 issuedAt,uint256 expiry)"
        );

    /// @notice Maximum permitted signature validity window, measured from issuedAt to expiry.
    ///         Enforced in claimReward(): expiry - issuedAt <= MAX_SIGNATURE_VALIDITY.
    ///
    ///         Why issuedAt instead of block.timestamp:
    ///         Checking expiry <= block.timestamp + MAX_SIGNATURE_VALIDITY only constrains
    ///         the *remaining* validity at submission time. A signature issued at T=0 with
    ///         expiry=T+23h would pass that check if submitted at T=22h59m (1h remaining).
    ///         Using expiry - issuedAt caps the *total* validity window from issuance
    ///         regardless of when the signature is submitted.
    ///
    ///         Backend should target much shorter windows (e.g. 15 minutes) — 1 hour is a ceiling.
    uint256 public constant MAX_SIGNATURE_VALIDITY = 1 hours;

    /// @notice Maximum AIEF that can be claimed in a single claimReward() call.
    ///         Limits damage from backend bugs, signer compromise, decimal errors,
    ///         or accidentally oversized signed claims. Legitimate larger payouts
    ///         must be split across multiple claims.
    ///         Immutable — cannot be adjusted by Ops Safe or anyone else.
    uint256 public constant MAX_CLAIM_AMOUNT = 50_000e18;

    /// @notice Minimum time between successive claimReward() calls per wallet.
    ///         Aligns with the 12-hour staking ROI cron cycle — no legitimate user
    ///         should need to claim more often. Prevents rapid pool drain even if
    ///         an attacker holds a valid signer key.
    ///         Immutable — cannot be adjusted by Ops Safe or anyone else.
    uint256 public constant CLAIM_COOLDOWN = 12 hours;


    /// @notice AIEF token contract. Set in constructor — never changeable.
    IERC20 public immutable token;

    /// @notice Ops Safe multisig (3-of-5 Gnosis Safe).
    ///         The only address that can call admin functions.
    ///         Cannot extract pool balance — no such function exists.
    address public immutable opsSafe;

    /// @notice Backend EIP-712 signing key.
    ///         Rotatable by Ops Safe via updateSigner().
    ///         After rotation, all in-flight signatures from the old key are
    ///         immediately invalid — backend must re-sign pending claims.
    address public signer;

    /// @notice Emergency pause for claimReward().
    ///         Set by Ops Safe via pauseClaims(). Does NOT affect
    ///         StakingContract.unstake() — principal withdrawal is always independent.
    bool public claimsPaused;

    /// @notice Per-user claim nonce. Starts at 0, increments by 1 on every
    ///         successful claimReward() call. Backend reads this before signing.
    ///         Replay protection: contract requires nonce == userNonce[msg.sender].
    mapping(address => uint256) public userNonce;

    /// @notice Timestamp of each user's most recent successful claimReward() call.
    ///         Used to enforce CLAIM_COOLDOWN between successive claims.
    ///         Starts at 0 (never claimed). Public — dApp reads for UX display.
    mapping(address => uint256) public lastClaimAt;


    /// @notice Emitted on every successful claim. Indexed by user for backend
    ///         confirmation that the on-chain claim was processed.
    ///         issuedAt and expiry together record the complete validity window
    ///         so the backend can reconstruct the signing context from on-chain
    ///         data alone without correlating against off-chain signing logs.
    event RewardClaimed(
        address indexed user,
        uint256 amount,
        uint256 nonce,
        uint256 issuedAt,
        uint256 expiry
    );

    /// @notice Emitted when pool balance falls at or below LOW_WATER_MARK.
    ///         Does not block withdrawals. Backend monitors and alerts ops team.
    ///         ⚠ Emitted on EVERY claim while balance remains at or below the mark —
    ///         not just once. Backend monitoring must handle repeated events and
    ///         deduplicate alerts rather than treating each emission as a new event.
    event LowWaterMarkTriggered(uint256 remainingBalance);

    /// @notice Emitted when claims are paused or unpaused by Ops Safe.
    event ClaimsPauseStateChanged(bool paused);

    /// @notice Emitted when the backend signing key is rotated.
    ///         Old key is invalid immediately after this event.
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);


    modifier onlyOpsSafe() {
        require(msg.sender == opsSafe, "SRP: only Ops Safe");
        _;
    }


    /// @notice Deploys the pool. Called at deployment step 2 (Spec Section 1.2).
    ///         400,000,000 AIEF is transferred to this contract at step 12.
    ///
    ///         ⚠ DEPLOYMENT NOTE:
    ///         This contract is deployed before StakingContract and
    ///         EcosystemPaymentContract. Its address is passed as a constructor
    ///         argument to both of those contracts.
    ///
    /// @param token_   AIEF token contract address (deployed at step 1)
    /// @param opsSafe_ Ops Safe multisig — permanent admin address
    /// @param signer_  Initial backend EIP-712 signing key (open item O10)
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


    /// @notice Claim a signed reward amount. The only function that moves tokens
    ///         out of this contract.
    ///
    ///         ── HOW IT WORKS ────────────────────────────────────────────────
    ///         1. User accumulates income in the off-chain Income Wallet ledger
    ///         2. User selects a Stage 1 speed (30/20/10/instant days)
    ///         3. Backend applies the Stage 1 deduction off-chain and credits
    ///            the net amount to the off-chain Hot Wallet ledger
    ///         4. User requests Stage 2 withdrawal from Hot Wallet
    ///         5. Backend validates daily cap, signs (user, amount, nonce, issuedAt, expiry)
    ///         6. User submits the signature here — receives 100% of amount
    ///
    ///         ── STAGE 2 FEE: ZERO ───────────────────────────────────────────
    ///         The signed `amount` is exactly what the user receives.
    ///         No burn. No deduction. No fee. The EIP-712 signature is used
    ///         for authorisation and replay protection only — not as a fee event.
    ///
    ///         ── SIGNATURE VALIDITY WINDOW ───────────────────────────────────
    ///         Validity is measured from issuedAt to expiry (total window),
    ///         not from block.timestamp to expiry (remaining window).
    ///         This prevents a signature issued far in the past from passing
    ///         a remaining-time check during its final hour.
    ///
    ///         ── CEI PATTERN ─────────────────────────────────────────────────
    ///         Checks  : paused / issuedAt / expiry / window / cooldown /
    ///                   nonce / amount / maxClaim / balance / signature
    ///         Effects : userNonce[msg.sender]++ AND lastClaimAt updated (BEFORE transfer)
    ///         Interactions: token.safeTransfer(msg.sender, amount)
    ///
    /// @param amount    Exact AIEF amount to receive — must be > 0 and <= MAX_CLAIM_AMOUNT (50,000 AIEF)
    /// @param nonce     Must equal userNonce[msg.sender] exactly
    /// @param issuedAt  Unix timestamp when backend signed this claim — must be <= block.timestamp
    /// @param expiry    Unix timestamp after which signature is invalid
    ///                  Must satisfy: expiry > issuedAt AND expiry - issuedAt <= MAX_SIGNATURE_VALIDITY
    /// @param signature EIP-712 signature from the authorised backend signer
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


    /// @notice Pause or unpause claimReward(). Emergency use only.
    ///
    ///         ⚠ This pause ONLY affects claimReward().
    ///         StakingContract.unstake() is completely independent — matured
    ///         principal withdrawal can never be blocked by this flag.
    ///
    /// @param paused True to pause claims, false to unpause.
    function pauseClaims(bool paused) external onlyOpsSafe {
        require(claimsPaused != paused, "SRP: same pause state");
        claimsPaused = paused;
        emit ClaimsPauseStateChanged(paused);
    }

    /// @notice Rotate the backend EIP-712 signing key.
    ///
    ///         After this call, all signatures from the old key are immediately
    ///         invalid. The backend must discard all pending unsigned claim
    ///         requests and re-sign with the new key. Any user who received
    ///         a signature before rotation must request a new one.
    ///
    ///         Use case: scheduled key rotation, suspected compromise, or
    ///         backend infrastructure migration.
    ///
    /// @param newSigner New backend signing address (open item O10)
    function updateSigner(address newSigner) external onlyOpsSafe {
        require(newSigner != address(0), "SRP: zero signer");
        require(newSigner != signer, "SRP: same signer");
        address oldSigner = signer;
        signer = newSigner;
        emit SignerUpdated(oldSigner, newSigner);
    }


    /// @notice Current pool balance. Primary health indicator — monitored by
    ///         backend daily reconciliation against total outstanding liability.
    function poolBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice Returns the next nonce the backend must sign for a given user.
    ///         Backend reads this before constructing the EIP-712 message.
    ///         Always equals userNonce[user] — convenience alias.
    function nextNonce(address user) external view returns (uint256) {
        return userNonce[user];
    }

    /// @notice Returns true if pool balance is at or below LOW_WATER_MARK.
    ///         Convenience check for backend health monitoring.
    function isLowWater() external view returns (bool) {
        return token.balanceOf(address(this)) <= LOW_WATER_MARK;
    }

    /// @notice Compute the EIP-712 digest for a claim without submitting it.
    ///
    ///         Primary use: backend signature debugging and integration testing.
    ///         The backend constructs the same digest locally, signs it with the
    ///         signer key, and compares the result of ECDSA.recover(digest, sig)
    ///         against the expected signer address before sending to the user.
    ///         If the backend digest and this function's output disagree, there
    ///         is a typehash mismatch, field-order bug, or domain separator issue.
    ///
    ///         Also useful for dApp pre-flight: call hashClaim() then recover
    ///         the signer off-chain to confirm signature validity before the
    ///         user pays gas.
    ///
    /// @param user     Wallet address that will call claimReward()
    /// @param amount   Claim amount
    /// @param nonce    Must equal userNonce[user] at time of submission
    /// @param issuedAt Timestamp when the backend signed the claim
    /// @param expiry   Timestamp after which the signature is invalid
    /// @return digest  The EIP-712 typed-data hash the signer must sign
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
