# Frontier Extension Kit

Build your own extensions for the [Frontier](https://frontier.fun) hook: fee calculators that set a
coin's swap fee, and observers that react to every swap. Test them against the **real**
`FactoryHook`, the exact source deployed on Robinhood Chain and published in
[FrontierFun/factory-hook](https://github.com/FrontierFun/factory-hook).

```sh
git clone --recurse-submodules <this repo> && cd frontier-extension-kit
forge test                          # local: real hook on a local Uniswap v4 stack, a few seconds
FOUNDRY_PROFILE=fork forge test     # live: a real coin on Robinhood Chain, through the real factory
                                    # (in CI: run the "Fork" workflow by hand from the Actions tab)
```

You need [Foundry](https://getfoundry.sh). Nothing else: the hook's source and every library it
builds with come from `lib/factory-hook`.

## How extensions work

A coin creator picks its extensions **once, at launch**, in the coin's `hookConfig` payload. They
stay bound to that coin's pool forever. One deployed extension serves any number of coins, and
each coin passes it its own config.

| | Fee calculator | Observer |
|---|---|---|
| Interface | `IFeeCalculator` | `IHookObserver` |
| Called | before every swap, to quote the fee | after every swap (and/or when the fee changes) |
| Can | return a fee (in pips, 10_000 = 1 %) | write its own state, emit events, hold funds |
| Cannot | write state (`staticcall`), see `hookData` | change the swap or block it |
| Budget | 50k gas per calculator | 600k gas shared by all of the pool's observers |
| If it fails | skipped, the previous fee passes through | ignored, the swap goes on |
| Per pool | up to 4, run in order | up to 8 |

Both implement a registration call (`onRegisterCalculator` / `onRegisterObserver`). The hook
makes that call inside the coin's deploy transaction, with the coin's config. It is the only
moment an extension can refuse a coin: reverting there fails the whole deploy.

One contract can play both roles on the same pool: list it in both places and implement both
interfaces (see `test/DualRoleExtension.t.sol`, where the observer side feeds the calculator side).

## Write your own

1. **Start from an example.** Copy `contracts/examples/LaunchFeeCalculator.sol` (a fee calculator) or
   `contracts/examples/BuyVolumeObserver.sol` (an observer). Each fits on one screen.
2. **Inherit `HookGated`** and call `_registerPool(poolId)` first thing in your registration
   function. It enforces the one rule every extension must follow, and gives you the hook to
   read the pool's coin and the hook's limits from.
3. **Gate state-changing notifications** with `onlyPoolHook(poolId)`. The arguments of
   `onAfterSwap` are the caller's, so anyone could call it to forge swaps if it were left open.
4. **Test** by inheriting `ExtensionCampaignBase`, Frontier's own harness (see the tests in
   `test/`). Useful helpers:

   | Helper | Does |
   |---|---|
   | `_deployGraduated(config, deployStaking)` | deploys a coin with your payload and graduates it: ready to swap |
   | `_swapEthForCoin(coin, who, amount)` / `_swapCoinForEth(...)` | buy / sell through the hooked pool |
   | `_swapEthForCoinWithHookData(coin, who, amount, hookData)` | buy with `hookData` |
   | `_newCoin` + `_registerCoin` | deploy without graduating; arm `vm.expectRevert` between the two to test a refused config |
   | `hook`, `factory`, `users.buyerOne` … | the real hook, the mock factory, funded users |

5. **Build the payload** a coin launches with, using `HookPayload`:

   ```solidity
   bytes memory hookConfig = HookPayload.encode(
       HookPayload.withFee(3000)                                              // 0.30 % base fee
           .addCalculator(address(myCalculator), abi.encode(uint24(20_000), uint32(1 hours)))
           .addObserver(address(myObserver), HookPayload.CALL_AFTER_SWAP, "")
   );
   ```

   `lpShareBps` (70 % by default) and `sniperWindow` are plain fields of the config: set them
   directly. The factory caps the whole payload at `maxHookConfigBytes` (4096 today).

6. **Run the fork test** (`test/fork/LiveRobinhood.t.sol`) with your extension, then deploy:
   `forge script script/Deploy.s.sol --rpc-url robinhood --account <keystore> --broadcast --verify --verifier sourcify`.
   `robinhood` is the public RPC, defined in `foundry.toml`; `.env.example` lists the optional
   overrides.

## Rules worth knowing

- **Registration must come from the hook (S1).** Pool ids are known before a coin exists, so an
  open registration can be claimed by someone else first and make the real deploy revert.
  `HookGated` handles it.
- **Keep calculators cheap and total.** Over 50k gas, or on any revert, the stage is skipped.
  Return `previousFee` when you have nothing to say. The hook clamps the final fee to 10 %
  (50 % during a declared sniper window) and never lets the protocol's 3 bps floor go.
- **`quoteFee` gets no `hookData`,** so a fee cannot depend on data the caller supplies.
  `tx.origin` is the only identity available.
- **A direct-seed coin is born graduated,** and the creator's own buy runs inside the deploy
  transaction, right after your registration: a launch-time fee applies to it too.
- **Observers run inside the swap's Uniswap unlock.** They may swap, but a v4 delta they leave
  unsettled reverts the swap (of their own pool only); a nested `unlock` reverts outright.
- **The swap `delta` an observer sees is net of the hook's non-LP fee.** On a buy that fee is in
  ETH, so what the buyer spent is `-delta.amount0() + feeAmount`. ETH is always `currency0`, so a
  negative `amount0` means a buy.
- **`hookData` is untrusted,** at most 256 bytes (longer is dropped). If you read an address from
  it, make sure a false one can only hurt its sender.
- **Registration can run more than once per pool**, in the same deploy transaction: once per
  role for a dual-role extension, or twice if the creator lists the same address twice.
  `HookGated` accepts it. If your config must be set only once, check that yourself.
- **Order matters for observers.** They share one gas budget in the order the creator listed
  them, and a greedy observer starves the ones after it.
- **Extensions are forever for the coins that bind them.** The hook never unbinds them, so
  treat any admin lever you add as a promise to every coin using it.
- **One deployment serves every hook generation.** A new Frontier hook only takes new coins,
  and `HookGated` pins each pool to the hook that registered it.

## Live addresses (Robinhood Chain, 4663)

| Contract | Address |
|---|---|
| `BCTokenFactory` | `0xe3A826C056e578c240D362BF4C2fa53E5c0c17a5` |
| `LiquidityManager` | `0x1716e590aB6eD7D0aC318C3033f8C4101f4f34c8` |
| `FactoryHook` v1.1 | `0xee588bCF2bd3e658f5160489f4199d1851BBf0Cc` |
| Uniswap v4 `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `DynamicFeeExtension` (official) | `0x0AC12a15b38903C443227D0e0cFC7E102893C493` |
| `SniperTaxExtension` (official) | `0x9CDE659adc4eC2FC3bfed0208DCFbe49f081e5c9` |
| `MaturityCurveExtension` (official) | `0x8BA6daE7182e33Bae7B21B2753cb5A6EDE2b03Cd` |

Always re-derive before relying on one:
`cast call <factory> "liquidityManager()(address)"`, then `cast call <manager> "hook()(address)"`.

## Updating to a new hook version

Frontier publishes each hook version as a folder of
[FrontierFun/factory-hook](https://github.com/FrontierFun/factory-hook) (`v1.1/`, then `v1.2/`, …).
The kit supports v1.1 and later. Build new extensions against the latest version only. To move
the kit to a new one:

```sh
script/use-hook-version.sh v1.2     # bumps the submodule, repoints remappings.txt, builds, tests
FOUNDRY_PROFILE=fork forge test     # once the new hook is live
```

Then update the table above and commit. The version the kit builds against is whatever folder
`remappings.txt` points to.

## Layout

```
contracts/
  HookGated.sol             registration rule (S1) + per-pool hook pinning
  HookPayload.sol           builds a coin's hookConfig
  examples/                 LaunchFeeCalculator, BuyVolumeObserver
test/                       example tests on the real hook (local)
test/fork/                  end to end on live Robinhood Chain
script/Deploy.s.sol         deploys the examples (replace with yours)
script/use-hook-version.sh  switches hook version
lib/factory-hook/           the published hook source, its tests and harness
```

The kit's own code lives in `contracts/`, not `src/`, because `src/` is remapped to the hook's
sources. That remapping is what lets Frontier's harness compile unchanged.

Your import paths: `frontier/…` for the hook's interfaces (`frontier/interfaces/extensions/IHookObserver.sol`),
`frontier-test/…` for its harness, and `contracts/…` for the kit.

## License

MIT (`LICENSE`).
