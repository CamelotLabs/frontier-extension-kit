// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {BuyVolumeObserver} from "contracts/examples/BuyVolumeObserver.sol";
import {LaunchFeeCalculator} from "contracts/examples/LaunchFeeCalculator.sol";

/**
 * @notice Deploys the example extensions. Replace them with yours.
 * @dev Dry run, then broadcast with a Foundry keystore account:
 *   forge script script/Deploy.s.sol --rpc-url robinhood
 *   forge script script/Deploy.s.sol --rpc-url robinhood --account <name> --broadcast \
 *     --verify --verifier sourcify
 */
contract Deploy is Script {
    /// @dev Frontier `BCTokenFactory` on Robinhood Chain (4663). Override with `BC_TOKEN_FACTORY`.
    address internal constant ROBINHOOD_FACTORY = 0xe3A826C056e578c240D362BF4C2fa53E5c0c17a5;

    function run() external returns (LaunchFeeCalculator calculator, BuyVolumeObserver observer) {
        address factory = vm.envOr("BC_TOKEN_FACTORY", ROBINHOOD_FACTORY);
        require(factory.code.length != 0, "BC_TOKEN_FACTORY has no code on this chain");

        vm.startBroadcast();
        calculator = new LaunchFeeCalculator(factory);
        observer = new BuyVolumeObserver(factory);
        vm.stopBroadcast();

        console.log("LaunchFeeCalculator:", address(calculator));
        console.log("BuyVolumeObserver:  ", address(observer));
    }
}
