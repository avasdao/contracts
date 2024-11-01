require("@nomicfoundation/hardhat-toolbox")

const { vars } = require("hardhat/config")

/* Set private keys. */
const AVAS_DAO_DB_PRIVATE_KEY = vars.get("AVAS_DAO_DB_PRIVATE_KEY")
const SEPOLIA_PRIVATE_KEY = vars.get("SEPOLIA_PRIVATE_KEY")

/* Set API keys. */
const INFURA_API_KEY = vars.get("INFURA_API_KEY")
// const ALCHEMY_API_KEY = vars.get("ALCHEMY_API_KEY")

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.27",
  networks: {
    nxy: {
      url: `https://nxy.social/area51`,
      accounts: [AVAS_DAO_DB_PRIVATE_KEY],
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${INFURA_API_KEY}`,
      // url: `https://eth-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
      accounts: [SEPOLIA_PRIVATE_KEY],
      // accounts: [AVAS_DAO_DB_PRIVATE_KEY],
    },
  },
};
