// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HighwaterHook} from "../src/HighwaterHook.sol";
import {HighwaterKeeper} from "../src/HighwaterKeeper.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Tests for the HighwaterKeeper auto-rebalance contract.
///
/// Strategy for simulating "price outside the active range":
///   - `poolManager.initialize` accepts a `sqrtPriceX96` argument which sets the
///     pool's starting price, and therefore its starting tick.
///   - `TickMath.getSqrtPriceAtTick(t)` converts any tick to the corresponding sqrt price.
///   - By initializing the pool at a tick that is OUTSIDE a range we later set via
///     `rebalance`, we get a pool where the current tick is already out of range —
///     with no need to manipulate state or exhaust large liquidity with swaps.
///
/// Two fixtures are used:
///   - IN_RANGE_POOL  : initialized at tick 0, range set to [-60, 60]  (tick 0 is inside)
///   - OUT_OF_RANGE_POOL: initialized at tick 300, range set to [-60, 60] (tick 300 is outside)
///
/// Each test setUp deploys a fresh hook + pool at the appropriate starting price.
contract HighwaterKeeperTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HighwaterKeeper internal keeper;
    Currency internal currency0;
    Currency internal currency1;

    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal bot = makeAddr("bot");

    uint32 constant EPOCH = 1 days;
    uint16 constant FEE_BPS = 2000;
    int24 constant TICK_SPACING = 60;

    // Active range used in all tests: ±60 ticks around 0.
    int24 constant RANGE_LOWER = -1 * TICK_SPACING; // -60
    int24 constant RANGE_UPPER = 1 * TICK_SPACING; //  60

    // Tick at which the out-of-range pool is initialized.
    // 300 is 5 spacings above RANGE_UPPER, cleanly outside [-60, 60].
    int24 constant OUT_OF_RANGE_TICK = 5 * TICK_SPACING; // 300

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers — deploy a hook+pool at a given starting tick
    // ─────────────────────────────────────────────────────────────────────────

    struct Fixture {
        HighwaterHook hook;
        PoolKey poolKey;
    }

    uint160 private _flagSeed = 0xA11C;

    /// @dev Deploy a fresh hook + pool initialized at `startTick`.
    ///      After initialization the hook's default range is full-range.
    ///      The caller may then call `hook.rebalance` to narrow it.
    function _deployFixture(int24 startTick) internal returns (Fixture memory f) {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(_flagSeed) << 144)
        );
        _flagSeed++; // unique address per fixture so deployCodeTo doesn't collide

        bytes memory ctor = abi.encode(poolManager, address(this), curator, EPOCH, FEE_BPS, true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        f.hook = HighwaterHook(payable(address(flags)));
        _enableSpotOracle(f.hook);

        f.poolKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(address(f.hook)));

        // Initialize the pool at the exact sqrtPrice that corresponds to startTick.
        // This is the standard v4 pattern: TickMath.getSqrtPriceAtTick gives the
        // exact uint160 that places the pool's current tick at startTick.
        uint160 startSqrtPrice = TickMath.getSqrtPriceAtTick(startTick);
        poolManager.initialize(f.poolKey, startSqrtPrice);
    }

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        _fund(alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // shouldRebalance — false when in range
    // ─────────────────────────────────────────────────────────────────────────

    function test_ShouldRebalanceFalseWhenInRange() public {
        // Pool starts at tick 0, range is [-60, 60] → tick 0 is inside.
        Fixture memory f = _deployFixture(0);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);

        assertFalse(keeper.shouldRebalance());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // shouldRebalance — true when out of range
    // ─────────────────────────────────────────────────────────────────────────

    function test_ShouldRebalanceTrueWhenOutOfRange() public {
        // Pool starts at tick 300, range is [-60, 60] → tick 300 is outside.
        Fixture memory f = _deployFixture(OUT_OF_RANGE_TICK);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);

        assertTrue(keeper.shouldRebalance());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // computeNewRange — ticks are aligned to spacing
    // ─────────────────────────────────────────────────────────────────────────

    function test_ComputeNewRangeAlignedToSpacing() public {
        Fixture memory f = _deployFixture(OUT_OF_RANGE_TICK);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);

        (int24 newLower, int24 newUpper) = keeper.computeNewRange();
        assertEq(newLower % TICK_SPACING, 0, "lower not aligned");
        assertEq(newUpper % TICK_SPACING, 0, "upper not aligned");
        assertLt(newLower, newUpper);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // triggerRebalance — moves range and re-centers on current tick
    // ─────────────────────────────────────────────────────────────────────────

    function test_TriggerRebalanceMovesRange() public {
        Fixture memory f = _deployFixture(OUT_OF_RANGE_TICK);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);
        assertTrue(keeper.shouldRebalance());

        int24 oldLower = f.hook.tickLower();
        int24 oldUpper = f.hook.tickUpper();

        vm.prank(bot);
        keeper.triggerRebalance();

        // Range must have moved.
        assertTrue(f.hook.tickLower() != oldLower || f.hook.tickUpper() != oldUpper);

        // New range must include the current tick.
        (, int24 currentTick,,) = poolManager.getSlot0(f.hook.boundId());
        assertGe(currentTick, f.hook.tickLower(), "tick below new lower");
        assertLe(currentTick, f.hook.tickUpper(), "tick above new upper");
    }

    function test_TriggerRebalanceCallerIsAnyAddress() public {
        Fixture memory f = _deployFixture(OUT_OF_RANGE_TICK);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);

        // Any address (not curator, not owner) can trigger a rebalance.
        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        keeper.triggerRebalance(); // must not revert
    }

    // ─────────────────────────────────────────────────────────────────────────
    // triggerRebalance — guards
    // ─────────────────────────────────────────────────────────────────────────

    function test_TriggerRebalanceRevertsWhenTickInRange() public {
        // Pool starts at tick 0, inside [-60, 60].
        Fixture memory f = _deployFixture(0);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);

        vm.expectRevert(HighwaterKeeper.TickAlreadyInRange.selector);
        keeper.triggerRebalance();
    }

    function test_KeeperRebalanceRevertsIfNotKeeper() public {
        Fixture memory f = _deployFixture(0);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);

        vm.prank(alice);
        vm.expectRevert(HighwaterHook.OnlyCuratorOrKeeper.selector);
        f.hook.keeperRebalance(RANGE_LOWER * 2, RANGE_UPPER * 2);
    }

    function test_HookKeeperRebalanceRevertsWhenTickInRange() public {
        // Even when called from the keeper address directly, the hook guards against
        // triggering a rebalance when the tick is already inside the active range.
        Fixture memory f = _deployFixture(0);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);

        vm.prank(address(keeper));
        vm.expectRevert(HighwaterHook.KeeperTickInRange.selector);
        f.hook.keeperRebalance(RANGE_LOWER * 2, RANGE_UPPER * 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Keeper disabled via setKeeper(address(0))
    // ─────────────────────────────────────────────────────────────────────────

    function test_DisabledKeeperCannotRebalance() public {
        Fixture memory f = _deployFixture(OUT_OF_RANGE_TICK);
        keeper = new HighwaterKeeper(f.hook, 10);
        f.hook.setKeeper(address(keeper));

        _depositAndNarrow(f.hook, f.poolKey);

        // Owner disables the keeper.
        f.hook.setKeeper(address(0));

        // triggerRebalance forwards to keeperRebalance, which now reverts because
        // keeper address no longer matches the registered keeper on the hook.
        vm.expectRevert();
        vm.prank(bot);
        keeper.triggerRebalance();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function test_UpdateHalfWidth() public {
        Fixture memory f = _deployFixture(0);
        keeper = new HighwaterKeeper(f.hook, 10);

        keeper.updateHalfWidth(20);
        assertEq(keeper.halfWidthSpacings(), 20);
    }

    function test_UpdateHalfWidthRevertsIfNotOwner() public {
        Fixture memory f = _deployFixture(0);
        keeper = new HighwaterKeeper(f.hook, 10);

        vm.prank(alice);
        vm.expectRevert(HighwaterKeeper.NotOwner.selector);
        keeper.updateHalfWidth(20);
    }

    function test_UpdateHalfWidthRevertsIfZero() public {
        Fixture memory f = _deployFixture(0);
        keeper = new HighwaterKeeper(f.hook, 10);

        vm.expectRevert(HighwaterKeeper.ZeroHalfWidth.selector);
        keeper.updateHalfWidth(0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deposit into the hook (full-range by default) then narrow to [-60, 60].
    ///      If the current tick is outside [-60, 60] after the rebalance, the keeper
    ///      will correctly report shouldRebalance() == true.
    function _depositAndNarrow(
        HighwaterHook h,
        PoolKey memory /* key */
    )
        internal
    {
        // Approve and deposit as alice.
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(h), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(h), type(uint256).max);
        // Single-sided deposit is fine when price is at an extreme tick:
        // LiquidityAmounts will simply use whichever token the range accepts.
        h.deposit(100_000e18, 100_000e18, 0);
        vm.stopPrank();

        // Curator narrows the range.
        vm.prank(curator);
        h.rebalance(RANGE_LOWER, RANGE_UPPER);
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 50_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(who, 50_000_000e18);
    }
}
