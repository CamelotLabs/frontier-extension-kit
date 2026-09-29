// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCToken} from "frontier/interfaces/IBCToken.sol";
import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";
import {IBondingCurve} from "frontier/interfaces/IBondingCurve.sol";
import {IFactoryHook} from "frontier/interfaces/IFactoryHook.sol";

import {HookPayload} from "contracts/HookPayload.sol";
import {BuyVolumeObserver} from "contracts/examples/BuyVolumeObserver.sol";
import {LaunchFeeCalculator} from "contracts/examples/LaunchFeeCalculator.sol";

/// @notice The liquidity manager reads this test needs (not part of the published hook interfaces).
interface ILiquidityManagerView {
    function hook() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function getPoolKey(address coin) external view returns (PoolKey memory);
}

/**
 * @notice End to end against the LIVE Frontier contracts on Robinhood Chain: deploy the examples,
 * launch a real coin through the real factory with them in its payload, graduate it on the real
 * curve, buy on the real pool.
 * @dev Run: `FOUNDRY_PROFILE=fork forge test`. Uses `RPC_URL` (default: the public Robinhood RPC)
 * and forks the latest block unless `FORK_BLOCK_NUMBER` is set (pinning needs an archive RPC).
 */
contract LiveRobinhoodTest is Test {
    using HookPayload for IFactoryHook.HookConfigV2;

    /// @dev Frontier `BCTokenFactory` on Robinhood Chain (4663). Everything else is read from it.
    address internal constant FACTORY = 0xe3A826C056e578c240D362BF4C2fa53E5c0c17a5;

    IBCTokenFactory internal factory = IBCTokenFactory(FACTORY);
    ILiquidityManagerView internal liquidityManager;
    PoolSwapTest internal router;

    LaunchFeeCalculator internal calculator;
    BuyVolumeObserver internal observer;

    address internal buyer = makeAddr("buyer");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        uint256 blockNumber = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);

        liquidityManager = ILiquidityManagerView(factory.liquidityManager());
        router = new PoolSwapTest(IPoolManager(liquidityManager.POOL_MANAGER()));

        calculator = new LaunchFeeCalculator(FACTORY);
        observer = new BuyVolumeObserver(FACTORY);
        vm.deal(buyer, 10 ether);
    }

    function testFork_liveCoin_runsBothExtensions() public {
        address coin = _launchAndGraduate(
            HookPayload.withFee(HookPayload.DEFAULT_FIXED_FEE)
                .addCalculator(address(calculator), abi.encode(uint24(20_000), uint32(1 hours)))
                .addObserver(address(observer), HookPayload.CALL_AFTER_SWAP, "")
        );
        PoolKey memory key = liquidityManager.getPoolKey(coin);
        PoolId poolId = key.toId();
        IFactoryHook hook = IFactoryHook(liquidityManager.hook());

        assertEq(observer.hookOf(poolId), address(hook), "registered by the live hook");

        vm.prank(buyer, buyer);
        router.swap{value: 0.1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(observer.volumeOf(poolId, buyer), 0.1 ether, "observer saw the buy");
        assertEq(hook.getCurrentFee(poolId), 20_000, "launch fee applied");
    }

    /// @dev Launches on the default curve with `config` as the hook payload, then buys the whole
    /// curve so the coin graduates to its Uniswap v4 pool.
    function _launchAndGraduate(IFactoryHook.HookConfigV2 memory config) internal returns (address coin) {
        (uint256 virtualReserves, uint256 initialSupply,) = factory.initialParams();
        (,,, uint80 creationFee) = factory.feeConfig();
        vm.deal(address(this), creationFee);

        coin = factory.deploy{value: creationFee}(
            "Kit Test",
            "KIT",
            "Frontier extension kit fork test",
            "ipfs://kit",
            50,
            keccak256(abi.encode("kit", block.number)),
            IBCTokenFactory.LaunchConfig({
                directSeed: false, virtualReserves: virtualReserves, initialSupply: initialSupply, seedTick: 0
            }),
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            HookPayload.encode(config)
        );

        uint256 targetEth = IBCToken(coin).TARGET_ETH();
        vm.deal(address(this), targetEth * 2);
        IBondingCurve(factory.bondingCurve()).buy{value: targetEth * 2}(coin, address(0), 0);
        assertTrue(IBCToken(coin).isLPd(), "graduated");
    }

    receive() external payable {}
}
