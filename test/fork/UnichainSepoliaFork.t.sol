// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {HighwaterHook} from "../../src/HighwaterHook.sol";
import {BaseTest} from "../utils/BaseTest.sol";

/// @notice Full deposit -> rebalance -> settle cycle against the canonical Unichain Sepolia
///         PoolManager (0x00B036B58a818B1BC34d502D3fE730Db729e62AC, chain 1301).
///         Skips loudly when UNICHAIN_SEPOLIA_RPC_URL is unset; CI stays offline.
contract UnichainSepoliaForkTest is BaseTest {
    using CurrencyLibrary for Currency;

    HighwaterHook hook;
    PoolKey key;
    Currency c0;
    Currency c1;
    address curator = makeAddr("forkCurator");
    address alice = makeAddr("forkAlice");

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 1301, "wrong fork: expected Unichain Sepolia");
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(0xF0A5) << 144)
        );
        bytes memory ctor = abi.encode(poolManager, address(this), curator, uint32(1 days), uint16(2000), true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        hook = HighwaterHook(payable(address(flags)));
        key = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        _enableSpotOracle(hook);

        MockERC20(Currency.unwrap(c0)).mint(alice, 1_000e18);
        MockERC20(Currency.unwrap(c1)).mint(alice, 1_000e18);
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
        MockERC20(Currency.unwrap(c1)).mint(address(this), 100e18);
        MockERC20(Currency.unwrap(c1)).approve(address(poolManager), type(uint256).max);
    }

    function test_FullCycleOnCanonicalPoolManager() public {
        vm.prank(alice);
        (uint256 shares, uint256 used0, uint256 used1) = hook.deposit(100e18, 100e18, 0);
        assertGt(shares, 0);
        assertGt(used0 + used1, 0);
        assertGt(hook.strategyNav(), 0);
        assertGt(hook.benchmarkNav(), 0);

        vm.prank(curator);
        hook.rebalance(-60, 60);
        assertEq(hook.tickLower(), -60);
        assertEq(hook.tickUpper(), 60);

        // Real alpha through the canonical PoolManager, then settle.
        _donateToPool(key, c1, 20e18);
        vm.warp(hook.epochStartTimestamp() + hook.epochDuration() + 1);
        (uint256 fee, uint256 curatorShares) = hook.settleEpoch();
        assertGt(fee, 0, "canonical settle should charge on protocol alpha");
        assertGt(curatorShares, 0);
        assertEq(hook.epochId(), 1);
        assertGt(hook.highWaterMark(), 1e18);

        // A second exit path still works after settlement.
        vm.prank(alice);
        (uint256 out0, uint256 out1) = hook.withdraw(shares / 2, 0, 0);
        assertGt(out0 + out1, 0);
        assertGt(hook.strategyNav(), 0);
    }
}
