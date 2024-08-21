// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
    }

    function test_setters(
        uint256 _depositLimit,
        uint16 _baseFee,
        uint96 _maxSingleTrade,
        uint16 _maxSlippageBps,
        uint16 _lstDiscountBps,
        bool _openDeposits
    ) public {
        vm.expectRevert("!management");
        strategy.setDepositLimit(_depositLimit);
        vm.prank(management);
        strategy.setDepositLimit(_depositLimit);
        assertEq(strategy.depositLimit(), _depositLimit);

        vm.expectRevert("!management");
        strategy.setMaxTendBasefeeGwei(_baseFee);
        vm.prank(management);
        strategy.setMaxTendBasefeeGwei(_baseFee);
        assertEq(strategy.maxTendBasefeeGwei(), _baseFee);

        vm.expectRevert("!management");
        strategy.setMaxSingleTrade(_maxSingleTrade);
        vm.prank(management);
        strategy.setMaxSingleTrade(_maxSingleTrade);
        assertEq(strategy.maxSingleTrade(), _maxSingleTrade);

        vm.expectRevert("!management");
        strategy.setMaxSlippageBps(_maxSlippageBps);
        vm.prank(management);
        if (_maxSlippageBps >= 1_000) vm.expectRevert();
        strategy.setMaxSlippageBps(_maxSlippageBps);
        if (_maxSlippageBps < 1_000) {
            assertEq(strategy.maxSlippageBps(), _maxSlippageBps);
        }

        vm.expectRevert("!management");
        strategy.setLstDiscountBps(_lstDiscountBps);
        vm.prank(management);
        if (_lstDiscountBps >= 1_000) vm.expectRevert();
        strategy.setLstDiscountBps(_lstDiscountBps);
        if (_lstDiscountBps < 1_000) {
            assertEq(strategy.lstDiscountBps(), _lstDiscountBps);
        }

        vm.expectRevert("!management");
        strategy.setOpenDeposits(_openDeposits);
        vm.prank(management);
        strategy.setOpenDeposits(_openDeposits);
        assertEq(strategy.openDeposits(), _openDeposits);

    }

    function test_operation(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        logStrategyInfo();

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        logStrategyInfo();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    /*
    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        uint256 toAirdrop = susde.convertToShares(
            (_amount * (MAX_BPS + _profitFactor)) / MAX_BPS
        );
        airdrop(ERC20(address(susde)), address(strategy), toAirdrop);
        deal(address(asset), address(strategy), 0);

        logStrategyInfo();

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        logStrategyInfo();

        // Check return Values
        assertApproxEq(
            profit,
            susde.convertToAssets(toAirdrop) - _amount,
            1e6,
            "!profit"
        );
        assertEq(loss, 0, "!loss");

        skip(
            Math.max(strategy.profitMaxUnlockTime(), susde.cooldownDuration())
        );

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport_multipleProxies(
        uint256 _amount,
        uint16 _profitFactor,
        uint8 _proxyCount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));
        _proxyCount = uint8(
            bound(uint256(_proxyCount), 1, strategy.MAX_STRATEGY_PROXIES() + 1)
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        uint256 totalAirdrop = susde.convertToShares(
            (_amount * (MAX_BPS + _profitFactor)) / MAX_BPS
        );

        vm.expectRevert("!management");
        strategy.addStrategyProxy();

        for (uint8 i = 0; i < _proxyCount; ++i) {
            // we already have one, so no need to clone the first
            if (i != 0) {
                // expect a revert on the too many proxies case
                if (i == strategy.MAX_STRATEGY_PROXIES()) {
                    vm.startPrank(management);
                    vm.expectRevert();
                    strategy.addStrategyProxy();
                    vm.stopPrank();
                    return;
                }
                vm.prank(management);
                strategy.addStrategyProxy();
            }

            uint256 toAirdrop = totalAirdrop / _proxyCount;

            airdrop(ERC20(address(susde)), address(strategy), toAirdrop);
            deal(
                address(asset),
                address(strategy),
                asset.balanceOf(address(strategy)) - (_amount / _proxyCount)
            );

            logStrategyInfo();

            // Report profit
            vm.prank(keeper);
            (uint256 profit, uint256 loss) = strategy.report();

            logStrategyInfo();

            // Check return Values
            assertGe(
                profit,
                susde.convertToAssets(toAirdrop) - (_amount / _proxyCount),
                "!profit"
            );
            assertEq(loss, 0, "!loss");

            skip(1 days); // skip 1 day
        }

        assertEq(strategy.strategyProxyCount(), _proxyCount, "!proxyCount");

        skip(
            Math.max(strategy.profitMaxUnlockTime(), susde.cooldownDuration())
        );

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_multipleDeposits(
        uint256 _depositA,
        uint256 _depositB,
        bool report,
        bool secondProxy
    ) public {
        _depositA = bound(_depositA, minFuzzAmount, maxFuzzAmount);
        _depositB = bound(_depositB, minFuzzAmount, maxFuzzAmount);
        uint256 _profitFactor = 100;

        if (secondProxy) {
            vm.prank(management);
            strategy.addStrategyProxy();
            assertEq(strategy.strategyProxyCount(), 2);
        }

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _depositA);

        assertEq(strategy.totalAssets(), _depositA, "!totalAssets");

        assertEq(strategy.estimatedTotalAssets(), _depositA);
        assertEq(asset.balanceOf(address(strategy)), _depositA);
        assertEq(susde.balanceOf(address(strategy)), 0);
        assertEq(strategy.coolingUSDe(), 0);

        uint256 toAirdrop = susde.convertToShares(
            (_depositA * (MAX_BPS + _profitFactor)) / MAX_BPS
        );
        airdrop(ERC20(address(susde)), address(strategy), toAirdrop);
        deal(address(asset), address(strategy), 0);

        logStrategyInfo();

        assertGt(strategy.estimatedTotalAssets(), _depositA);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(susde.balanceOf(address(strategy)), toAirdrop);
        assertEq(strategy.coolingUSDe(), 0);

        // Report profit
        vm.prank(keeper);
        strategy.tend();

        assertGt(strategy.estimatedTotalAssets(), _depositA);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(susde.balanceOf(address(strategy)), 0);
        assertGt(strategy.coolingUSDe(), _depositA);

        if (report) {
            // Report profit
            vm.prank(keeper);
            (uint256 profit, uint256 loss) = strategy.report();

            logStrategyInfo();

            // Check return Values
            assertApproxEq(
                profit,
                susde.convertToAssets(toAirdrop) - _depositA,
                1e6,
                "!profit"
            );
            assertEq(loss, 0, "!loss");
        }

        skip(1 days);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _depositB);

        if (report) {
            assertGt(
                strategy.totalAssets(),
                _depositA + _depositB,
                "!totalAssets"
            );
        } else {
            assertEq(
                strategy.totalAssets(),
                _depositA + _depositB,
                "!totalAssets"
            );
        }

        assertGt(strategy.estimatedTotalAssets(), _depositA + _depositB);
        assertEq(asset.balanceOf(address(strategy)), _depositB);
        assertEq(susde.balanceOf(address(strategy)), 0);
        assertGt(strategy.coolingUSDe(), _depositA);

        toAirdrop = susde.convertToShares(
            (_depositB * (MAX_BPS + _profitFactor)) / MAX_BPS
        );
        airdrop(ERC20(address(susde)), address(strategy), toAirdrop);
        deal(address(asset), address(strategy), 0);

        logStrategyInfo();

        assertGt(strategy.estimatedTotalAssets(), _depositA + _depositB);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(susde.balanceOf(address(strategy)), toAirdrop);
        assertGt(strategy.coolingUSDe(), _depositA);

        // Report profit
        vm.prank(keeper);
        strategy.tend();

        logStrategyInfo();

        assertGt(strategy.estimatedTotalAssets(), _depositA + _depositB);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertEq(
            susde.balanceOf(address(strategy)),
            secondProxy ? 0 : toAirdrop
        );
        assertGt(
            strategy.coolingUSDe(),
            secondProxy ? _depositA + _depositB : _depositA
        );

        skip(
            Math.max(strategy.profitMaxUnlockTime(), susde.cooldownDuration())
        );

        uint256 balanceBefore = asset.balanceOf(user);
        uint256 redeemAmount = secondProxy ? _depositA + _depositB : _depositA;
        redeemAmount = Math.min(redeemAmount, strategy.maxRedeem(user));

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(redeemAmount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + redeemAmount,
            "!final balance"
        );
    }

    function test_redeemSubset(
        uint256 _amount,
        uint256 _redeemAmount,
        bool _profit,
        bool _report
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _redeemAmount = bound(_redeemAmount, 1e18, _amount - 1e18);
        uint256 _profitFactor = 100;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        if (_profit) {
            // Earn Interest
            skip(1 days);

            uint256 toAirdrop = susde.convertToShares(
                (_amount * (MAX_BPS + _profitFactor)) / MAX_BPS
            );
            airdrop(ERC20(address(susde)), address(strategy), toAirdrop);
            deal(address(asset), address(strategy), 0);
        }

        logStrategyInfo();

        if (_report) {
            // Report profit
            vm.prank(keeper);
            (uint256 profit, uint256 loss) = strategy.report();

            logStrategyInfo();

            // Check return Values
            if (_profit) {
                assertGt(profit, 0, "!profit");
            } else {
                assertEq(profit, 0, "!profit");
            }
            assertEq(loss, 0, "!loss");

            skip(
                Math.max(
                    strategy.profitMaxUnlockTime(),
                    susde.cooldownDuration()
                )
            );
        }

        uint256 balanceBefore = asset.balanceOf(user);

        uint256 maxRedeem = strategy.maxRedeem(address(user));
        if (_profit && !_report) {
            assertEq(maxRedeem, 0);
        } else {
            vm.prank(user);
            strategy.redeem(_redeemAmount, user, user);
            assertGe(
                asset.balanceOf(user),
                balanceBefore + _redeemAmount,
                "!partialRedeem"
            );
        }

        logStrategyInfo();

        maxRedeem = strategy.maxRedeem(address(user));
        if (_profit && !_report) {
            assertEq(maxRedeem, 0);
            return; // nothing else to do
        }
        // Withdraw all funds
        vm.startPrank(user);
        strategy.redeem(strategy.balanceOf(user), user, user);
        vm.stopPrank();

        logStrategyInfo();

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_sUSDeRedeemable(uint256 _amount, bool report) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        uint256 _profitFactor = 100;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        assertEq(strategy.estimatedTotalAssets(), _amount);
        assertEq(asset.balanceOf(address(strategy)), _amount);
        assertEq(susde.balanceOf(address(strategy)), 0);
        assertEq(strategy.coolingUSDe(), 0);

        uint256 toAirdrop = susde.convertToShares(
            (_amount * (MAX_BPS + _profitFactor)) / MAX_BPS
        );
        airdrop(ERC20(address(susde)), address(strategy), toAirdrop);
        deal(address(asset), address(strategy), 0);

        logStrategyInfo();

        assertGt(strategy.estimatedTotalAssets(), _amount);
        assertEq(asset.balanceOf(address(strategy)), 0);
        assertGt(susde.balanceOf(address(strategy)), 0);
        assertEq(strategy.coolingUSDe(), 0);

        assertEq(strategy.maxRedeem(user), 0);

        vm.prank(susde.owner());
        susde.setCooldownDuration(0);

        logStrategyInfo();
        assertEq(strategy.maxRedeem(user), _amount);

        if (report) {
            // Report profit
            vm.prank(keeper);
            (uint256 profit, uint256 loss) = strategy.report();

            logStrategyInfo();

            assertGt(strategy.estimatedTotalAssets(), _amount);
            assertGt(asset.balanceOf(address(strategy)), _amount);
            assertEq(susde.balanceOf(address(strategy)), 0);
            assertEq(strategy.coolingUSDe(), 0);

            // Check return Values
            assertApproxEq(
                profit,
                susde.convertToAssets(toAirdrop) - _amount,
                1e6,
                "!profit"
            );
            assertEq(loss, 0, "!loss");

            skip(strategy.profitMaxUnlockTime());
        }

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }
    */
}
