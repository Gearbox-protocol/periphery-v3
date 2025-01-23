import { defineConfig } from "@wagmi/cli";
import { foundry } from "@wagmi/cli/plugins";

export default defineConfig({
  out: "./generated.ts",
  contracts: [],
  plugins: [
    foundry({
      include: [
        "ITokenCompressor.sol/**.json",
        "IPriceFeedCompressor.sol/**.json"
      ],
    }),
  ],
});
