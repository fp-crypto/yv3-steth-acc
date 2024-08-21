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

    uint16 public maxTendBasefeeGwei = 1; // 1 gwei
    uint96 public maxSingleTrade = 1_000e18;
    uint16 public maxSlippageBps = 100;
    uint16 public lstDiscountBps = 50;
    uint8 public lstOutstandingWithdrawCount;

    bool public openDeposits;
    uint256 public depositLimit;
    mapping(address => bool) public allowedDepositors;

    constructor(
        string memory _name
    ) BaseHealthCheck(address(WETH), _name) {}

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
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        if (lstOutstandingWithdrawCount != 0) return;

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
                _amountOut
            );
        }
    }

    /**
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {

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
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     */
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (!openDeposits && !allowedDepositors[_owner]) return 0;

        uint256 _totalAssets = TokenizedStrategy.totalAssets();
        return _totalAssets >= depositLimit ? 0 : depositLimit - _totalAssets;
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
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
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     */
    function _tend(uint256 _totalIdle) internal override {
        if (_totalIdle > 0) {
            _deployFunds(_totalIdle);
        }
    }

    /**
     * @return . Should return true if tend() should be called by keeper or false if not.
     */
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.totalAssets() == 0) {
            return false;
        }

        uint256 _maxTendBasefeeGwei = uint256(maxTendBasefeeGwei);
        if (
            _maxTendBasefeeGwei != 0 &&
            block.basefee >= _maxTendBasefeeGwei * 1e9
        ) {
            return false;
        }

        if (TokenizedStrategy.isShutdown()) {
            return false;
        }

        // TODO: come up with a minimum to tend
        if (asset.balanceOf(address(this)) >= maxSingleTrade) {
            return true;
        }

        return false;
    }

    /**
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // TODO: needs more?
        _freeFunds(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                       Custom Management Methods 
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the deposit limit. Can only be called by management
     * @param _depositLimit The deposit limit
     */
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
    }

    /**
     * @notice Sets the max base fee for tends. Can only be called by management
     * @param _maxTendBasefeeGwei The maximum base fee allowed in gwei
     */
    function setMaxTendBasefeeGwei(
        uint16 _maxTendBasefeeGwei
    ) external onlyManagement {
        maxTendBasefeeGwei = _maxTendBasefeeGwei;
    }

    /// @notice Set maxSlippageBps to new value
    /// @param _maxSlippageBps new maxSlippageBps value
    function setMaxSlippageBps(uint16 _maxSlippageBps) external onlyManagement {
        require(_maxSlippageBps < 1_000); // dev: must be less than 10%
        maxSlippageBps = _maxSlippageBps;
    }

    /// @notice Set maxSingleTrade to new value
    /// @param _maxSingleTrade new maxSlippageBps value
    function setMaxSingleTrade(uint96 _maxSingleTrade) external onlyManagement {
        maxSingleTrade = _maxSingleTrade;
    }

    /// @notice Set lstDiscountBps to new value
    /// @param _lstDiscountBps new lstDiscountBps value
    function setLstDiscountBps(uint16 _lstDiscountBps) external onlyManagement {
        require(_lstDiscountBps < 1_000); // dev: must be less than 10%
        lstDiscountBps = _lstDiscountBps;
    }

    /// @notice Set openDeposits to new value
    /// @param _openDeposits new openDeposits value
    function setOpenDeposits(bool _openDeposits) external onlyManagement {
        openDeposits = _openDeposits;
    }

    /// @notice Set whether a depositor is allowed or not 
    /// @param _depositor the depositor to allow/disallow
    /// @param _allowed whether the depositor is allowed 
    function setAllowedDepositor(address _depositor, bool _allowed) external onlyManagement {
        allowedDepositors[_depositor] = _allowed;
    }

    /// @notice Initiate a liquid staking token (LST) withdrawal process to redeem 1:1. Returns requestIds which can be used to claim asset into the strategy.
    /// @param _amount the amount of LST to initiate a withdrawal process for.
    function initiateLSTwithdrawal(
        uint256 _amount
    ) external onlyManagement returns (uint256 requestId) {
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = _amount;
        uint256[] memory requestIds = LIDO_WITHDRAWAL_QUEUE.requestWithdrawals(
            _amounts,
            address(this)
        );
        requestId = requestIds[0];
        lstOutstandingWithdrawCount++;
    }

    /// @notice Claim asset from a liquid staking token (LST) withdrawal process to redeem 1:1. Use the requestId from initiateLSTwithdrawal() as argument.
    /// @param _requestId return from calling initiateLSTwithdrawal() to identify the withdrawal.
    function claimLSTwithdrawal(uint256 _requestId) external onlyKeepers {
        LIDO_WITHDRAWAL_QUEUE.claimWithdrawal(_requestId);
        WETH.deposit{value: address(this).balance}();
        lstOutstandingWithdrawCount--;
    }
}
