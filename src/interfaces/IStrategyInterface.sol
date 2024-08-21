// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    function maxTendBasefeeGwei() external returns (uint16);

    function maxSingleTrade() external returns (uint96);

    function maxSlippageBps() external returns (uint16);

    function lstDiscountBps() external returns (uint16);

    function lstOutstandingWithdrawCount() external returns (uint8);

    function openDeposits() external returns (bool);

    function depositLimit() external returns (uint256);

    function allowedDepositors(
        address _depositor
    ) external returns (bool _allowed);

    function estimatedTotalAssets() external view returns (uint256);

    function setDepositLimit(uint256 _depositLimit) external;

    function setMaxTendBasefeeGwei(uint16 _maxTendBasefeeGwei) external;

    function setMaxSlippageBps(uint16 _maxSlippageBps) external;

    function setMaxSingleTrade(uint96 _maxSingleTrade) external;

    function setLstDiscountBps(uint16 _lstDiscountBps) external;

    function setOpenDeposits(bool _openDeposits) external;

    function setAllowedDepositor(address _depositor, bool _allowed) external;

    function initiateLSTwithdrawal(
        uint256 _amount
    ) external returns (uint256 _requestId);

    function claimLSTwithdrawal(uint256 _requestId) external;
}
