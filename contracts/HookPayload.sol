// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

/**
 * @title HookPayload
 * @notice Builds the `hookConfig` bytes a coin is deployed with (schema v2): a base fee, a chain of
 * fee calculators and a set of observers. The hook validates it inside the deploy transaction; an
 * invalid payload reverts the deploy.
 * @dev Usage:
 *   bytes memory payload = HookPayload.encode(
 *       HookPayload.withFee(3000).addCalculator(address(myCalculator), abi.encode(...))
 *           .addObserver(address(myObserver), HookPayload.CALL_AFTER_SWAP, "")
 *   );
 * `lpShareBps` (LP share of the total fee, 0..10_000) and `sniperWindow` (seconds after graduation
 * with the raised fee ceiling; needs at least one calculator) are plain fields: set them on the
 * config directly.
 */
library HookPayload {
    /// @notice The schema version byte the hook expects.
    uint8 internal constant VERSION = 2;

    /// @notice Observer subscription: notify after every settled swap.
    uint8 internal constant CALL_AFTER_SWAP = 1 << 0;

    /// @notice Observer subscription: notify when the applied fee changes.
    uint8 internal constant CALL_FEE_CHANGE = 1 << 1;

    /// @notice The hook's default base fee in pips (0.30 %).
    uint24 internal constant DEFAULT_FIXED_FEE = 3000;

    /// @notice The LP share the hook gives a coin launched without a payload (70 %).
    uint16 internal constant DEFAULT_LP_SHARE_BPS = 7000;

    /// @notice A config with base fee `fixedFee` (pips), the default LP share and no extension.
    function withFee(uint24 fixedFee) internal pure returns (IFactoryHook.HookConfigV2 memory config) {
        config.fixedFee = fixedFee;
        config.lpShareBps = DEFAULT_LP_SHARE_BPS;
    }

    /// @notice Appends a fee calculator; calculators run in the order they are added.
    function addCalculator(IFactoryHook.HookConfigV2 memory config, address calculator, bytes memory calculatorConfig)
        internal
        pure
        returns (IFactoryHook.HookConfigV2 memory)
    {
        uint256 n = config.feeCalculators.length;
        address[] memory calculators = new address[](n + 1);
        bytes[] memory configs = new bytes[](n + 1);
        for (uint256 i; i < n; ++i) {
            calculators[i] = config.feeCalculators[i];
            configs[i] = config.calculatorConfigs[i];
        }
        calculators[n] = calculator;
        configs[n] = calculatorConfig;
        config.feeCalculators = calculators;
        config.calculatorConfigs = configs;
        return config;
    }

    /// @notice Appends an observer subscribed to `calls` (`CALL_AFTER_SWAP`, `CALL_FEE_CHANGE`, or both).
    function addObserver(
        IFactoryHook.HookConfigV2 memory config,
        address observer,
        uint8 calls,
        bytes memory observerConfig
    ) internal pure returns (IFactoryHook.HookConfigV2 memory) {
        uint256 n = config.observers.length;
        IFactoryHook.ObserverConfig[] memory observers = new IFactoryHook.ObserverConfig[](n + 1);
        for (uint256 i; i < n; ++i) {
            observers[i] = config.observers[i];
        }
        observers[n] = IFactoryHook.ObserverConfig({observer: observer, calls: calls, config: observerConfig});
        config.observers = observers;
        return config;
    }

    /// @notice The bytes to pass as `hookConfig` to `BCTokenFactory.deploy`.
    function encode(IFactoryHook.HookConfigV2 memory config) internal pure returns (bytes memory) {
        return abi.encodePacked(VERSION, abi.encode(config));
    }
}
