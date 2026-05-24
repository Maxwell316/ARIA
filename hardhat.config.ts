import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const PRIVATE_KEY = process.env.PRIVATE_KEY ?? "0x" + "0".repeat(64);
const SOMNIA_RPC  = process.env.SOMNIA_RPC  ?? "https://dream-rpc.somnia.network";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    // Local Hardhat network for unit tests
    hardhat: {
      chainId: 31337,
    },
    // Somnia Testnet
    somniaTestnet: {
      url: SOMNIA_RPC,
      chainId: 50312,
      accounts: [PRIVATE_KEY],
    },
  },
  etherscan: {
    // No Etherscan for Somnia yet — placeholder
    apiKey: {
      somniaTestnet: "no-key",
    },
    customChains: [
      {
        network: "somniaTestnet",
        chainId: 50312,
        urls: {
          apiURL:  "https://explorer.somnia.network/api",
          browserURL: "https://explorer.somnia.network",
        },
      },
    ],
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
  },
};

export default config;
