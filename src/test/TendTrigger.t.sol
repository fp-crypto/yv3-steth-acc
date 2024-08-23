// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TendTriggerTest is Setup {
    function setUp() public virtual override {
        super.setUp();
        vm.prank(management);
    }

    function test_tendTrigger(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger, "no deposit");

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        for (
            uint256 _loose = asset.balanceOf(address(strategy));
            _loose >= strategy.maxSingleTrade();
            _loose = asset.balanceOf(address(strategy))
        ) {
            (trigger, ) = strategy.tendTrigger();
            assertTrue(trigger, "enough loose to tend");
            vm.prank(keeper);
            strategy.tend();
        }
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger, "not enough loose");

        airdrop(
            ERC20(address(asset)),
            address(strategy),
            strategy.maxSingleTrade()
        );

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "loose");

        // False due to fee too high
        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 + 1);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger, "fee too high");

        // True due to fee below max
        vm.fee(uint256(strategy.maxTendBasefeeGwei()) * 1e9 - 1);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger, "fee acceptable");

        vm.prank(keeper);
        strategy.tend();

        // False just tended
        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.startPrank(user);
        strategy.redeem(
            Math.min(_amount, strategy.maxRedeem(user)),
            user,
            user
        );
        vm.stopPrank();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}
