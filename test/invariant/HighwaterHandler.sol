// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {HighwaterHook} from "../../src/HighwaterHook.sol";

/// @notice Fuzz actor for HIGHWATER stateful invariant campaign.
/// @dev fail_on_revert=false: random calls may revert (auth, slippage, epoch); that's fine.
contract HighwaterHandler is Test {
    using CurrencyLibrary for Currency;

    HighwaterHook public immutable hook;
    IUniswapV4Router04 public immutable swapRouter;
    PoolKey public key;
    Currency public currency0;
    Currency public currency1;

    address public immutable curator;
    address public immutable alice;
    address public immutable bob;

    uint256 public ghostDeposits;
    uint256 public ghostWithdraws;
    uint256 public ghostRebalances;
    uint256 public ghostSettles;
    uint256 public ghostSwaps;
    uint256 public ghostLastHwm;

    constructor(
        HighwaterHook hook_,
        IUniswapV4Router04 swapRouter_,
        PoolKey memory key_,
        Currency currency0_,
        Currency currency1_,
        address curator_,
        address alice_,
        address bob_
    ) {
        hook = hook_;
        swapRouter = swapRouter_;
        key = key_;
        currency0 = currency0_;
        currency1 = currency1_;
        curator = curator_;
        alice = alice_;
        bob = bob_;
        ghostLastHwm = hook.highWaterMark();
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actorSeed % 2 == 0 ? alice : bob;
        uint256 amt = bound(amountSeed, 1e18, 50e18);

        vm.startPrank(actor);
        try hook.deposit(amt, amt, 0) {
            ghostDeposits++;
        } catch {}
        vm.stopPrank();

        _trackHwm();
    }

    function withdraw(uint256 actorSeed, uint256 shareSeed) external {
        address actor = actorSeed % 2 == 0 ? alice : bob;
        uint256 bal = hook.balanceOf(actor);
        if (bal == 0) return;

        uint256 shares = bound(shareSeed, 1, bal);

        vm.startPrank(actor);
        try hook.withdraw(shares, 0, 0) {
            ghostWithdraws++;
        } catch {}
        vm.stopPrank();

        _trackHwm();
    }

    function rebalance(uint256 widthSeed) external {
        int24 spacing = key.tickSpacing;
        uint256 width = bound(widthSeed, 1, 20);
        int24 w = int24(uint24(width)) * spacing;

        vm.prank(curator);
        try hook.rebalance(-w, w) {
            ghostRebalances++;
        } catch {}

        _trackHwm();
    }

    function swap(uint256 dirSeed, uint256 amountSeed) external {
        bool zeroForOne = dirSeed % 2 == 0;
        uint256 amountIn = bound(amountSeed, 1e15, 5e18);

        address trader = alice;
        vm.startPrank(trader);
        try swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 1
        }) {
            ghostSwaps++;
        } catch {}
        vm.stopPrank();

        _trackHwm();
    }

    function warpAndSettle(uint256 warpSeed) external {
        uint256 extra = bound(warpSeed, 0, 3 days);
        vm.warp(block.timestamp + hook.epochDuration() + extra);

        try hook.settleEpoch() {
            ghostSettles++;
        } catch {}

        _trackHwm();
    }

    function _trackHwm() internal {
        uint256 hwm = hook.highWaterMark();
        // HWM must be non-decreasing across the whole campaign.
        if (hwm < ghostLastHwm) {
            // Leave a breadcrumb; the invariant assert will catch it too.
            revert("HWM_DECREASED");
        }
        ghostLastHwm = hwm;
    }
}
