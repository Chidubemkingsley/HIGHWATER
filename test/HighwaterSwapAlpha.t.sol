// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HighwaterHook} from "../src/HighwaterHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

/// @notice Swap-path alpha: fees accruing to the curated position beat frozen HODL inventory.
/// This is the non-airdrop proof that settle can mint a real performance fee.
contract HighwaterSwapAlphaTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    HighwaterHook internal hook;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    address internal curator = makeAddr("curator");
    address internal alice = makeAddr("alice");
    address internal trader = makeAddr("trader");

    uint32 constant EPOCH = 1 days;
    uint16 constant FEE_BPS = 2000;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(0xA11A) << 144)
        );
        bytes memory ctor = abi.encode(poolManager, address(this), curator, EPOCH, FEE_BPS, true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        hook = HighwaterHook(payable(address(flags)));

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        _fund(alice);
        _fund(trader);

        vm.startPrank(trader);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_SwapFeesCreateAlphaAndCuratorFee() public {
        // Deep full-range deposit so many swaps can clear.
        vm.prank(alice);
        hook.deposit(5_000e18, 5_000e18, 0);

        uint256 benchBefore = hook.benchmarkNav();
        uint256 stratBefore = hook.strategyNav();
        assertApproxEqRel(stratBefore, benchBefore, 0.01e18); // ~equal at open

        // Drive volume through the pool — LP fees accrue to the hook-owned position.
        for (uint256 i = 0; i < 20; i++) {
            bool zeroForOne = i % 2 == 0;
            vm.prank(trader);
            swapRouter.swapExactTokensForTokens({
                amountIn: 50e18,
                amountOutMin: 0,
                zeroForOne: zeroForOne,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: trader,
                deadline: block.timestamp + 1
            });
        }

        uint256 strategy = hook.strategyNav();
        uint256 bench = hook.benchmarkNav();

        // Fees (and inventory drift) should push strategy above frozen HODL bench.
        assertGt(strategy, bench, "swaps did not create measurable alpha vs HODL");

        vm.warp(block.timestamp + EPOCH + 1);

        uint256 curatorBefore = hook.balanceOf(curator);
        (uint256 feeWad, uint256 curatorShares) = hook.settleEpoch();

        assertGt(feeWad, 0, "expected performance fee from swap-earned alpha");
        assertGt(curatorShares, 0, "curator should receive fee shares");
        assertEq(hook.balanceOf(curator), curatorBefore + curatorShares);
        assertGt(hook.highWaterMark(), 1e18);
    }

    function test_RebalanceThenSwaps_StillSettlesClean() public {
        vm.prank(alice);
        hook.deposit(2_000e18, 2_000e18, 0);

        int24 spacing = poolKey.tickSpacing;
        vm.prank(curator);
        hook.rebalance(-100 * spacing, 100 * spacing);

        for (uint256 i = 0; i < 8; i++) {
            vm.prank(trader);
            swapRouter.swapExactTokensForTokens({
                amountIn: 20e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: trader,
                deadline: block.timestamp + 1
            });
        }

        vm.warp(block.timestamp + EPOCH + 1);
        // Must not revert whether alpha is positive or not.
        hook.settleEpoch();
        assertEq(hook.epochId(), 1);
    }

    function _fund(address who) internal {
        MockERC20(Currency.unwrap(currency0)).mint(who, 50_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(who, 50_000_000e18);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }
}
