require("@nomicfoundation/hardhat-toolbox");
require("@nomiclabs/hardhat-ethers");
require("dotenv").config();

const WETH = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9"; // Sepolia WETH address
const USDC = "0xda9d4f9b69ac6C22e444eD9aF0CfC043b7a7f53f"; // Sepolia USDC address

async function main() {
    try {
        const [deployer] = await ethers.getSigners();
        console.log("Interacting with contracts using the account:", deployer.address);

        const flashloanMaximizer = await ethers.getContractAt(
            "FlashloanMaximizerV3",
            "0x5Dc90dC3fd600FeF94B5e76e987da452Cce99FCE" // Replace with your deployed contract address
        );

        const tokenIn = WETH; // Replace with input token address if different
        const tokenOut = USDC; // Replace with output token address if different
        
        // Get pool information
        const poolInfo = await flashloanMaximizer.getPoolInfo(tokenIn, tokenOut);
        console.log("Pool information:", poolInfo);

        // Check liquidity
        const [hasLiquidity, reason] = await flashloanMaximizer.checkPoolLiquidity(tokenIn, tokenOut);
        console.log("Liquidity check:", { hasLiquidity, reason });

        if (!hasLiquidity) {
            console.log("Cannot proceed: ", reason);
            return;
        }

        // Check allowances
        const allowances = await flashloanMaximizer.checkAllowances(tokenIn, tokenOut);
        console.log("Current allowances:", allowances);

        // Ensure sufficient WETH balance
        const wethBalance = await ethers.provider.getBalance(deployer.address);
        console.log(`WETH Balance: ${ethers.utils.formatUnits(wethBalance, 18)}`);
        if (wethBalance.lt(ethers.utils.parseEther("1"))) {
            console.log("Insufficient WETH balance");
            return;
        }

        // Execute arbitrage with proper error handling
        const tx = await flashloanMaximizer.executeArbitrage(
            tokenIn,
            tokenOut,
            ethers.utils.parseEther("1"), // 1 WETH
            ethers.utils.parseUnits("1800", 6), // Minimum expected USDC (adjust as needed)
            {
                gasLimit: 1000000,
                gasPrice: await ethers.provider.getGasPrice()
            }
        );

        console.log("Transaction hash:", tx.hash);
        const receipt = await tx.wait();
        console.log("Transaction confirmed:", receipt);

    } catch (error) {
        console.error("Detailed error information:");
        console.error("Message:", error.message);
        console.error("Code:", error.code);
        console.error("Transaction:", error.transaction);
        if (error.error) {
            console.error("Provider error:", error.error);
        }
        throw error;
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
