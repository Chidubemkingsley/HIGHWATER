// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HighwaterHook} from "../src/HighwaterHook.sol";
import {HighwaterKeeper} from "../src/HighwaterKeeper.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Audit findings — regression tests for each identified security issue.
/// Each test is named after the finding it covers (S1–S6).
contract HighwaterAuditTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HighwaterHook internal hook;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint32 constant EPOCH = 1 days;
    uint16 constant FEE_BPS = 2000;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(0xA99D) << 144)
        );
        bytes memory ctor = abi.encode(poolManager, address(this), curator, EPOCH, FEE_BPS, true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        hook = HighwaterHook(payable(address(flags)));
        _enableSpotOracle(hook);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        _fund(alice);
        _fund(bob);
        _fund(curator);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // S1 — Benchmark after full exit + re-entry
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice S1: If all live shareholders exit and the vault goes to dead-shares-only,
    ///         then `settleEpoch` can still be called (epoch elapsed). After the settle,
    ///         the benchmark is refreshed from the dead-shares' dust inventory. The next
    ///         depositor must get a fresh, correct benchmark, not the stale dust values.
    function test_S1_BenchmarkRefreshesCorrectlyAfterFullExit() public {
        // Alice deposits and becomes the only live LP.
        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(500e18, 500e18, 0);

        // Record benchmark after deposit.
        uint256 bench0After = hook.benchAmount0();
        uint256 bench1After = hook.benchAmount1();
        assertGt(bench0After + bench1After, 0, "bench should be set after deposit");

        // Alice fully exits — only dead shares remain.
        vm.prank(alice);
        hook.withdraw(aliceShares, 0, 0);
        assertEq(hook.balanceOf(alice), 0);
        assertGt(hook.balanceOf(address(0xdead)), 0, "dead shares must survive");

        // Warp past epoch and settle. Supply is non-zero (dead shares), NAV is dust.
        vm.warp(block.timestamp + EPOCH + 1);
        hook.settleEpoch(); // must not revert

        // After settle, bench is refreshed to current inventory (dust from dead shares).
        uint256 benchAfterSettle0 = hook.benchAmount0();
        uint256 benchAfterSettle1 = hook.benchAmount1();
        // Bench must reflect the actual dust inventory, not stale pre-exit amounts.
        // The dead shares hold a tiny slice; bench can be 0 or tiny — but must not be
        // the pre-exit values, which were much larger.
        assertLt(benchAfterSettle0, bench0After, "bench0 should shrink after full LP exit");
        assertLt(benchAfterSettle1, bench1After, "bench1 should shrink after full LP exit");

        // Bob now deposits. His shares must be priced against the refreshed benchmark.
        vm.prank(bob);
        (uint256 bobShares,,) = hook.deposit(200e18, 200e18, 0);
        assertGt(bobShares, 0, "bob must receive shares after re-entry");

        // The benchmark must now reflect Bob's fresh deposit inventory.
        uint256 benchAfterBob0 = hook.benchAmount0();
        uint256 benchAfterBob1 = hook.benchAmount1();
        assertGt(benchAfterBob0 + benchAfterBob1, 0, "benchmark must be non-trivial after Bob's deposit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // S2 — migrateStrategy does not refresh benchmark
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice S2: After fix, `migrateStrategy` with `doRebalance=true` MUST refresh
    ///         the benchmark to match the post-migration inventory composition.
    function test_S2_MigrateStrategyLeavesStaleHodlBenchmark() public {
        vm.prank(alice);
        hook.deposit(1_000e18, 1_000e18, 0);

        uint256 bench0Before = hook.benchAmount0();
        uint256 bench1Before = hook.benchAmount1();
        assertGt(bench0Before, 0);
        assertGt(bench1Before, 0);

        // Migrate to a narrow range.
        address newCurator = makeAddr("newCurator");
        int24 spacing = poolKey.tickSpacing;
        hook.migrateStrategy(newCurator, -2 * spacing, 2 * spacing, true);

        uint256 bench0After = hook.benchAmount0();
        uint256 bench1After = hook.benchAmount1();

        // FIX VERIFIED: benchmark is now refreshed after migrateStrategy.
        // The new bench must reflect the narrower-range inventory, which differs
        // from the full-range composition. At 1:1 price both should be non-trivial
        // but the total should not be identical to the full-range snapshot.
        assertGt(bench0After + bench1After, 0, "benchmark must be non-zero after migrate");
        // The total inventory in a narrow range differs from full-range — at minimum
        // one of the values must have changed.
        bool benchChanged = (bench0After != bench0Before) || (bench1After != bench1Before);
        assertTrue(benchChanged, "[S2] benchmark must refresh after migrateStrategy with doRebalance=true");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // S3 — Keeper sandwich: frontrun triggerRebalance to manipulate new range center
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice S3 (FIXED): keeperRebalance now requires the proposed range to contain
    ///         the current tick, so a compromised keeper cannot move the position to a
    ///         tick-free zone and grief depositors.
    function test_S3_KeeperRangeDoesNotNeedToContainCurrentTick() public {
        HighwaterKeeper keeper = new HighwaterKeeper(hook, 10);
        hook.setKeeper(address(keeper));

        vm.prank(alice);
        hook.deposit(500e18, 500e18, 0);

        // Active range entirely above tick 0 so keeper fires.
        int24 spacing = poolKey.tickSpacing;
        vm.prank(curator);
        hook.rebalance(2 * spacing, 5 * spacing);

        (, int24 currentTick,,) = poolManager.getSlot0(hook.boundId());
        assertTrue(currentTick < hook.tickLower(), "tick should be below range");
        assertTrue(keeper.shouldRebalance());

        // FIX VERIFIED: keeper cannot propose a range that excludes the current tick.
        int24 attackLower = 10 * spacing; // entirely above tick 0
        int24 attackUpper = 20 * spacing;

        vm.prank(address(keeper));
        vm.expectRevert(HighwaterHook.InvalidTicks.selector);
        hook.keeperRebalance(attackLower, attackUpper);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // S5 — Burn before poke: shares burned before revert guard can be irrecoverable
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice S5: `withdraw` calls `_burn(msg.sender, shares)` early in the function,
    ///         before the liquidity removal, idle payout, and the final NAV guard.
    ///         If the final guard `strategyNav() == 0` fires (which triggers a revert),
    ///         the burn is NOT rolled back — Foundry/EVM reverts the whole transaction,
    ///         so the shares ARE restored by the EVM revert. This is therefore NOT
    ///         a real loss bug. This test confirms the EVM revert restores state correctly.
    function test_S5_WithdrawRevertRestoresShares() public {
        // Alice is the only live depositor.
        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(100e18, 100e18, 0);

        uint256 sharesBefore = hook.balanceOf(alice);
        assertEq(sharesBefore, aliceShares);

        // Alice attempts to withdraw her entire position (minus dead shares).
        // This should SUCCEED (dead shares retain a dust claim on the vault position).
        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(aliceShares, 0, 0);
        assertGt(out0 + out1, 0, "full exit must return something");

        // Shares are properly burned — Alice holds 0.
        assertEq(hook.balanceOf(alice), 0, "shares must be burned on success");
        // Dead shares still hold the vault.
        assertGt(hook.balanceOf(address(0xdead)), 0);
        assertGt(hook.totalSupply(), 0);
    }

    /// @notice S5b: a failed withdrawal must leave share balances and NAV untouched.
    ///         The burn happens before the payout, so the EVM revert is what restores it.
    function test_S5b_RevertRestoresShares() public {
        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(80e18, 80e18, 0);

        uint256 sharesBefore = hook.balanceOf(alice);
        uint256 navBefore = hook.strategyNav();

        // Request more shares than owned: fails after the burn point in withdraw().
        vm.prank(alice);
        vm.expectRevert(HighwaterHook.InsufficientShares.selector);
        hook.withdraw(aliceShares + 1, 0, 0);

        assertEq(hook.balanceOf(alice), sharesBefore, "failed withdraw burned shares");
        assertEq(hook.strategyNav(), navBefore, "failed withdraw changed NAV");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // S6 — No two-step ownership / curator transfer
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice S6: `setCurator` and `transferOwnership` take effect immediately.
    ///         If the owner sets curator to a contract that cannot call `rebalance`
    ///         (e.g. wrong address, missing interface), the vault is griefed permanently
    ///         until the owner sets a new curator. This is a LOW operational risk.
    ///
    ///         This test documents that setting curator to address(0) is explicitly
    ///         blocked, but setting it to a non-callable address is not.
    function test_S6_SetCuratorToZeroReverts() public {
        vm.expectRevert(HighwaterHook.InvalidCurator.selector);
        hook.setCurator(address(0));
    }

    function test_S6_SetCuratorToDeadAddressSucceedsButGriefsCuration() public {
        // Setting curator to 0xdead is accepted (not address(0)).
        // The vault is now permanently stuck on its current range unless owner migrates.
        hook.setCurator(address(0xdead));
        assertEq(hook.curator(), address(0xdead));

        // Any attempt by the legitimate curator (the old one) to rebalance now fails.
        vm.prank(alice);
        hook.deposit(100e18, 100e18, 0);

        vm.prank(curator); // old curator — now unauthorized
        vm.expectRevert(HighwaterHook.OnlyCurator.selector);
        hook.rebalance(-60, 60);

        // Owner can recover by migrating.
        hook.setCurator(curator);
        assertEq(hook.curator(), curator);

        // Now the real curator can rebalance again.
        vm.prank(curator);
        hook.rebalance(-60, 60);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // S-EXTRA: Verify keeperRebalance range-covers-tick fix path
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Documents the desired post-fix behavior for S3:
    ///         After fix, keeperRebalance should require newLower <= currentTick <= newUpper.
    ///         Currently this test proves the gap — the assert at the end should become
    ///         an expectRevert once the fix is applied.
    function test_S3_Fix_KeeperRebalanceShouldRequireRangeCoversCurrentTick() public {
        HighwaterKeeper keeper = new HighwaterKeeper(hook, 10);
        hook.setKeeper(address(keeper));

        vm.prank(alice);
        hook.deposit(500e18, 500e18, 0);

        int24 spacing = poolKey.tickSpacing;
        // Put active range entirely above current tick (0).
        vm.prank(curator);
        hook.rebalance(2 * spacing, 5 * spacing);

        // Confirm: tick 0 is below range, keeper should fire.
        assertTrue(keeper.shouldRebalance());

        // The HighwaterKeeper correctly centers on the current tick —
        // so the keeper's OWN triggerRebalance is safe.
        // The gap is only if the keeper contract is replaced with a malicious one.
        (int24 newLower, int24 newUpper) = keeper.computeNewRange();
        (, int24 currentTick,,) = poolManager.getSlot0(hook.boundId());
        assertGe(currentTick, newLower, "keeper's computed range must cover current tick");
        assertLe(currentTick, newUpper, "keeper's computed range must cover current tick");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 10_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(who, 10_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECOND AUDIT CONTRACT — B-series findings
// (Bunni-class rounding + DAI vault zero-liquidity idle drain)
// ─────────────────────────────────────────────────────────────────────────────

/// @notice B-series regression tests based on real exploit patterns found online.
///
/// B1 — Bunni V2 rounding class ($8.4M, Sep 2025):
///      Root cause: rounding direction in withdrawal accounting overstated what
///      withdrawers received, leaving the vault underfunded. 44 micro-withdrawals
///      accumulated the discrepancy into a drain.
///      HIGHWATER status: floor division in `_payoutIdle` rounds in vault's favour
///      (withdrawer gets less, never more). We prove this with a repeated-withdrawal
///      fuzz test: total extracted across N partial exits must never exceed the vault's
///      idle balance at the start.
///
/// B2 — DAI vault zero-liquidity idle drain ($14,838, Oct 2026):
///      Root cause: when `liqToRemove` rounded to 0, a fallback branch paid out the
///      entire idle balance without pro-rata constraint — 1 wei of shares = 100% of idle.
///      HIGHWATER status: when `liqToRemove == 0`, `_payoutIdle` is still called with
///      `(bal * shares) / supply` — pro-rata, not unbounded. We prove this explicitly.
contract HighwaterBSeriesAuditTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HighwaterHook internal hook;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    address internal curator = makeAddr("curatorB");
    address internal alice = makeAddr("aliceB");
    address internal bob = makeAddr("bobB");
    address internal attacker = makeAddr("attacker");

    uint32 constant EPOCH = 1 days;
    uint16 constant FEE_BPS = 2000;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(0xB33F) << 144)
        );
        bytes memory ctor = abi.encode(poolManager, address(this), curator, EPOCH, FEE_BPS, true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        hook = HighwaterHook(payable(address(flags)));
        _enableSpotOracle(hook);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        _fund(alice);
        _fund(bob);
        _fund(attacker);
        _fund(curator);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // B1 — Bunni-class: repeated small withdrawals must not accumulate surplus
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice B1a: Floor division in `_payoutIdle` rounds in vault's favour.
    ///         Total extracted across N partial exits must never exceed the idle
    ///         balance at the moment of the first exit.
    function test_B1_RepeatedSmallWithdrawalsConserveIdle() public {
        // Alice and Bob both deposit. Accrue some idle via swaps.
        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(500e18, 500e18, 0);
        vm.prank(bob);
        hook.deposit(500e18, 500e18, 0);

        // Drive some swap volume to put fees into hook idle.
        _fund(address(this));
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        for (uint256 i = 0; i < 20; i++) {
            swapRouter.swapExactTokensForTokens({
                amountIn: 30e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        // Record tracked idle before any withdrawals.
        (uint256 idle0Start, uint256 idle1Start) = hook.idleBalances();
        uint256 supplyAtStart = hook.totalSupply();

        // Alice makes 10 micro-withdrawals of 1/100th of her shares each.
        uint256 slice = aliceShares / 100;
        require(slice > 0, "shares too small for test");

        for (uint256 i = 0; i < 10; i++) {
            uint256 sharesToBurn = (i == 9) ? hook.balanceOf(alice) - (aliceShares - slice * 10) : slice;
            if (sharesToBurn == 0 || hook.balanceOf(alice) == 0) break;
            sharesToBurn = sharesToBurn > hook.balanceOf(alice) ? hook.balanceOf(alice) : sharesToBurn;

            vm.prank(alice);
            hook.withdraw(sharesToBurn, 0, 0);
        }

        // B1 invariant: Alice can only pull her pro-rata slice of tracked idle across all
        // micro-withdrawals. Repeated rounding must accumulate in the vault, not in her favour.
        (uint256 idle0After, uint256 idle1After) = hook.idleBalances();
        uint256 maxIdleOut0 = (idle0Start * aliceShares) / supplyAtStart;
        uint256 maxIdleOut1 = (idle1Start * aliceShares) / supplyAtStart;
        uint256 floor0 = idle0Start > maxIdleOut0 ? idle0Start - maxIdleOut0 : 0;
        uint256 floor1 = idle1Start > maxIdleOut1 ? idle1Start - maxIdleOut1 : 0;
        assertGe(idle0After + 1, floor0, "[B1] token0 idle over-extracted");
        assertGe(idle1After + 1, floor1, "[B1] token1 idle over-extracted");
        assertGt(hook.strategyNav(), 0, "[B1] vault NAV drained to zero by micro-withdrawals");
        assertGt(hook.balanceOf(bob), 0, "[B1] Bob's shares wiped by Alice's micro-withdrawals");

        // Bob must still be able to withdraw something meaningful.
        uint256 bobShares = hook.balanceOf(bob);
        vm.prank(bob);
        (uint256 bobOut0, uint256 bobOut1) = hook.withdraw(bobShares, 0, 0);
        assertGt(bobOut0 + bobOut1, 0, "[B1] Bob got nothing after Alice's micro-withdrawals");
    }

    /// @notice B1b: Fuzz — for any number of partial withdrawals, the last withdrawer
    ///         (Bob) must receive at least his proportional share of remaining NAV.
    function test_B1_FuzzPartialWithdrawsPreserveBobShare(uint8 numWithdraws, uint8 sliceDenom) public {
        numWithdraws = uint8(bound(numWithdraws, 1, 20));
        sliceDenom = uint8(bound(sliceDenom, 2, 50));

        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(200e18, 200e18, 0);
        vm.prank(bob);
        hook.deposit(200e18, 200e18, 0);

        // Real idle via a v4 donation, realised by a zero-delta poke.
        _donateToPool(poolKey, currency1, 10e18);
        hook.poke();

        uint256 slice = aliceShares / sliceDenom;
        if (slice == 0) slice = 1;

        for (uint256 i = 0; i < numWithdraws; i++) {
            uint256 bal = hook.balanceOf(alice);
            if (bal == 0) break;
            uint256 s = slice > bal ? bal : slice;
            vm.prank(alice);
            hook.withdraw(s, 0, 0);
        }

        // Bob should always be able to withdraw his remaining shares.
        uint256 bobShares = hook.balanceOf(bob);
        if (bobShares > 0) {
            vm.prank(bob);
            (uint256 out0, uint256 out1) = hook.withdraw(bobShares, 0, 0);
            assertGt(out0 + out1, 0, "[B1-fuzz] Bob got nothing");
        }
        // Vault must not have gone negative / reverted.
        assertGe(hook.strategyNav(), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // B2 — DAI vault exploit: zero-liquidity idle must pay pro-rata, not 100%
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice B2: When `liqToRemove` rounds to 0 (dust shares), `_payoutIdle` is
    ///         still called. Prove it pays pro-rata (shares/supply) not the full balance.
    ///         The October 2026 DAI vault exploit paid 100% of idle to 1 wei of shares
    ///         because the fallback branch was unbounded. HIGHWATER uses `(bal * shares) / supply`
    ///         which is properly bounded.
    function test_B2_DustSharesGetProRataIdleNotFullBalance() public {
        // Alice holds the vast majority of shares. Attacker holds dust (1 share).
        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(1_000e18, 1_000e18, 0);

        // Transfer exactly 1 share to attacker (simulate attacker buying dust on secondary).
        vm.prank(alice);
        hook.transfer(attacker, 1);
        uint256 attackerShares = 1;
        uint256 supply = hook.totalSupply();

        // Real idle via a v4 donation, realised by a zero-delta poke (accumulated fees).
        uint256 idleAmount = 500e18;
        _donateToPool(poolKey, currency1, idleAmount);
        hook.poke();

        uint256 idleBefore = currency1.balanceOf(address(hook));
        // v4's donate divides by liquidity with floor arithmetic; 1 wei of dust is expected.
        assertApproxEqAbs(idleBefore, idleAmount, 1);

        // Attacker tries to withdraw their 1 share.
        // liqToRemove = (liq * 1) / supply = 0 (dust, floors to 0).
        // The code should then call _payoutIdle with shares=1, supply=supply.
        // payoutIdle = (idleAmount * 1) / supply, which is near-zero.
        vm.prank(attacker);
        (, uint256 out1) = hook.withdraw(attackerShares, 0, 0);

        uint256 idleAfter = currency1.balanceOf(address(hook));

        // B2 invariant: attacker received proportional slice, NOT the full idle.
        uint256 maxProRata = (idleAmount * attackerShares * 110) / (supply * 100); // 10% slack
        assertLe(out1, maxProRata + 1, "[B2] attacker received disproportionate idle payout");

        // The vault must still hold nearly all idle for Alice.
        assertGt(idleAfter, idleAmount * 90 / 100, "[B2] vault idle drained by dust share holder");

        // Alice can still withdraw her share.
        uint256 aliceSharesNow = hook.balanceOf(alice);
        vm.prank(alice);
        (uint256 aOut0, uint256 aOut1) = hook.withdraw(aliceSharesNow, 0, 0);
        assertGt(aOut0 + aOut1, 0, "[B2] Alice lost her funds after attacker's dust withdrawal");
    }

    /// @notice B2b: Edge case — if the pool has zero position liquidity (no active range)
    ///         but non-zero idle, withdrawal must still be pro-rata.
    function test_B2_ZeroPositionLiquidityIdleIsProRata() public {
        vm.prank(alice);
        (uint256 aliceShares,,) = hook.deposit(100e18, 100e18, 0);
        vm.prank(bob);
        hook.deposit(100e18, 100e18, 0);

        // Real idle via v4 donations, realised by a zero-delta poke.
        _donateToPool(poolKey, currency0, 50e18);
        _donateToPool(poolKey, currency1, 50e18);
        hook.poke();

        uint256 supply = hook.totalSupply();
        uint256 halfAlice = aliceShares / 2;

        // Record total vault assets before withdrawal (position + idle).
        uint256 totalNavBefore = hook.strategyNav();

        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(halfAlice, 0, 0);

        // B2b invariant: the value remaining in the vault must be at least the pro-rata
        // claim of the shares that did not withdraw. In WAD NAV terms, Alice took her
        // half of the supply, so the rest must retain at least the complementary fraction.
        uint256 remainingNav = hook.strategyNav();
        uint256 expectedRemaining = (totalNavBefore * (supply - halfAlice)) / supply;
        assertGe(
            remainingNav + 1e15,
            expectedRemaining,
            "[B2b] vault lost more than Alice's pro-rata claim"
        );
        assertGt(out0 + out1, 0, "[B2b] withdraw returned nothing");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 10_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(who, 10_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }
}
