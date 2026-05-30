// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AIEFToken is ERC20, Ownable {

    /// @notice Hard-capped total supply. Minted once at construction to deployer.
    ///         No mint function exists — this number can never increase.
    uint256 public constant TOTAL_SUPPLY = 500_000_000e18;

    /// @notice Sell tax: 4% of every PancakeSwap sell. Always collected in full
    ///         from the seller regardless of burn floor status.
    uint16 public constant SELL_TAX_BPS = 400;

    /// @notice Sell tax split — each destination receives 25% of the 4% tax (= 1% of trade).
    ///         Note: SELL_LP_BPS is declared here for spec completeness and on-chain
    ///         transparency. The actual lpAmt in _transfer() is calculated as the
    ///         remainder (tax - burnAmt - rewardsAmt - founderAmt) to guarantee no
    ///         integer-division dust is ever stranded in the contract. The constant
    ///         documents the intended economic split; the remainder ensures exact delivery.
    uint16 public constant SELL_BURN_BPS = 2500;
    uint16 public constant SELL_REWARDS_BPS = 2500;
    uint16 public constant SELL_LP_BPS = 2500;
    uint16 public constant SELL_FOUNDER_BPS = 2500;

    /// @notice Transfer burn: 0.5% deducted from every non-exempt transfer.
    ///         BEHAVIOUR AT FLOOR: stops entirely — full amount transferred, nothing
    ///         sent to DEAD. Contrast with sell-tax burn share which routes to DEAD
    ///         after the floor (see _applyTransferBurn vs sell path in _transfer).
    uint16 public constant TRANSFER_BURN_BPS = 50;

    /// @notice Supply-reducing burns (_burn() calls) stop permanently once totalSupply()
    ///         reaches this value. 300M burned = 60% of total supply destroyed.
    ///         After floor: transfer burn stops entirely. Sell-tax burn share routes to DEAD.
    uint256 public constant BURN_FLOOR = 200_000_000e18;

    /// @notice 180-day DEX buy restriction window starting from enableTrading().
    ///         Cannot be extended after renounce. Expires automatically.
    uint32 public constant RESTRICTION_PERIOD = 180 days;

    /// @notice Permanent DEAD address for DEAD routing transfers (non-supply-reducing).
    ///         Tokens sent here are permanently inaccessible — no private key exists.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Basis-points denominator. All BPS calculations divide by this.
    ///         Named constant prevents magic-number errors (e.g. 1_000 vs 10_000).
    uint256 public constant BPS_DENOMINATOR = 10_000;


    /// @notice Founder Pool Wallet (dedicated Gnosis Safe).
    ///         Receives 25% of sell tax (1% of trade) on every DEX sell.
    ///         Accumulates founder revenue share — distributed equally to active
    ///         eligible founders off-chain via the backend cron.
    ///         Immutable — set once in constructor, never changeable.
    address public immutable founderPoolWallet;

    /// @notice LP Accumulator Wallet (Ops Safe controlled Gnosis Safe).
    ///         Receives 25% of sell tax (1% of trade) and 25% of exit deductions.
    ///         Ops Safe deploys accumulated AIEF as LP in batches — no auto-swap here.
    ///         Immutable — set once in constructor, never changeable.
    address public immutable lpAccumulatorWallet;

    /// @notice StakingRewardsPool contract address.
    ///         Receives 25% of sell tax (1% of trade) on every DEX sell.
    ///         NOT set in constructor — set via setStakingRewardsPool() post-deploy.
    ///         One-time setter: cannot be changed once set.
    address public rewardsPool;

    /// @notice PancakeSwap AIEF/USDT pair address.
    ///         Used in _transfer() to detect buy (from == dexPair) and sell (to == dexPair).
    ///         NOT set in constructor — set via setDexPair() after pair creation.
    ///         One-time setter: cannot be changed once set.
    address public dexPair;

    /// @notice True once enableTrading() is called. Required for any DEX buy to succeed.
    ///         Even whitelisted (isDexRestrictionExempt) addresses cannot buy before this.
    bool public tradingEnabled;

    /// @notice Timestamp after which direct public DEX buys are permitted.
    ///         Set to block.timestamp + RESTRICTION_PERIOD inside enableTrading().
    ///         NOT set in constructor.
    uint256 public restrictionEndTime;

    /// @notice True once BurnFloorReached event has been emitted.
    ///         Prevents repeated event emissions after the floor is reached.
    bool public burnFloorReachedEmitted;

    /// @notice Immutable record of the deployer address. Set once at construction.
    ///         Used by enableTrading() to enforce that the deployer exemption has
    ///         been removed before trading is activated — a contract-enforced gate
    ///         replacing a procedural checklist item.
    address public immutable deploymentWallet;


    /// @notice Exempt from 0.5% transfer burn AND from sell tax.
    ///         Protocol contracts must be exempt so stated percentages are
    ///         delivered exactly (e.g. partner receives exactly 95%, not 94.525%).
    ///
    ///         ⚠ SELL-TAX DISCLOSURE: burnExempt addresses that sell to dexPair
    ///         also bypass the 4% sell tax — PATH 2 returns before PATH 3 fires.
    ///         Protocol contracts (StakingContract, RewardsPool, etc.) never sell
    ///         to the DEX so this has no practical effect for them. Treasury Safe
    ///         and Ops Safe are burnExempt for exact-transfer accuracy on outflows —
    ///         any DEX sale from these addresses would be zero-tax. This is
    ///         intentional, visible on BSCScan source, and disclosed here explicitly.
    ///         No user wallet is in the permanent exempt list.
    ///
    ///         ⚠ SELL-TAX EXEMPTION NOTE (permanent after renounce):
    ///         isTransferBurnExempt shortcut fires BEFORE sell-tax logic.
    ///         Exempt addresses can transfer to dexPair without paying sell tax.
    ///         This is INTENTIONAL for LP seeding and protocol operations.
    ///         All permanently exempt addresses are protocol-controlled.
    ///         There are NO user wallets in the permanent exempt list.
    mapping(address => bool) public isTransferBurnExempt;

    /// @notice Exempt from the 180-day DEX buy restriction.
    ///         DappStakeRouter is the ONLY address that should have this flag set.
    ///         It is the sole authorized DEX buyer during the restriction window —
    ///         it swaps USDT→AIEF and immediately stakes for the user.
    ///         No other protocol contract, multisig, or user wallet should ever
    ///         receive dexExempt=true. Setting any other address dexExempt=true
    ///         would violate the controlled-launch promise.
    ///         ⚠ Does NOT bypass the tradingEnabled gate — nobody can buy before
    ///           enableTrading() is called, including DappStakeRouter.
    mapping(address => bool) public isDexRestrictionExempt;


    /// @notice Emitted once in the constructor. Permanently records the two
    ///         immutable fee destination addresses in the event log.
    ///         These addresses receive 1% of every sell transaction forever.
    ///         Visible on BSCScan without decoding constructor calldata — essential
    ///         for community transparency on the two most permanent fund destinations.
    event TokenDeployed(
        address indexed founderPoolWallet,
        address indexed lpAccumulatorWallet,
        address indexed deploymentWallet
    );

    /// @notice Emitted when enableTrading() is called. Records the exact timestamp
    ///         at which the restriction window expires. Backend monitors this.
    event TradingEnabled(uint256 restrictionEndTime);

    /// @notice Emitted when rewardsPool is set. One-time event.
    event RewardsPoolSet(address indexed pool);

    /// @notice Emitted when dexPair is set. One-time event.
    event DexPairSet(address indexed pair);

    /// @notice Emitted whenever an exemption is added or removed.
    ///         (false, false) = both exemptions removed (removeExempt).
    event ExemptionUpdated(
        address indexed addr,
        bool burnExempt,
        bool dexExempt
    );

    /// @notice Emitted exactly once when totalSupply() first reaches BURN_FLOOR.
    ///         After this event, supply-reducing burns (_burn()) cease permanently.
    ///         Transfer burn stops entirely; sell-tax burn share routes to DEAD.
    event BurnFloorReached(uint256 finalSupply);


    /// @notice Deploys the token, sets permanent destinations, mints total supply.
    ///
    ///         ⚠ DEPLOYMENT ORDER (Section 1.2 of Spec):
    ///         This contract is deployed FIRST. rewardsPool and dexPair are NOT
    ///         set here — they are set in steps 4 and 10 of the deployment sequence
    ///         via one-time setters. This avoids circular constructor dependencies.
    ///
    ///         ⚠ DEPLOYER WALLET REQUIREMENT:
    ///         Use a dedicated TEMPORARY deployer EOA — NOT the Ops Safe.
    ///         Reason: enableTrading() requires that deploymentWallet is no longer
    ///         in either exempt mapping. The Ops Safe is a PERMANENT exempt address
    ///         (per Spec Section 2.7) and can never be removed from exemptions.
    ///         If Ops Safe were the deployer, enableTrading() could never be called.
    ///         Correct flow: temporary EOA deploys → distributes tokens → step 13
    ///         removeExempt(temporaryEOA) → step 16 enableTrading() + renounce →
    ///         temporary EOA holds zero tokens and is discarded.
    ///
    /// @param founderPoolWallet_ Founder Pool Wallet — receives 1% on every sell.
    ///                             New dedicated Gnosis Safe — separate from Treasury Safe.
    ///                             Must be a deployed contract (code.length > 0).
    /// @param lpAccumulatorWallet_ LP Accumulator Wallet — receives 1% on every sell.
    ///                             Must be a deployed contract (code.length > 0).
    ///                             Open item O21 — must be confirmed before deployment.
    constructor(
        address founderPoolWallet_,
        address lpAccumulatorWallet_
    ) ERC20("AIEF", "AIEF") {
        require(founderPoolWallet_ != address(0), "AIEF: zero founder pool");
        require(lpAccumulatorWallet_ != address(0), "AIEF: zero LP wallet");
        require(
            founderPoolWallet_.code.length > 0,
            "AIEF: founder pool must be contract"
        );
        require(
            lpAccumulatorWallet_.code.length > 0,
            "AIEF: LP wallet must be contract"
        );

        founderPoolWallet = founderPoolWallet_;
        lpAccumulatorWallet = lpAccumulatorWallet_;
        deploymentWallet = msg.sender;

        _mint(msg.sender, TOTAL_SUPPLY);

        _setExempt(msg.sender, true, true);

        emit TokenDeployed(
            founderPoolWallet_,
            lpAccumulatorWallet_,
            msg.sender
        );
    }


    /// @notice Set the StakingRewardsPool address. Called at deployment step 4.
    ///         Cannot be changed once set — one-time setter.
    ///         Required before enableTrading() will succeed.
    ///
    ///         ⚠ Requires the address to be a deployed contract (code.length > 0).
    ///         Setting an EOA here would silently route sell-tax funds to an address
    ///         with no recovery mechanism after ownership is renounced.
    function setStakingRewardsPool(address pool) external onlyOwner {
        require(rewardsPool == address(0), "AIEF: already set");
        require(pool != address(0), "AIEF: zero address");
        require(pool.code.length > 0, "AIEF: pool must be a contract");
        rewardsPool = pool;
        emit RewardsPoolSet(pool);
    }

    /// @notice Set the PancakeSwap AIEF/USDT pair address. Called at deployment step 10.
    ///         Cannot be changed once set — one-time setter.
    ///         Required before enableTrading() will succeed.
    ///
    ///         ⚠ SECURITY: Rejects any address that is already marked exempt in either
    ///         mapping. Prevents the attack vector where setExempt(futurePairAddress)
    ///         is called before setDexPair(), which would silently bypass sell tax.
    ///
    ///         ⚠ Rejects founderPoolWallet, lpAccumulatorWallet, and rewardsPool.
    ///         All three are permanent fee destinations in the sell tax path. Setting
    ///         any of them as the pair would cause every sell to misroute permanently
    ///         with no recovery after renounce.
    ///
    ///         ⚠ Requires the address to be a deployed contract (code.length > 0).
    function setDexPair(address pair) external onlyOwner {
        require(dexPair == address(0), "AIEF: pair already set");
        require(pair != address(0), "AIEF: zero address");
        require(pair.code.length > 0, "AIEF: pair must be a contract");
        require(
            !isTransferBurnExempt[pair],
            "AIEF: pair cannot be burn-exempt"
        );
        require(
            !isDexRestrictionExempt[pair],
            "AIEF: pair cannot be dex-exempt"
        );
        require(pair != founderPoolWallet, "AIEF: pair cannot be founder pool");
        require(
            pair != lpAccumulatorWallet,
            "AIEF: pair cannot be LP accumulator"
        );
        require(pair != rewardsPool, "AIEF: pair cannot be rewards pool");
        dexPair = pair;
        emit DexPairSet(pair);
    }


    /// @notice Set exemption flags for an address.
    ///
    ///         ⚠ LOCKED AFTER enableTrading(): once tradingEnabled == true, this
    ///         function permanently reverts. All exemptions must be finalized before
    ///         enableTrading() is called. This makes the exemption list trustless —
    ///         the community can verify the final state before trading opens and know
    ///         it will never change.
    ///
    ///         burnExempt: exempt from 0.5% transfer burn. Set for all protocol
    ///                     contracts that receive or route tokens (exact amounts needed).
    ///         dexExempt:  exempt from 180-day DEX buy restriction. Set ONLY for
    ///                     DappStakeRouter — the sole authorized DEX buyer during launch.
    ///                     Do NOT set dexExempt=true for any other address unless there
    ///                     is a specific documented launch reason.
    function setExempt(
        address addr,
        bool burnExempt,
        bool dexExempt
    ) external onlyOwner {
        require(!tradingEnabled, "AIEF: exemptions locked");
        require(addr != address(0), "AIEF: zero address");
        _setExempt(addr, burnExempt, dexExempt);
    }

    /// @notice Remove all exemptions from an address.
    ///         CRITICAL: call this for the deployer wallet at step 13 before renounce.
    ///
    ///         ⚠ LOCKED AFTER enableTrading(): once tradingEnabled == true, this
    ///         function permanently reverts. Exemptions are frozen at trading enable.
    function removeExempt(address addr) external onlyOwner {
        require(!tradingEnabled, "AIEF: exemptions locked");
        require(addr != address(0), "AIEF: zero address");
        _setExempt(addr, false, false);
    }

    function _setExempt(
        address addr,
        bool burnExempt,
        bool dexExempt
    ) internal {
        if (dexPair != address(0) && addr == dexPair) {
            require(
                !burnExempt && !dexExempt,
                "AIEF: dexPair cannot be exempt"
            );
        }
        isTransferBurnExempt[addr] = burnExempt;
        isDexRestrictionExempt[addr] = dexExempt;
        emit ExemptionUpdated(addr, burnExempt, dexExempt);
    }


    /// @notice Activate trading and start the 180-day DEX restriction window.
    ///
    ///         ⚠ DEPLOYMENT CRITICAL (Spec Section 1.2, Step 16):
    ///         Call this function and renounceOwnership() back-to-back in a single
    ///         Hardhat/Foundry script via PRIVATE RPC. No manual pause between them.
    ///         No unrelated transactions between them.
    ///
    ///         Pre-flight assertions (run in script before calling):
    ///           assert rewardsPool  != address(0)
    ///           assert dexPair      != address(0)
    ///           assert owner()      == deployer
    ///           assert deployer NOT in either exempt mapping
    ///           assert all token allocations transferred correctly
    ///
    ///         Post-flight assertions (run in script after both calls):
    ///           assert tradingEnabled  == true
    ///           assert owner()         == address(0)
    ///           assert restrictionEndTime > block.timestamp
    ///
    ///         The 180-day restriction begins from block.timestamp at THIS call,
    ///         not from token deployment. Cannot be extended after renounce.
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "AIEF: already enabled");
        require(rewardsPool != address(0), "AIEF: rewardsPool not set");
        require(dexPair != address(0), "AIEF: dexPair not set");

        require(
            !isTransferBurnExempt[deploymentWallet] &&
                !isDexRestrictionExempt[deploymentWallet],
            "AIEF: deployer exemption not removed"
        );

        require(
            balanceOf(deploymentWallet) == 0,
            "AIEF: deployer must hold zero tokens"
        );

        tradingEnabled = true;
        restrictionEndTime = block.timestamp + RESTRICTION_PERIOD;

        emit TradingEnabled(restrictionEndTime);
    }


    /// @notice Overrides ERC20._transfer(). Every token movement passes through here.
    ///
    ///         ── DECISION TREE (evaluated in strict order) ───────────────────
    ///
    ///         PATH 0 — ZERO VALUE (amount == 0)
    ///           Bypasses all logic immediately via super._transfer(from, to, 0).
    ///           Ensures ERC-20 compatibility for zero-value transfers from any
    ///           address including dexPair before enableTrading() is called.
    ///
    ///         PATH 1 — DEX BUY (from == dexPair)
    ///           Checked FIRST, before any exemption shortcut.
    ///           Reason: even whitelisted DappStakeRouter must not bypass tradingEnabled.
    ///           a) require tradingEnabled — always enforced, no exception
    ///           b) if !isDexRestrictionExempt[to] → require block.timestamp >= restrictionEndTime
    ///           c) if isTransferBurnExempt[to] → super._transfer (no burn, no tax)
    ///           d) else → _applyTransferBurn (0.5% burn on received amount)
    ///
    ///         PATH 2 — NON-DEX EXEMPT (isTransferBurnExempt[from] || [to])
    ///           Protocol-to-protocol transfers (staking deposits, reward payouts, etc.)
    ///           → super._transfer, zero deduction. Exact amounts always delivered.
    ///
    ///         PATH 3 — DEX SELL (to == dexPair)
    ///           4% sell tax split into 4 parts:
    ///             burnAmt    = tax × 25%    → _burnFromSupply() pre-floor / DEAD routing post-floor
    ///             founderAmt = tax × 25%    → founderPoolWallet
    ///             rewardsAmt = tax × 25%    → rewardsPool
    ///             lpAmt      = tax remainder → lpAccumulatorWallet (absorbs integer dust)
    ///           Then _applyTransferBurn on the 96% net remainder.
    ///           Pre-floor effective sell cost: 4% + (0.5% × 96%) = 4.48% of gross amount.
    ///           At/after floor: transfer burn stops entirely. Only 4% sell tax is collected.
    ///
    ///         PATH 4 — WALLET-TO-WALLET
    ///           _applyTransferBurn only (0.5%, stops at floor)
    ///
    /// @param from   Token sender.
    /// @param to     Token recipient.
    /// @param amount Gross amount before any deduction.
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "AIEF: transfer from zero");
        require(to != address(0), "AIEF: transfer to zero");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if (from == dexPair) {
            require(tradingEnabled, "AIEF: trading not enabled");

            if (!isDexRestrictionExempt[to]) {
                require(
                    block.timestamp >= restrictionEndTime,
                    "AIEF: buy through dApp only"
                );
            }

            if (isTransferBurnExempt[to]) {
                super._transfer(from, to, amount);
                return;
            }

            _applyTransferBurn(from, to, amount);
            return;
        }

        if (isTransferBurnExempt[from] || isTransferBurnExempt[to]) {
            super._transfer(from, to, amount);
            return;
        }

        if (to == dexPair) {
            require(rewardsPool != address(0), "AIEF: rewardsPool not set");

            uint256 tax = (amount * SELL_TAX_BPS) / BPS_DENOMINATOR;
            uint256 burnAmt = (tax * SELL_BURN_BPS) / BPS_DENOMINATOR;
            uint256 rewardsAmt = (tax * SELL_REWARDS_BPS) / BPS_DENOMINATOR;
            uint256 founderAmt = (tax * SELL_FOUNDER_BPS) / BPS_DENOMINATOR;
            uint256 lpAmt = tax - burnAmt - rewardsAmt - founderAmt;

            uint256 actualBurned = _burnFromSupply(from, burnAmt);
            if (actualBurned < burnAmt) {
                uint256 deadRemainder = burnAmt - actualBurned;
                super._transfer(from, DEAD, deadRemainder);
            }

            super._transfer(from, founderPoolWallet, founderAmt);
            super._transfer(from, rewardsPool, rewardsAmt);
            super._transfer(from, lpAccumulatorWallet, lpAmt);

            uint256 netAfterTax = amount - tax;
            _applyTransferBurn(from, to, netAfterTax);
            return;
        }

        _applyTransferBurn(from, to, amount);
    }


    /// @notice Apply the 0.5% transfer burn to a transfer.
    ///
    ///         ── BEHAVIOUR DISTINCTION FROM SELL-TAX BURN SHARE ──────────────
    ///         Before 200M floor : burns 0.5% via _burn() (supply-reducing)
    ///         After  200M floor : burn SKIPPED ENTIRELY — full amount transferred
    ///                             Nothing goes to DEAD. No DEAD routing here.
    ///         This is different from the sell-tax burn share path which routes
    ///         the burn component to DEAD after the floor.
    ///
    /// @param from   Source address (tokens burned from here)
    /// @param to     Recipient of net-after-burn amount
    /// @param amount Gross amount to apply burn to
    function _applyTransferBurn(
        address from,
        address to,
        uint256 amount
    ) internal {
        uint256 requestedBurn = (amount * TRANSFER_BURN_BPS) / BPS_DENOMINATOR;
        uint256 actualBurn = _burnFromSupply(from, requestedBurn);
        super._transfer(from, to, amount - actualBurn);
    }

    /// @notice Calculate how many tokens can be burned without breaching BURN_FLOOR.
    ///         Returns 0 if supply is already at or below the floor.
    ///
    /// @param requested Amount we want to burn
    /// @return The actual burnable amount (may be less than requested near the floor)
    function _availableBurnAmount(
        uint256 requested
    ) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply <= BURN_FLOOR) return 0;
        uint256 maxBurn = supply - BURN_FLOOR;
        return requested > maxBurn ? maxBurn : requested;
    }

    /// @notice Attempt to burn `requested` tokens from `from`.
    ///         Caps the burn at the amount available before the floor.
    ///         Emits BurnFloorReached exactly once when floor is first reached.
    ///
    ///         Called by both _applyTransferBurn and the sell-tax burn share path.
    ///         Returns the actual amount burned (may be 0 or less than requested).
    ///
    /// @param from      Address to burn from
    /// @param requested Amount to attempt to burn
    /// @return burned   Actual amount burned
    function _burnFromSupply(
        address from,
        uint256 requested
    ) internal returns (uint256 burned) {
        burned = _availableBurnAmount(requested);
        if (burned == 0) return 0;

        _burn(from, burned);

        if (!burnFloorReachedEmitted && totalSupply() <= BURN_FLOOR) {
            burnFloorReachedEmitted = true;
            emit BurnFloorReached(totalSupply());
        }

        return burned;
    }


    /// @notice Returns true if the 180-day DEX restriction is currently active.
    ///         False means direct public buys are permitted.
    function isRestrictionActive() external view returns (bool) {
        return tradingEnabled && block.timestamp < restrictionEndTime;
    }

    /// @notice Returns how many seconds remain in the restriction window.
    ///         Returns 0 if restriction has expired or trading not yet enabled.
    function restrictionSecondsRemaining() external view returns (uint256) {
        if (!tradingEnabled || block.timestamp >= restrictionEndTime) return 0;
        return restrictionEndTime - block.timestamp;
    }

    /// @notice Returns how many tokens can still be burned before the floor.
    ///         Returns 0 once the floor has been reached.
    function remainingBurnCapacity() external view returns (uint256) {
        uint256 supply = totalSupply();
        return supply > BURN_FLOOR ? supply - BURN_FLOOR : 0;
    }


    /// @notice BEP-20 standard: 18 decimals.
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
