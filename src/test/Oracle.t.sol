pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AprOracle} from "@periphery/AprOracle/AprOracle.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";
import {IIrm} from "../interfaces/morpho/IIrm.sol";
import {IOracle} from "../interfaces/morpho/IOracle.sol";
import {SharesMathLib} from "../libraries/morpho/SharesMathLib.sol";
import {ManualBorrowRewardAprOracle} from "../periphery/ManualBorrowRewardAprOracle.sol";
import {StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";

contract StrategyAprOracleHarness is StrategyAprOracle {
    constructor(address _governance) StrategyAprOracle(_governance) {}

    function borrowDelta(
        address _strategy,
        int256 _assetDelta
    ) external view returns (int256) {
        return _borrowDelta(IStrategyInterface(_strategy), _assetDelta);
    }

    function applyBorrowDelta(
        uint256 _totalBorrowAssets,
        uint256 _totalBorrowShares,
        int256 _borrowDelta
    ) external pure returns (uint256 newBorrowAssets, uint256 newBorrowShares) {
        return
            _applyBorrowDelta(
                _totalBorrowAssets,
                _totalBorrowShares,
                _borrowDelta
            );
    }
}

contract OracleTest is Setup {
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant BORROW_RATE_PER_SECOND = 1e9;
    uint256 internal constant LENDER_APR = 8e16;
    AprOracle internal constant APR_ORACLE =
        AprOracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    StrategyAprOracleHarness public oracle;

    function setUp() public override {
        lenderVault = 0x696d02Db93291651ED510704c9b286841d506987;
        super.setUp();
        oracle = new StrategyAprOracleHarness(management);
    }

    function test_oracleReturnsReturnOnEquityAfterDebtChange(
        uint256 _amount,
        uint16 _percentChange,
        bool _increase
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _percentChange = uint16(bound(uint256(_percentChange), 1, MAX_BPS / 2));
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _mockRates(LENDER_APR);

        uint256 absoluteDelta = (_amount * _percentChange) / MAX_BPS;
        int256 assetDelta = _increase
            ? int256(absoluteDelta)
            : -int256(absoluteDelta);
        uint256 expectedRoe = _expectedRoe(assetDelta, 0);
        uint256 actualRoe = oracle.aprAfterDebtChange(
            address(strategy),
            assetDelta
        );

        assertEq(actualRoe, expectedRoe, "not return on equity");
    }

    function test_oracleWeightsBorrowRewards(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _mockRates(LENDER_APR);

        ManualBorrowRewardAprOracle rewardOracle = new ManualBorrowRewardAprOracle(
                management
            );
        vm.startPrank(management);
        rewardOracle.setBorrowRewardAprBps(strategy.marketId(), 500);
        oracle.setRewardAprOracle(address(strategy), address(rewardOracle));
        vm.stopPrank();

        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 0),
            _expectedRoe(0, 5e16),
            "reward APR not weighted"
        );
    }

    function test_oracleFloorsNegativeReturnAtZero(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        mintAndDepositIntoStrategy(strategy, user, _amount);
        _mockRates(0);

        assertEq(
            oracle.aprAfterDebtChange(address(strategy), 0),
            0,
            "negative return"
        );
    }

    function test_oracleReturnsZeroWithoutProjectedEquity(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(
            oracle.aprAfterDebtChange(
                address(strategy),
                -int256(strategy.totalAssets())
            ),
            0,
            "nonzero full-withdraw ROE"
        );
        assertEq(
            oracle.aprAfterDebtChange(address(strategy), type(int256).min),
            0,
            "invalid negative delta reverted"
        );
    }

    function test_repaySimulationRoundsSharesDown() public view {
        uint256 totalBorrowAssets = 1_000_000;
        uint256 totalBorrowShares = 777_777;
        uint256 decreaseAssets = 333_333;
        uint256 decreaseShares = SharesMathLib.toSharesDown(
            decreaseAssets,
            totalBorrowAssets,
            totalBorrowShares
        );

        (uint256 newBorrowAssets, uint256 newBorrowShares) = oracle
            .applyBorrowDelta(
                totalBorrowAssets,
                totalBorrowShares,
                -int256(decreaseAssets)
            );

        assertEq(newBorrowAssets, totalBorrowAssets - decreaseAssets);
        assertEq(newBorrowShares, totalBorrowShares - decreaseShares);
    }

    function test_strategyInterfaceMatchesImplementation() public {
        assertEq(strategy.borrowUsdOracle(), BORROW_USD_ORACLE);
        assertTrue(strategy.MERKL_DISTRIBUTOR() != address(0));

        uint64 configuredSlippage = strategy.slippage();
        assertLt(configuredSlippage, MAX_BPS);

        vm.prank(management);
        strategy.setBorrowUsdOracle(BORROW_USD_ORACLE);
        assertEq(strategy.borrowUsdOracle(), BORROW_USD_ORACLE);
    }

    function _expectedRoe(
        int256 _assetDelta,
        uint256 _borrowRewardApr
    ) internal view returns (uint256) {
        int256 debtDelta = oracle.borrowDelta(address(strategy), _assetDelta);
        uint256 projectedAssets = _applyDelta(
            strategy.totalAssets(),
            _assetDelta
        );
        uint256 projectedDebt = _applyDelta(
            strategy.balanceOfDebt(),
            debtDelta
        );

        (, , address morphoOracle, , ) = strategy.marketParams();
        uint256 equityInBorrow = Math.mulDiv(
            projectedAssets,
            IOracle(morphoOracle).price(),
            ORACLE_PRICE_SCALE
        );
        uint256 spread = LENDER_APR +
            _borrowRewardApr -
            (BORROW_RATE_PER_SECOND * SECONDS_PER_YEAR);

        return Math.mulDiv(spread, projectedDebt, equityInBorrow);
    }

    function _mockRates(uint256 _lenderApr) internal {
        (, , , address irm, ) = strategy.marketParams();
        vm.mockCall(
            irm,
            abi.encodeWithSelector(IIrm.borrowRateView.selector),
            abi.encode(BORROW_RATE_PER_SECOND)
        );
        vm.mockCall(
            address(APR_ORACLE),
            abi.encodeWithSelector(AprOracle.getStrategyApr.selector),
            abi.encode(_lenderApr)
        );
    }

    function _applyDelta(
        uint256 _amount,
        int256 _delta
    ) internal pure returns (uint256) {
        return
            _delta >= 0
                ? _amount + uint256(_delta)
                : _amount - uint256(-_delta);
    }
}
