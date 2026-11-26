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

/// @notice Priority-0 regressions: tracked idle inventory and rolling HODL benchmark.
contract HighwaterP0Test is BaseTest {
    using CurrencyLibrary for Currency;

    Currency c0;
    Currency c1;
    address curator = makeAddr("curatorP0");
    address alice = makeAddr("aliceP0");
    address bob = makeAddr("bobP0");
    address attacker = makeAddr("attackerP0");
    uint32 constant EPOCH = 1 days;
    uint160 seed = 0xC0DE;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();
        _fundApprove(alice);
        _fundApprove(bob);
        _fundApprove(attacker);
    }

    function _deploy() internal returns (HighwaterHook h, PoolKey memory k) {
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | uint256(uint160(seed) << 144)
        );
        seed++;
        bytes memory ctor = abi.encode(poolManager, address(this), curator, EPOCH, uint16(2000), true);
        deployCodeTo("HighwaterHook.sol:HighwaterHook", ctor, address(flags));
        h = HighwaterHook(payable(address(flags)));
        _enableSpotOracle(h);
        k = PoolKey(c0, c1, 3000, 60, IHooks(address(h)));
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);
    }

    function test_UnsolicitedTransferDoesNotMoveNavOrShares() public {
        (HighwaterHook h, PoolKey memory k) = _deploy();
        k; // silence unused warning; this test only needs the hook
        _approveHook(attacker, address(h));
        _approveHook(bob, address(h));

        vm.prank(attacker);
        (uint256 attShares,,) = h.deposit(1e18, 1e18, 0);
        uint256 navBefore = h.strategyNav();

        // Classic ERC-4626 inflation attack: donate directly to the vault.
        MockERC20(Currency.unwrap(c1)).mint(attacker, 1_000_000e18);
        MockERC20(Currency.unwrap(c1)).transfer(address(h), 1_000_000e18);

        assertEq(h.strategyNav(), navBefore, "unsolicited transfer must not move NAV");
        (uint256 idle0, uint256 idle1) = h.idleBalances();
        assertEq(idle0, 0);
        assertEq(idle1, 0);

        vm.prank(bob);
        (uint256 bobShares,,) = h.deposit(100e18, 100e18, 0);
        // At 1:1, 100 token0 + 100 token1 ≈ 200e18 NAV against ~2e18 supply: ~100e18 shares.
        assertGt(bobShares, 99e18, "donation inflated the share price");
        assertGt(attShares, 0);
    }

    function test_UnsolicitedTransferDoesNotCreateCuratorFee() public {
        (HighwaterHook h, PoolKey memory k) = _deploy();
        _approveHook(alice, address(h));
        vm.prank(alice);
        h.deposit(100e18, 100e18, 0);

        MockERC20(Currency.unwrap(c1)).mint(alice, 50e18);
        vm.prank(alice);
        MockERC20(Currency.unwrap(c1)).transfer(address(h), 50e18);

        vm.warp(block.timestamp + EPOCH + 1);
        (uint256 fee, uint256 shares) = h.settleEpoch();
        assertEq(fee, 0, "direct donation must not create billable alpha");
        assertEq(shares, 0);

        // Owner can recover the unsolicited tokens without touching shareholder idle.
        uint256 balBefore = MockERC20(Currency.unwrap(c1)).balanceOf(address(this));
        h.sweepUnexpected(address(Currency.unwrap(c1)), address(this));
        assertEq(MockERC20(Currency.unwrap(c1)).balanceOf(address(this)) - balBefore, 50e18);
        (, uint256 idle1) = h.idleBalances();
        assertEq(idle1, 0);
    }

    function test_MidEpochDepositDoesNotInflateCuratorFee() public {
        // Baseline: alpha from a v4 donation, then settle.
        (HighwaterHook base, PoolKey memory baseKey) = _deploy();
        _approveHook(alice, address(base));
        vm.prank(alice);
        base.deposit(100e18, 100e18, 0);
        _donateToPool(baseKey, c1, 50e18);
        vm.warp(block.timestamp + EPOCH + 1);
        (uint256 feeNoDeposit,) = base.settleEpoch();

        // Same alpha, but a large deposit arrives mid-epoch.
        (HighwaterHook withDeposit, PoolKey memory depositKey) = _deploy();
        _approveHook(alice, address(withDeposit));
        _approveHook(bob, address(withDeposit));
        vm.prank(alice);
        withDeposit.deposit(100e18, 100e18, 0);
        _donateToPool(depositKey, c1, 50e18);
        vm.prank(bob);
        withDeposit.deposit(1_000e18, 1_000e18, 0);
        vm.warp(block.timestamp + EPOCH + 1);
        (uint256 feeWithDeposit,) = withDeposit.settleEpoch();

        assertGt(feeNoDeposit, 0, "baseline should charge a performance fee");
        // The deposit resets the HODL benchmark to current inventory, which absorbs any
        // alpha accrued before it. It must never increase the curator's fee.
        assertLe(feeWithDeposit, feeNoDeposit, "mid-epoch deposit inflated the curator fee");
    }

    function test_NoOracleFailsClosed() public {
        (HighwaterHook h, PoolKey memory oracleKey) = _deploy();
        h.setPriceOracle(address(0));
        _approveHook(alice, address(h));
        vm.prank(alice);
        h.deposit(100e18, 100e18, 0);
        _donateToPool(oracleKey, c1, 50e18);
        vm.warp(block.timestamp + EPOCH + 1);
        (uint256 fee, uint256 shares) = h.settleEpoch();
        assertEq(fee, 0, "no oracle must fail closed");
        assertEq(shares, 0);
    }

    function test_DivergentOracleFailsClosed() public {
        (HighwaterHook h, PoolKey memory oracleKey) = _deploy();
        _approveHook(alice, address(h));
        vm.prank(alice);
        h.deposit(100e18, 100e18, 0);
        _donateToPool(oracleKey, c1, 50e18);
        spotOracle.setFixedPrice(1); // wildly below spot
        vm.warp(block.timestamp + EPOCH + 1);
        (uint256 fee, uint256 shares) = h.settleEpoch();
        assertEq(fee, 0, "divergent oracle must fail closed");
        assertEq(shares, 0);
    }

    function test_PriceDeviationIsBounded() public {
        (HighwaterHook h,) = _deploy();
        h.setPriceDeviationBps(1_500);
        assertEq(h.priceDeviationBps(), 1_500);
        vm.expectRevert(HighwaterHook.InvalidFee.selector);
        h.setPriceDeviationBps(2_001);
    }

    function _fundApprove(address who) internal {
        MockERC20(Currency.unwrap(c0)).mint(who, 10_000_000e18);
        MockERC20(Currency.unwrap(c1)).mint(who, 10_000_000e18);
    }

    function _approveHook(address who, address h) internal {
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(h, type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(h, type(uint256).max);
        vm.stopPrank();
    }
}
