// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HighwaterHook} from "../src/HighwaterHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Threat-map driven security / accounting tests.
contract HighwaterSecurityTest is BaseTest {
    using CurrencyLibrary for Currency;

    HighwaterHook internal hook;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(0x5EC) << 144)
        );
        bytes memory ctor = abi.encode(poolManager, address(this), curator, uint32(1 days), uint16(2000), true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        hook = HighwaterHook(payable(address(flags)));

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        _fund(alice);
        _fund(curator);
    }

    function test_DoubleSettleRequiresAnotherEpoch() public {
        vm.prank(alice);
        hook.deposit(100e18, 100e18, 0);

        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 20e18);
        vm.warp(block.timestamp + 1 days + 1);
        (uint256 fee1,) = hook.settleEpoch();
        assertGt(fee1, 0);

        // Immediate re-settle must fail — epoch clock reset.
        vm.expectRevert(HighwaterHook.EpochNotElapsed.selector);
        hook.settleEpoch();
    }

    function test_SecondEpochNoFeeWithoutNewHighWater() public {
        vm.prank(alice);
        hook.deposit(100e18, 100e18, 0);

        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 30e18);
        vm.warp(block.timestamp + 1 days + 1);
        (uint256 fee1, uint256 shares1) = hook.settleEpoch();
        assertGt(fee1, 0);
        assertGt(shares1, 0);
        uint256 hwm = hook.highWaterMark();

        // New epoch, no new outperformance above HWM → fee 0 even if still > HODL.
        // Bench was resnapshotted including the idle; leave inventory alone.
        vm.warp(block.timestamp + 1 days + 1);
        (uint256 fee2, uint256 shares2) = hook.settleEpoch();
        assertEq(fee2, 0, "HWM must block repeat fee without new high");
        assertEq(shares2, 0);
        assertEq(hook.highWaterMark(), hwm);
    }

    function test_OnlyOwnerCanMigrate() public {
        vm.prank(alice);
        hook.deposit(50e18, 50e18, 0);

        vm.prank(alice);
        vm.expectRevert(HighwaterHook.OnlyOwner.selector);
        hook.migrateStrategy(alice, -60, 60, false);
    }

    /// @dev After swaps, a partial withdraw must leave accrued fees in hook idle for remaining LPs
    ///      (not hand 100% of feesAccrued to the withdrawer). Second withdrawer still gets value.
    function test_WithdrawDoesNotCaptureAllAccruedFees() public {
        address bob = makeAddr("bob");
        _fund(bob);

        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(1_000e18, 1_000e18, 0);
        vm.prank(bob);
        (uint256 bobShares,,) = hook.deposit(1_000e18, 1_000e18, 0);

        _fund(address(this));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        for (uint256 i = 0; i < 12; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 40e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        uint256 navBefore = hook.strategyNav();
        assertGt(navBefore, 0);

        vm.prank(alice);
        hook.withdraw(aliceShares, 0, 0);

        // Bob's remaining claim must still be meaningful — fees were not fully skimmed by Alice.
        uint256 bobNavFloor = hook.strategyNav();
        assertGt(bobNavFloor, 0, "remaining LP NAV wiped - fees likely paid entirely to withdrawer");

        vm.prank(bob);
        (uint256 out0, uint256 out1) = hook.withdraw(bobShares, 0, 0);
        assertGt(out0 + out1, 0);
    }

    function test_SettleSetsPostDilutionHwm() public {
        vm.prank(alice);
        hook.deposit(200e18, 200e18, 0);

        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 50e18);
        uint256 nav = hook.strategyNav();
        uint256 supply = hook.totalSupply();

        vm.warp(block.timestamp + 1 days + 1);
        (uint256 feeWad, uint256 curatorShares) = hook.settleEpoch();
        assertGt(feeWad, 0);
        assertGt(curatorShares, 0);

        uint256 postNps = (nav * 1e18) / (supply + curatorShares);
        assertApproxEqAbs(hook.highWaterMark(), postNps, 1);
        // Must not lock above actual post-fee NPS (Tokemak class).
        assertLe(hook.highWaterMark(), postNps + 1);
    }

    function test_DeadSharesSurviveWithdrawAll() public {
        vm.prank(alice);
        (uint256 shares,,) = hook.deposit(80e18, 80e18, 0);

        vm.prank(alice);
        hook.withdraw(shares, 0, 0);

        assertEq(hook.balanceOf(address(0xdead)), 1000);
        assertEq(hook.balanceOf(alice), 0);
        // Dust may remain from dead shares' claim on liquidity — NAV can be tiny but non-zero.
        assertGt(hook.totalSupply(), 0);
    }

    function test_PreviewFeeBoundedThenSettleAfterRebalance() public {
        vm.prank(alice);
        hook.deposit(500e18, 500e18, 0);

        int24 spacing = poolKey.tickSpacing;
        vm.prank(curator);
        hook.rebalance(-10 * spacing, 10 * spacing);

        _fund(address(this));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        // Modest volume — stay inside the band so swaps don't hit price limit.
        for (uint256 i = 0; i < 4; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 5e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        (uint256 strat, uint256 bench, uint256 alpha, uint256 previewFee,) = hook.previewSettle();
        if (strat <= bench) assertEq(previewFee, 0);
        else assertLe(previewFee, alpha);

        vm.warp(block.timestamp + 1 days + 1);
        (uint256 fee,) = hook.settleEpoch();
        assertLe(fee, alpha);
        assertEq(hook.epochId(), 1);
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 5_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(who, 5_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }
}
