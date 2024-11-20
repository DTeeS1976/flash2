require("dotenv").config();
const hre = require("hardhat");

async function main() {
  try {
    const [deployer] = await hre.ethers.getSigners();
    console.log("Deploying contracts with the account:", deployer.address);

    const balance = await hre.ethers.provider.getBalance(deployer.address);
    console.log("Account balance:", hre.ethers.utils.formatEther(balance));

    const ADDRESSES = {
      SWAP_ROUTER: '0xE592427A0AEce92De3Edee1F18E0157C05861564', // Uniswap V3 SwapRouter
      QUOTER: '0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6', // Uniswap V3 Quoter
      UNISWAP_FACTORY: '0x1F98431c8aD98523631AE4a59f267346ea31F984', // Uniswap V3 Factory
      AAVE_POOL_PROVIDER: '0x0496275d34753A48320CA58103d5220d394FF77F'
    };

    console.log("\nUsing addresses:");
    console.log("Uniswap V3 SwapRouter:", ADDRESSES.SWAP_ROUTER);
    console.log("Uniswap V3 Quoter:", ADDRESSES.QUOTER);
    console.log("Uniswap V3 Factory:", ADDRESSES.UNISWAP_FACTORY);
    console.log("AAVE Pool Provider:", ADDRESSES.AAVE_POOL_PROVIDER);

    const Flashloan = await hre.ethers.getContractFactory("FlashloanMaximizerV3");
    console.log("\nDeploying FlashloanMaximizerV3 contract...");

    const flashloan = await Flashloan.deploy(
      deployer.address,
      ADDRESSES.SWAP_ROUTER,
      ADDRESSES.QUOTER,
      ADDRESSES.UNISWAP_FACTORY,
      ADDRESSES.AAVE_POOL_PROVIDER,
      50, // 0.5% slippage tolerance
      5000000, // gas limit
      20 * 10 ** 9 // gas price in wei
    );

    console.log("Waiting for deployment...");
    await flashloan.deployTransaction.wait();

    const deployedAddress = flashloan.address;
    console.log("\nFlashloanMaximizerV3 deployed to:", deployedAddress);

    console.log("\nVerify with:");
    console.log(`npx hardhat verify --network sepolia ${deployedAddress} ${deployer.address} ${ADDRESSES.SWAP_ROUTER} ${ADDRESSES.QUOTER} ${ADDRESSES.UNISWAP_FACTORY} ${ADDRESSES.AAVE_POOL_PROVIDER} 50 5000000 20000000000`);
  } catch (error) {
    console.error("\nDeployment failed!");
    console.error(error);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
