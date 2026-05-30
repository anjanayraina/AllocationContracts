// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AIEFToken is ERC20, Ownable {

    uint256 public constant TOTAL_SUPPLY = 500_000_000e18;

    uint16 public constant SELL_TAX_BPS = 400;

    uint16 public constant SELL_BURN_BPS = 2500;
    uint16 public constant SELL_REWARDS_BPS = 2500;
    uint16 public constant SELL_LP_BPS = 2500;
    uint16 public constant SELL_FOUNDER_BPS = 2500;

    uint16 public constant TRANSFER_BURN_BPS = 50;

    uint256 public constant BURN_FLOOR = 200_000_000e18;

    uint32 public constant RESTRICTION_PERIOD = 180 days;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable founderPoolWallet;

    address public immutable lpAccumulatorWallet;

    address public rewardsPool;

    address public dexPair;

    bool public tradingEnabled;

    uint256 public restrictionEndTime;

    bool public burnFloorReachedEmitted;

    address public immutable deploymentWallet;

    mapping(address => bool) public isTransferBurnExempt;

    mapping(address => bool) public isDexRestrictionExempt;

    event TokenDeployed(
        address indexed founderPoolWallet,
        address indexed lpAccumulatorWallet,
        address indexed deploymentWallet
    );

    event TradingEnabled(uint256 restrictionEndTime);

    event RewardsPoolSet(address indexed pool);

    event DexPairSet(address indexed pair);

    event ExemptionUpdated(
        address indexed addr,
        bool burnExempt,
        bool dexExempt
    );

    event BurnFloorReached(uint256 finalSupply);

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

    function setStakingRewardsPool(address pool) external onlyOwner {
        require(rewardsPool == address(0), "AIEF: already set");
        require(pool != address(0), "AIEF: zero address");
        require(pool.code.length > 0, "AIEF: pool must be a contract");
        rewardsPool = pool;
        emit RewardsPoolSet(pool);
    }

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

    function setExempt(
        address addr,
        bool burnExempt,
        bool dexExempt
    ) external onlyOwner {
        require(!tradingEnabled, "AIEF: exemptions locked");
        require(addr != address(0), "AIEF: zero address");
        _setExempt(addr, burnExempt, dexExempt);
    }

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

    function _applyTransferBurn(
        address from,
        address to,
        uint256 amount
    ) internal {
        uint256 requestedBurn = (amount * TRANSFER_BURN_BPS) / BPS_DENOMINATOR;
        uint256 actualBurn = _burnFromSupply(from, requestedBurn);
        super._transfer(from, to, amount - actualBurn);
    }

    function _availableBurnAmount(
        uint256 requested
    ) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply <= BURN_FLOOR) return 0;
        uint256 maxBurn = supply - BURN_FLOOR;
        return requested > maxBurn ? maxBurn : requested;
    }

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

    function isRestrictionActive() external view returns (bool) {
        return tradingEnabled && block.timestamp < restrictionEndTime;
    }

    function restrictionSecondsRemaining() external view returns (uint256) {
        if (!tradingEnabled || block.timestamp >= restrictionEndTime) return 0;
        return restrictionEndTime - block.timestamp;
    }

    function remainingBurnCapacity() external view returns (uint256) {
        uint256 supply = totalSupply();
        return supply > BURN_FLOOR ? supply - BURN_FLOOR : 0;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
