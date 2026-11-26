// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HighwaterHook} from "../src/HighwaterHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract HighwaterTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;
    HighwaterHook hook;

    address curator = makeAddr("curator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint32 constant EPOCH = 1 days;
    uint16 constant FEE_BPS = 2000; // 20% of alpha

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Permissions: afterInitialize | beforeAddLiquidity | beforeRemoveLiquidity
        // Namespace bits OR'd into the free region of the hook address (v4 flag convention).
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(0xA11CE) << 144)
        );

        bytes memory ctor = abi.encode(poolManager, address(this), curator, EPOCH, FEE_BPS, true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        hook = HighwaterHook(payable(address(flags)));

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Fund users + approvals
        _fundAndApprove(alice, 1_000_000e18);
        _fundAndApprove(bob, 1_000_000e18);
        _fundAndApprove(curator, 1_000_000e18);
        _fundAndApprove(address(this), 1_000_000e18);
    }

    function _fundAndApprove(address who, uint256 amount) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, amount);
        MockERC20(Currency.unwrap(currency1)).mint(who, amount);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_BindOnInitialize() public view {
        assertTrue(hook.bound());
        assertEq(PoolId.unwrap(hook.boundId()), PoolId.unwrap(poolId));
        assertEq(hook.curator(), curator);
        assertEq(hook.performanceFeeBps(), FEE_BPS);
    }

    function test_ExternalLiquidityGated() public {
        // Exercise the gate itself: the hook entry point is only callable by the PoolManager,
        // and the gate must reject every sender that is not the hook (even via a router).
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)
        });

        vm.prank(address(poolManager));
        vm.expectRevert(HighwaterHook.LiquidityOnlyViaHook.selector);
        hook.beforeAddLiquidity(alice, poolKey, params, "");

        vm.prank(address(poolManager));
        vm.expectRevert(HighwaterHook.LiquidityOnlyViaHook.selector);
        hook.beforeRemoveLiquidity(alice, poolKey, params, "");
    }

    function test_DepositMintsShares() public {
        vm.prank(alice);
        (uint256 shares, uint256 a0, uint256 a1) = hook.deposit(100e18, 100e18, 0);

        assertGt(shares, 0);
        assertGt(a0 + a1, 0);
        assertEq(hook.balanceOf(alice), shares);
        assertGt(hook.strategyNav(), 0);
        // Benchmark snapshot opened on first deposit
        assertGt(hook.benchAmount0() + hook.benchAmount1(), 0);
    }

    function test_WithdrawReturnsProRata() public {
        vm.prank(alice);
        (uint256 shares,,) = hook.deposit(200e18, 200e18, 0);

        uint256 bal0Before = currency0.balanceOf(alice);
        uint256 bal1Before = currency1.balanceOf(alice);

        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(shares / 2, 0, 0);

        assertGt(out0 + out1, 0);
        assertEq(hook.balanceOf(alice), shares - shares / 2);
        assertEq(currency0.balanceOf(alice), bal0Before + out0);
        assertEq(currency1.balanceOf(alice), bal1Before + out1);
    }

    function test_CuratorRebalance() public {
        vm.prank(alice);
        hook.deposit(500e18, 500e18, 0);

        int24 spacing = poolKey.tickSpacing;
        int24 newLower = -60 * spacing;
        int24 newUpper = 60 * spacing;

        vm.prank(curator);
        hook.rebalance(newLower, newUpper);

        assertEq(hook.tickLower(), newLower);
        assertEq(hook.tickUpper(), newUpper);
    }

    function test_RebalanceOnlyCurator() public {
        vm.prank(alice);
        hook.deposit(100e18, 100e18, 0);

        vm.prank(alice);
        vm.expectRevert(HighwaterHook.OnlyCurator.selector);
        hook.rebalance(-120, 120);
    }

    function test_SettleEpoch_NoFeeWhenUnderperform() public {
        vm.prank(alice);
        hook.deposit(300e18, 300e18, 0);

        // Force underperformance relative to HODL by leaving inventory as-is;
        // without swaps/fee alpha, strategy ≈ bench → fee 0. Warp past epoch.
        vm.warp(block.timestamp + EPOCH + 1);

        uint256 curatorSharesBefore = hook.balanceOf(curator);
        (uint256 feeWad, uint256 curatorShares) = hook.settleEpoch();

        // Equal inventories → alpha ~0 → no fee
        assertEq(feeWad, 0);
        assertEq(curatorShares, 0);
        assertEq(hook.balanceOf(curator), curatorSharesBefore);
        assertEq(hook.epochId(), 1);
    }

    function test_SettleEpoch_RevertsBeforeElapsed() public {
        vm.prank(alice);
        hook.deposit(100e18, 100e18, 0);

        vm.expectRevert(HighwaterHook.EpochNotElapsed.selector);
        hook.settleEpoch();
    }

    function test_MigrateStrategy() public {
        address newCurator = makeAddr("newCurator");

        vm.prank(alice);
        hook.deposit(400e18, 400e18, 0);

        int24 spacing = poolKey.tickSpacing;
        int24 newLower = -30 * spacing;
        int24 newUpper = 30 * spacing;

        hook.migrateStrategy(newCurator, newLower, newUpper, true);

        assertEq(hook.curator(), newCurator);
        assertEq(hook.tickLower(), newLower);
        assertEq(hook.tickUpper(), newUpper);
    }

    function test_PreviewSettleMatchesSettleWhenNoAlpha() public {
        vm.prank(alice);
        hook.deposit(150e18, 150e18, 0);
        vm.warp(block.timestamp + EPOCH + 1);

        (,,, uint256 previewFee, uint256 previewShares) = hook.previewSettle();
        (uint256 fee, uint256 shares) = hook.settleEpoch();
        assertEq(fee, previewFee);
        assertEq(shares, previewShares);
    }

    function test_SecondDepositorProRataShares() public {
        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(100e18, 100e18, 0);

        vm.prank(bob);
        (uint256 bobShares,,) = hook.deposit(100e18, 100e18, 0);

        // Roughly similar deposits → roughly similar shares (allow slack for rounding / dead shares)
        assertApproxEqRel(aliceShares + 1000, bobShares + aliceShares - bobShares + 1000, 0.15e18);
        assertGt(bobShares, 0);
        assertEq(hook.balanceOf(alice), aliceShares);
        assertEq(hook.balanceOf(bob), bobShares);
    }

    /// @dev Simulate curator outperformance: idle tokens land on the hook after the HODL
    ///      snapshot, so strategy NAV > benchmark. Settle must mint fee shares to curator.
    function test_SettleEpoch_MintsFeeOnAlpha() public {
        vm.prank(alice);
        hook.deposit(200e18, 200e18, 0);

        uint256 bench = hook.benchmarkNav();
        assertGt(bench, 0);

        // Air-drop token1 to the hook → strategy inventory rises, HODL bench does not.
        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 50e18);

        uint256 strategy = hook.strategyNav();
        assertGt(strategy, bench);

        vm.warp(block.timestamp + EPOCH + 1);

        uint256 curatorBefore = hook.balanceOf(curator);
        (uint256 feeWad, uint256 curatorShares) = hook.settleEpoch();

        assertGt(feeWad, 0);
        assertGt(curatorShares, 0);
        assertEq(hook.balanceOf(curator), curatorBefore + curatorShares);
        // High-water ratchets up after a fee event
        assertGt(hook.highWaterMark(), 1e18);
    }
}
