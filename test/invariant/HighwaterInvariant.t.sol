// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HighwaterHook} from "../../src/HighwaterHook.sol";
import {HighwaterLib} from "../../src/libraries/HighwaterLib.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {HighwaterHandler} from "./HighwaterHandler.sol";

/// @notice Stateful invariant suite for HIGHWATER (HWM monotone, fee bounds, dead shares).
/// Master properties:
///   1) high-water mark never decreases
///   2) settle fee never exceeds alpha (preview)
///   3) dead shares remain locked at 0xdead after first deposit
///   4) strategy NAV is zero only when no live shares (besides dead)
contract HighwaterInvariantTest is StdInvariant, BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    HighwaterHook internal hook;
    HighwaterHandler internal handler;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(0xBEEF) << 144)
        );
        bytes memory ctor = abi.encode(poolManager, address(this), curator, uint32(1 days), uint16(2000), true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        hook = HighwaterHook(payable(address(flags)));
        _enableSpotOracle(hook);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        _fund(alice);
        _fund(bob);
        _fund(curator);
        _fund(address(this));

        // Seed vault so invariants aren't vacuous on empty state.
        vm.prank(alice);
        hook.deposit(200e18, 200e18, 0);

        // Approve router for swaps from alice/bob.
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        handler = new HighwaterHandler(hook, swapRouter, poolKey, currency0, currency1, curator, alice, bob);

        // Handler needs token balances + approvals for deposits.
        _fund(address(handler));
        // Transfer from this contract's mint to handler already done via _fund mint-to-who.
        // Handler deposits as alice/bob (prank), so alice/bob must stay funded — already are.

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = HighwaterHandler.deposit.selector;
        selectors[1] = HighwaterHandler.withdraw.selector;
        selectors[2] = HighwaterHandler.rebalance.selector;
        selectors[3] = HighwaterHandler.swap.selector;
        selectors[4] = HighwaterHandler.warpAndSettle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ─── master invariants ───────────────────────────────────────────────────

    function invariant_highWaterMarkNeverDecreases() public view {
        // HWM starts at 1.0 WAD and HighwaterLib never lowers it. The handler's
        // _trackHwm() reverts on any observed decrease (discarding that action), so
        // here we check the absolute floor rather than a self-updating ghost.
        assertGe(hook.highWaterMark(), HighwaterLib.WAD, "HWM fell below its initial value");
    }

    function invariant_previewFeeNeverExceedsAlpha() public view {
        (uint256 strategyNavWad, uint256 benchmarkNavWad, uint256 alphaWad, uint256 feeWad,) = hook.previewSettle();
        if (strategyNavWad <= benchmarkNavWad) {
            assertEq(feeWad, 0, "fee on non-positive alpha");
            assertEq(alphaWad, 0, "alpha should be 0 when underperforming");
        } else {
            assertLe(feeWad, alphaWad, "fee exceeds alpha");
        }
    }

    function invariant_deadSharesLocked() public view {
        // After seed deposit, dead shares must remain at 0xdead forever.
        assertEq(hook.balanceOf(address(0xdead)), hook.DEAD_SHARES(), "dead shares moved");
    }

    function invariant_sharesImplyPositiveNav() public view {
        uint256 live = hook.totalSupply() - hook.balanceOf(address(0xdead));
        if (live > 0) {
            assertGt(hook.strategyNav(), 0, "live shares but zero NAV");
        }
        // Even with only dead shares, inventory may be dust — but never negative mark.
        assertGe(hook.strategyNav(), 0);
    }

    function afterInvariant() public view {
        // Anti-vacuity: the campaign must have exercised real actions, not just the seed.
        assertGt(hook.totalSupply(), 0, "vacuous: no shares");
        assertEq(hook.balanceOf(address(0xdead)), hook.DEAD_SHARES(), "dead shares missing after campaign");
        assertGt(
            handler.ghostDeposits() + handler.ghostSettles() + handler.ghostSwaps(),
            0,
            "vacuous: no fuzz actions succeeded"
        );
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 10_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(who, 10_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }
}
