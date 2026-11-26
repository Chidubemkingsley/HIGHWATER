// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {HighwaterHook} from "./HighwaterHook.sol";

/// @title HighwaterKeeper
/// @notice Permissionless keeper that triggers a rebalance on a HighwaterHook
///         whenever the current pool tick drifts outside the hook's active range.
///
/// @dev Design decisions:
///
///   - Anyone may call `triggerRebalance`. The hook itself enforces the out-of-range
///     guard (`KeeperTickInRange` revert), so this contract doesn't need to repeat it.
///
///   - The new range is re-centered around the current tick with a configurable
///     half-width expressed in tick spacings. The curator sets `halfWidthSpacings`
///     when deploying or updating the keeper — it is not a free parameter for callers.
///
///   - The keeper address must be registered on the hook via `hook.setKeeper(address(this))`
///     by the owner before `triggerRebalance` will work.
///
/// Usage:
///   1. Owner deploys HighwaterKeeper(hook, halfWidthSpacings).
///   2. Owner calls hook.setKeeper(address(keeper)).
///   3. Any bot / EOA / automation network calls keeper.triggerRebalance() when needed.
///   4. Owner may call updateHalfWidth to adjust the range width at any time.
///   5. Owner may call hook.setKeeper(address(0)) to disable the keeper.

contract HighwaterKeeper {
    using StateLibrary for IPoolManager;
    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotOwner();
    error ZeroHalfWidth();
    error TickAlreadyInRange();

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event KeeperTriggered(address indexed caller, int24 newTickLower, int24 newTickUpper, int24 currentTick);
    event HalfWidthUpdated(uint24 oldHalfWidth, uint24 newHalfWidth);

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    HighwaterHook public immutable hook;
    IPoolManager public immutable poolManager;

    /// @notice Owner who may update `halfWidthSpacings`.
    address public immutable owner;

    /// @notice Number of tick spacings on each side of the current tick for the new range.
    /// @dev e.g. halfWidthSpacings = 10 with tickSpacing = 60 → range width = ±600 ticks.
    uint24 public halfWidthSpacings;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _hook            The HighwaterHook to manage.
    /// @param _halfWidthSpacings  Number of tick spacings on each side of current tick.
    constructor(HighwaterHook _hook, uint24 _halfWidthSpacings) {
        if (_halfWidthSpacings == 0) revert ZeroHalfWidth();
        hook = _hook;
        poolManager = _hook.poolManager();
        owner = msg.sender;
        halfWidthSpacings = _halfWidthSpacings;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns true when the current pool tick is outside the hook's active range.
    function shouldRebalance() public view returns (bool) {
        (, int24 currentTick,,) = poolManager.getSlot0(hook.boundId());
        return currentTick < hook.tickLower() || currentTick > hook.tickUpper();
    }

    /// @notice Computes the new [tickLower, tickUpper] that would be used by triggerRebalance.
    function computeNewRange() public view returns (int24 newLower, int24 newUpper) {
        (, int24 currentTick,,) = poolManager.getSlot0(hook.boundId());
        int24 spacing = hook.poolKey().tickSpacing;
        (newLower, newUpper) = _centeredRange(currentTick, spacing);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Actions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Trigger a rebalance. Reverts if the tick is still inside the current range
    ///         (the hook enforces this guard with `KeeperTickInRange`).
    /// @dev Callable by anyone — gas cost is paid by the caller (or automation network).
    function triggerRebalance() external {
        (, int24 currentTick,,) = poolManager.getSlot0(hook.boundId());

        // Early revert with a cleaner error before hitting the hook.
        if (currentTick >= hook.tickLower() && currentTick <= hook.tickUpper()) {
            revert TickAlreadyInRange();
        }

        int24 spacing = hook.poolKey().tickSpacing;
        (int24 newLower, int24 newUpper) = _centeredRange(currentTick, spacing);

        hook.keeperRebalance(newLower, newUpper);

        emit KeeperTriggered(msg.sender, newLower, newUpper, currentTick);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner admin
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Owner adjusts the half-width used for recentering.
    function updateHalfWidth(uint24 newHalfWidth) external {
        if (msg.sender != owner) revert NotOwner();
        if (newHalfWidth == 0) revert ZeroHalfWidth();
        uint24 old = halfWidthSpacings;
        halfWidthSpacings = newHalfWidth;
        emit HalfWidthUpdated(old, newHalfWidth);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Aligns the current tick to the nearest spacing multiple, then adds ±halfWidth.
    ///      Clamps to usable tick bounds so the hook's `_validateTicks` never reverts.
    function _centeredRange(int24 currentTick, int24 spacing) internal view returns (int24 newLower, int24 newUpper) {
        // Round current tick down to the nearest spacing multiple.
        int24 aligned = _alignTick(currentTick, spacing);

        int24 halfWidth = int24(uint24(halfWidthSpacings)) * spacing;
        int24 minTick = TickMath.minUsableTick(spacing);
        int24 maxTick = TickMath.maxUsableTick(spacing);

        newLower = aligned - halfWidth;
        newUpper = aligned + halfWidth;

        // Clamp to usable bounds.
        if (newLower < minTick) newLower = minTick;
        if (newUpper > maxTick) newUpper = maxTick;

        // Ensure lower < upper after clamping (edge case at extreme ticks).
        if (newLower >= newUpper) {
            newLower = minTick;
            newUpper = maxTick;
        }
    }

    /// @dev Floor-divides toward negative infinity (Solidity truncates toward zero for negatives).
    function _alignTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        // If tick is negative and not exactly on a boundary, subtract 1.
        if (tick < 0 && tick % spacing != 0) compressed -= 1;
        return compressed * spacing;
    }
}
