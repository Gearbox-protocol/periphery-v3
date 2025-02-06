import { defineConfig } from "@wagmi/cli";
import { foundry } from "@wagmi/cli/plugins";

export default defineConfig({
  out: "./generated.ts",
  contracts: [],
  plugins: [
    foundry({
      include: [
        "IAdapterCompressor.sol/**.json",
        "ICreditAccountCompressor.sol/**.json",
        "IDataCompressorV3.sol/**.json",
        "IGaugeCompressor.sol/**.json",
        "IMarketCompressor.sol/**.json",
        "IPeripheryCompressor.sol/**.json",
        "IPriceFeedCompressor.sol/**.json",
        "IRewardsCompressor.sol/**.json",
        "ITokenCompressor.sol/**.json",
      ],
    }),
  ],
});
