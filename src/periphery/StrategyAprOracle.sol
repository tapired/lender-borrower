// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracle} from "@periphery/AprOracle/AprOracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";
import {IMorpho, Id, Market, MarketParams} from "../interfaces/morpho/IMorpho.sol";
import {IOracle} from "../interfaces/morpho/IOracle.sol";
import {IIrm} from "../interfaces/morpho/IIrm.sol";
import {MorphoBalancesLib} from "../libraries/morpho/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "../libraries/morpho/SharesMathLib.sol";
import {Governance} from "@periphery/utils/Governance.sol";

interface IRewardAprOracle {
    function borrowRewardApr(Id _id) external view returns (uint256);
}

contract StrategyAprOracle is Governance {
    using MorphoBalancesLib for IMorpho;

    error Int256Overflow();

    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    AprOracle internal constant APR_ORACLE =
        AprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    mapping(address => address) public rewardAprOracles;

    constructor(address _governance) Governance(_governance) {}

    function setRewardAprOracle(
        address _strategy,
        address _rewardAprOracle
    ) external onlyGovernance {
        rewardAprOracles[_strategy] = _rewardAprOracle;
    }

    /**
     * @notice Expected APR after a debt change. Positive _delta means more debt (assets) to the strategy.
     * @param _strategy The strategy to evaluate.
     * @param _delta Debt change in terms of strategy asset
     * @return apr The expected return on equity in 1e18.
     */
    function aprAfterDebtChange(
        address _strategy,
        int256 _delta
    ) external view returns (uint256 apr) {
        IStrategyInterface strat = IStrategyInterface(_strategy);
        uint256 projectedAssets = _applyDelta(strat.totalAssets(), _delta);
        if (projectedAssets == 0) return 0;

        int256 borrowDelta = _borrowDelta(strat, _delta);
        uint256 currentDebt = strat.balanceOfDebt();
        if (borrowDelta < 0 && _abs(borrowDelta) > currentDebt) {
            if (currentDebt > uint256(type(int256).max)) {
                revert Int256Overflow();
            }
            borrowDelta = -int256(currentDebt);
        }

        uint256 projectedDebt = _applyDelta(currentDebt, borrowDelta);
        if (projectedDebt == 0) return 0;

        uint256 borrowApr = _borrowApr(strat, borrowDelta);

        // Reward APR from the lender vault (borrow token APR).
        uint256 rewardApr = APR_ORACLE.getStrategyApr(
            address(strat.lenderVault()),
            borrowDelta
        );

        address rewardAprOracle = rewardAprOracles[address(strat)];
        if (rewardAprOracle != address(0)) {
            rewardApr += IRewardAprOracle(rewardAprOracle).borrowRewardApr(
                strat.marketId()
            );
        }

        // Floor unprofitable positions at zero because the Yearn APR oracle
        // interface cannot represent a negative return.
        if (rewardApr <= borrowApr) return 0;

        (, , address oracleAddr, , ) = strat.marketParams();
        uint256 projectedEquityInBorrow = Math.mulDiv(
            projectedAssets,
            IOracle(oracleAddr).price(),
            ORACLE_PRICE_SCALE
        );
        if (projectedEquityInBorrow == 0) return 0;

        // Return on equity = net spread * projected debt / projected equity.
        apr = Math.mulDiv(
            rewardApr - borrowApr,
            projectedDebt,
            projectedEquityInBorrow
        );
    }

    function _borrowDelta(
        IStrategyInterface strat,
        int256 deltaAsset
    ) internal view returns (int256) {
        if (deltaAsset == 0) return 0;

        // target LTV = liqCF (1e18) * multiplier (bps) / 1e4
        uint256 targetLtv = (strat.getLiquidateCollateralFactor() *
            strat.targetLTVMultiplier()) / 10_000;

        // Convert asset amount to borrow token via Morpho oracle price (loan per collateral, 1e36).
        (, , address oracleAddr, , ) = strat.marketParams();
        uint256 price = IOracle(oracleAddr).price(); // 1e36
        if (price == 0) return 0;

        uint256 absoluteDelta = _abs(deltaAsset);
        uint256 assetAtTarget = Math.mulDiv(absoluteDelta, targetLtv, WAD);
        uint256 absoluteBorrowDelta = Math.mulDiv(
            assetAtTarget,
            price,
            ORACLE_PRICE_SCALE
        );
        if (absoluteBorrowDelta > uint256(type(int256).max)) {
            revert Int256Overflow();
        }

        return
            deltaAsset > 0
                ? int256(absoluteBorrowDelta)
                : -int256(absoluteBorrowDelta);
    }

    function _borrowApr(
        IStrategyInterface strat,
        int256 borrowDelta
    ) internal view returns (uint256) {
        (
            address loanToken,
            address collateralToken,
            address oracleAddr,
            address irmAddr,
            uint256 lltv
        ) = strat.marketParams();
        MarketParams memory params = MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: oracleAddr,
            irm: irmAddr,
            lltv: lltv
        });

        // Accrued market balances for accurate rate calc.
        (uint256 tsa, uint256 tss, uint256 tba, uint256 tbs) = strat
            .morpho()
            .expectedMarketBalances(params);
        Market memory market = strat.morpho().market(strat.marketId());
        if (borrowDelta != 0) {
            (tba, tbs) = _applyBorrowDelta(tba, tbs, borrowDelta);
        }
        market.totalSupplyAssets = uint128(tsa);
        market.totalSupplyShares = uint128(tss);
        market.totalBorrowAssets = uint128(tba);
        market.totalBorrowShares = uint128(tbs);

        uint256 borrowRatePerSec = IIrm(params.irm).borrowRateView(
            params,
            market
        );
        return borrowRatePerSec * SECONDS_PER_YEAR;
    }

    function _applyBorrowDelta(
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        int256 borrowDelta
    ) internal pure returns (uint256 newBorrowAssets, uint256 newBorrowShares) {
        if (borrowDelta > 0) {
            uint256 increaseAssets = uint256(borrowDelta);
            uint256 increaseShares = SharesMathLib.toSharesUp(
                increaseAssets,
                totalBorrowAssets,
                totalBorrowShares
            );
            return (
                totalBorrowAssets + increaseAssets,
                totalBorrowShares + increaseShares
            );
        }

        uint256 decreaseAssets = _abs(borrowDelta);
        if (decreaseAssets >= totalBorrowAssets) return (0, 0);

        uint256 decreaseShares = SharesMathLib.toSharesDown(
            decreaseAssets,
            totalBorrowAssets,
            totalBorrowShares
        );
        if (decreaseShares > totalBorrowShares) {
            decreaseShares = totalBorrowShares;
        }

        return (
            totalBorrowAssets - decreaseAssets,
            totalBorrowShares - decreaseShares
        );
    }

    function _applyDelta(
        uint256 amount,
        int256 delta
    ) internal pure returns (uint256) {
        if (delta >= 0) return amount + uint256(delta);

        uint256 decrease = _abs(delta);
        return decrease >= amount ? 0 : amount - decrease;
    }

    function _abs(int256 value) internal pure returns (uint256) {
        unchecked {
            return value < 0 ? uint256(-(value + 1)) + 1 : uint256(value);
        }
    }
}
