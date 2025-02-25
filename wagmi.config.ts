import { defineConfig } from "@wagmi/cli";
import { foundry } from "@wagmi/cli/plugins";
import path from 'node:path';

export default defineConfig([
  {
    out: "./compressors.generated.ts",
    plugins: [
      foundry({
        artifacts: "out",
        forge: {
          build: false,
          clean: false,
          rebuild: false,
        },
        include: [
          "IAdapterCompressor.sol/**.json",
          "ICreditAccountCompressor.sol/**.json",
          "ICreditSuiteCompressor.sol/**.json",
          "IGaugeCompressor.sol/**.json",
          "IMarketCompressor.sol/**.json",
          "IPeripheryCompressor.sol/**.json",
          "IPoolCompressor.sol/**.json",
          "IPriceFeedCompressor.sol/**.json",
          "IRewardsCompressor.sol/**.json",
          "ITokenCompressor.sol/**.json",
        ],
      }),
    ],
  },
  {
    out: "./v310.generated.ts",
    plugins: [
      foundry({
        artifacts: "out",
        forge: {
          build: false,
          clean: false,
          rebuild: false,
        },
        include: [
          "IAddressProvider.sol/IAddressProvider.json",
          "IBotListV3.sol/IBotListV3.json",
          "ICreditConfiguratorV3.sol/ICreditConfiguratorV3.json",
          "ICreditFacadeV3.sol/ICreditFacadeV3.json",
          "ICreditFacadeV3Multicall.sol/ICreditFacadeV3Multicall.json",
          "ICreditManagerV3.sol/ICreditManagerV3.json",
          "IGaugeV3.sol/IGaugeV3.json",
          "ILossPolicy.sol/ILossPolicy.json",
          "IMarketConfigurator.sol/IMarketConfigurator.json",
          "IPoolQuotaKeeperV3.sol/IPoolQuotaKeeperV3.json",
          "IPoolV3.sol/IPoolV3.json",
          "IPriceOracleV3.sol/IPriceOracleV3.json",
          "ITumblerV3.sol/ITumblerV3.json",
        ],
        exclude: [
          "base/IAddressProvider.sol/IAddressProvider.json"
        ]
      }),
    ],
  }
]);
