// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Deployers} from "./Deployers.sol";
import {HighwaterHook} from "../../src/HighwaterHook.sol";
import {SpotPriceOracle} from "./SpotPriceOracle.sol";

contract BaseTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    SpotPriceOracle internal spotOracle;

    /// @dev Wire the test-only spot oracle so settlement is not fail-closed.
    function _enableSpotOracle(HighwaterHook hook) internal {
        if (address(spotOracle) == address(0)) spotOracle = new SpotPriceOracle(poolManager);
        hook.setPriceOracle(address(spotOracle));
    }

    function deployArtifactsAndLabel() internal {
        deployArtifacts();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    function deployCurrencyPair() internal virtual override returns (Currency currency0, Currency currency1) {
        (currency0, currency1) = super.deployCurrencyPair();

        vm.label(Currency.unwrap(currency0), "Currency0");
        vm.label(Currency.unwrap(currency1), "Currency1");
    }

    function _etch(address target, bytes memory bytecode) internal override {
        vm.etch(target, bytecode);
    }

    /// @dev Test-side unlock callback used to drive `PoolManager.donate` in fork/local tests.
    ///      Donations are resolved in the same unlock as v4 requires.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amount0, uint256 amount1) = abi.decode(data, (PoolKey, uint256, uint256));
        poolManager.donate(key, amount0, amount1, "");
        key.currency0.settle(poolManager, address(this), amount0, false);
        key.currency1.settle(poolManager, address(this), amount1, false);
        return "";
    }

    /// @notice Create real, protocol-level alpha: donate through the PoolManager so the
    ///         fee growth is credited to the hook-owned position and realised on poke.
    function _donateToPool(PoolKey memory key, Currency currency, uint256 amount) internal {
        MockERC20(Currency.unwrap(currency)).mint(address(this), amount);
        MockERC20(Currency.unwrap(currency)).approve(address(poolManager), amount);
        if (currency == key.currency0) {
            poolManager.unlock(abi.encode(key, amount, uint256(0)));
        } else {
            poolManager.unlock(abi.encode(key, uint256(0), amount));
        }
    }
}
