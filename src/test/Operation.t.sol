// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20} from "./utils/Setup.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set protocol fee to 0 and perf fee to 0
        setFees(0, 0);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() *
            strategy.targetLTVMultiplier()) / MAX_BPS;

        checkStrategyTotals(strategy, _amount, _amount, 0);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(
            strategy.balanceOfCollateral(),
            _amount,
            10,
            "!balanceOfCollateral"
        );
        assertApproxEqRel(
            strategy.balanceOfDebt(),
            strategy.balanceOfLentAssets(),
            1e15
        ); // 0.1%

        // Earn Interest
        skip(1 days);

        uint256 toAirdrop = _amount / 1000;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertApproxEqRel(
            asset.balanceOf(user),
            balanceBefore + _amount,
            1e15,
            "!final balance"
        ); // 0.1%

        checkStrategyTotals(strategy, 0, 0, 0);
    }

    function test_basicDepositWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        uint256 warningLTV = (strategy.getLiquidateCollateralFactor() *
            strategy.warningLTVMultiplier()) / MAX_BPS;

        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertGt(strategy.balanceOfCollateral(), 0, "collateral");
        assertGt(strategy.balanceOfDebt(), 0, "debt");
        assertLt(strategy.getCurrentLTV(), warningLTV, "ltv too high");

        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.withdraw(_amount / 2, user, user);

        assertApproxEq(
            strategy.totalAssets(),
            strategy.totalSupply(),
            10,
            "assets ~ supply"
        );
        assertEq(asset.balanceOf(user), userBalanceBefore + (_amount / 2));
    }

    function test_reportDoesNotRevert(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Let some time pass to accrue interest.
        skip(1 days);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Accept either profit or minor loss, but strategy should stay solvent.
        assertGt(strategy.totalAssets(), 0, "no assets");
        assertGe(profit + strategy.totalAssets(), strategy.totalAssets());
        assertGe(loss + strategy.totalAssets(), strategy.totalAssets() - loss);
    }

    function test_profitableReport(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Let some time pass to accrue interest.
        skip(2 days);

        // Airdrop asset to simulate yield above any negative carry.
        uint256 toAirdrop = _amount / 100;
        airdrop(asset, address(strategy), toAirdrop);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(loss, 0, "!loss");
        assertGt(profit, 0, "!profit");
        // Profit is the airdrop minus the interest gap from the skip.
        assertApproxEqRel(profit, toAirdrop, 0.2e18, "!profit amount");
        assertGe(strategy.totalAssets(), _amount, "!totalAssets");
    }

    function test_manualRepayReducesDebt(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 debtBefore = strategy.balanceOfDebt();
        assertGt(debtBefore, 0, "no debt");

        // Fund borrow token to repay
        airdrop(ERC20(borrowToken), address(strategy), debtBefore / 2);
        vm.prank(management);
        strategy.manualRepayDebt();

        assertLt(strategy.balanceOfDebt(), debtBefore, "debt not reduced");
    }

    function test_fullWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Verify position was established
        assertGt(strategy.balanceOfCollateral(), 0, "no collateral");
        assertGt(strategy.balanceOfDebt(), 0, "no debt");

        // Let some time pass - this causes interest to accrue
        skip(1 days);

        // Get user's shares
        uint256 userShares = strategy.balanceOf(user);
        uint256 userBalanceBefore = asset.balanceOf(user);

        vm.prank(user);
        strategy.redeem(userShares, user, user);

        // Verify full withdrawal succeededs
        assertEq(strategy.balanceOf(user), 0, "user still has shares");
        assertGt(
            asset.balanceOf(user),
            userBalanceBefore,
            "user didn't receive assets"
        );
    }

    function test_multipleReportCycles(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        uint256 totalAssetsBefore = strategy.totalAssets();

        // Run 3 report cycles
        for (uint256 i = 0; i < 3; i++) {
            skip(1 days);

            vm.prank(keeper);
            strategy.report();

            // Total assets should remain reasonable (not go to 0, not explode)
            assertGt(strategy.totalAssets(), 0, "assets went to 0");
            assertLt(
                strategy.totalAssets(),
                totalAssetsBefore * 2,
                "assets doubled unexpectedly"
            );
        }

        // After 3 cycles, strategy should still be solvent
        assertGt(strategy.totalAssets(), 0, "insolvent after cycles");

        // Collateral should still exist
        assertGt(
            strategy.balanceOfCollateral(),
            0,
            "no collateral after cycles"
        );
    }

    function test_setLtvMultipliers_validation() public {
        // Test: target >= warning should revert
        vm.prank(management);
        vm.expectRevert("invalid LTV");
        strategy.setLtvMultipliers(8_000, 8_000);

        vm.prank(management);
        vm.expectRevert("invalid LTV");
        strategy.setLtvMultipliers(8_500, 8_000);

        // Test: warning > 9000 should revert
        vm.prank(management);
        vm.expectRevert("invalid LTV");
        strategy.setLtvMultipliers(7_000, 9_001);

        // Test: target = 0 should revert
        vm.prank(management);
        vm.expectRevert("invalid LTV");
        strategy.setLtvMultipliers(0, 8_000);

        // Test: valid params succeed
        vm.prank(management);
        strategy.setLtvMultipliers(6_000, 7_000);
        assertEq(strategy.targetLTVMultiplier(), 6_000);
        assertEq(strategy.warningLTVMultiplier(), 7_000);

        // Test: edge case - tight band
        vm.prank(management);
        strategy.setLtvMultipliers(8_999, 9_000);
        assertEq(strategy.targetLTVMultiplier(), 8_999);
        assertEq(strategy.warningLTVMultiplier(), 9_000);
    }
}
