// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HighwaterHook} from "../src/HighwaterHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice ≤5 min pitch loop as a re-runnable Foundry receipt.
/// Run: forge test --match-contract DemoScoreboard -vv
contract DemoScoreboardTest is BaseTest {
    using CurrencyLibrary for Currency;

    HighwaterHook internal hook;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");

    uint32 constant EPOCH = 1 days;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(0xDE20) << 144)
        );
        bytes memory ctor = abi.encode(poolManager, address(this), curator, EPOCH, uint16(2000), true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        hook = HighwaterHook(payable(address(flags)));

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        MockERC20(Currency.unwrap(currency0)).mint(alice, 5_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(alice, 5_000_000e18);
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_PitchLoop_UnderperformThenOutperform() public {
        console2.log("HIGHWATER demo scoreboard");

        // 1) Deposit
        vm.prank(alice);
        (uint256 shares,,) = hook.deposit(500e18, 500e18, 0);
        console2.log("1 deposit shares", shares);
        console2.log("  strategyNav", hook.strategyNav());
        console2.log("  benchmarkNav", hook.benchmarkNav());

        // 2) Curator rebalances
        int24 spacing = poolKey.tickSpacing;
        vm.prank(curator);
        hook.rebalance(-50 * spacing, 50 * spacing);
        console2.log("2 rebalanced ticks", uint256(int256(hook.tickLower())), uint256(int256(hook.tickUpper())));

        // 3) Epoch elapses, no alpha → fee 0
        vm.warp(block.timestamp + EPOCH + 1);
        (uint256 fee0, uint256 curShares0) = hook.settleEpoch();
        console2.log("3 settle (no alpha) fee", fee0);
        console2.log("  curatorShares", curShares0);
        assertEq(fee0, 0);

        // 4) Simulate outperformance (idle inventory lands after HODL snapshot)
        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 80e18);
        console2.log("4 injected alpha strategyNav", hook.strategyNav());
        console2.log("  benchmarkNav", hook.benchmarkNav());

        vm.warp(block.timestamp + EPOCH + 1);
        (uint256 fee1, uint256 curShares1) = hook.settleEpoch();
        console2.log("5 settle (alpha) fee", fee1);
        console2.log("  curatorShares", curShares1);
        console2.log("  highWaterMark", hook.highWaterMark());
        assertGt(fee1, 0);
        assertGt(curShares1, 0);

        // 5) Migrate curator
        address next = makeAddr("nextCurator");
        hook.migrateStrategy(next, -20 * spacing, 20 * spacing, true);
        console2.log("6 migrated curator", next);
        assertEq(hook.curator(), next);
    }
}
