pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ShutdownTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        logStrategyInfo();

        // Earn Interest
        skip(180 days);
        createProfit(steth.balanceOf(address(strategy)), 180 days);

        logStrategyInfo();

        vm.prank(keeper);
        strategy.report();
        
        skip(3 days);
        
        logStrategyInfo();

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        assertGe(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.startPrank(user);
        for (
            uint256 _sharesRemaining = _amount;
            _sharesRemaining > 0;
            _sharesRemaining = strategy.balanceOf(user)
        ) {
            strategy.redeem(
                Math.min(strategy.maxRedeem(user), _sharesRemaining),
                user,
                user
            );
        }
        vm.stopPrank();

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }
}
