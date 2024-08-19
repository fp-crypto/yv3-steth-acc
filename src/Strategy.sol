// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWETH} from "./interfaces/IWETH.sol";
import {IStEth} from "./interfaces/Lido/IStETH.sol";
import {IQueue} from "./interfaces/Lido/IQueue.sol";
import {ICurve} from "./interfaces/Curve/ICurve.sol";

contract Strategy is BaseHealthCheck {
    using SafeERC20 for ERC20;

    IWETH public constant WETH =
        IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IStEth public constant StETH =
        IStEth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    ICurve public constant CURVE_POOL =
        ICurve(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IQueue internal constant LIDO_WITHDRAWAL_QUEUE =
        IQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

    address private constant REFERRAL =
        0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;
    int128 private constant ETH_CRV_LP_IDX = 0;
    int128 private constant LST_CRV_LP_IDX = 1;

    uint96 public maxSingleTrade = 1_000e18;
    uint16 public maxSlippageBps = 500;

    constructor(
        address _asset,
        string memory _name
    ) BaseHealthCheck(_asset, _name) {}

    // Make eth receivable
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            Custom Views
    //////////////////////////////////////////////////////////////*/

    function estimatedTotalAssets() public view returns (uint256) {
        uint256 _lstBalance = StETH.balanceOf(address(this));
        _lstBalance =
            (_lstBalance * (MAX_BPS - uint256(maxSlippageBps))) /
            MAX_BPS;

        return asset.balanceOf(address(this)) + _lstBalance;
    }

    /*//////////////////////////////////////////////////////////////
                        BaseStrategy Overrides 
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        _amount = Math.min(_amount, maxSingleTrade);

        WETH.withdraw(_amount);

        uint256 _amountOut = CURVE_POOL.get_dy(
            ETH_CRV_LP_IDX,
            LST_CRV_LP_IDX,
            _amount
        );
        if (_amountOut < _amount && !StETH.isStakingPaused()) {
            StETH.submit{value: _amount}(REFERRAL);
        } else {
            CURVE_POOL.exchange{value: _amount}(
                ETH_CRV_LP_IDX,
                LST_CRV_LP_IDX,
                _amount,
                _amount
            );
        }
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // implement queue withdraw

        uint256 _slippageAllowance = (_amount *
            (MAX_BPS - uint256(maxSlippageBps))) / MAX_BPS;

        CURVE_POOL.exchange(
            LST_CRV_LP_IDX,
            ETH_CRV_LP_IDX,
            _amount,
            _slippageAllowance
        );

        WETH.deposit{value: address(this).balance}();
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        _tend(asset.balanceOf(address(this)));
        _totalAssets = estimatedTotalAssets();
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // TODO: something better?
        return asset.balanceOf(address(this)) + maxSingleTrade;
    }

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
     */
    function _tend(uint256 _totalIdle) internal override {
        if (_totalIdle > 0) {
            _deployFunds(_totalIdle);
        }
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
     */
    function _tendTrigger() internal view override returns (bool) {
        // TODO: Implement
        return false;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // TODO: needs more?
        _freeFunds(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                       Custom Management Methods 
    //////////////////////////////////////////////////////////////*/

    /// @notice Set maxSlippageBps to new value
    /// @param _maxSlippageBps new maxSlippageBps value
    function setMaxSlippageBps(uint16 _maxSlippageBps) external onlyManagement {
        require(_maxSlippageBps < MAX_BPS);
        maxSlippageBps = _maxSlippageBps;
    }

    /// @notice Set maxSingleTrade to new value
    /// @param _maxSingleTrade new maxSlippageBps value
    function setMaxSingleTrade(uint96 _maxSingleTrade) external onlyManagement {
        maxSingleTrade = _maxSingleTrade;
    }

    /// @notice Initiate a liquid staking token (LST) withdrawal process to redeem 1:1. Returns requestIds which can be used to claim asset into the strategy.
    /// @param _amounts the amounts of LST to initiate a withdrawal process for.
    function initiateLSTwithdrawal(
        uint256[] calldata _amounts
    ) external onlyManagement returns (uint256[] memory requestIds) {
        requestIds = LIDO_WITHDRAWAL_QUEUE.requestWithdrawals(
            _amounts,
            address(this)
        );
    }

    /// @notice Claim asset from a liquid staking token (LST) withdrawal process to redeem 1:1. Use the requestId from initiateLSTwithdrawal() as argument.
    /// @param _requestId return from calling initiateLSTwithdrawal() to identify the withdrawal.
    function claimLSTwithdrawal(uint256 _requestId) external onlyManagement {
        LIDO_WITHDRAWAL_QUEUE.claimWithdrawal(_requestId);
        WETH.deposit{value: address(this).balance}();
    }
}
