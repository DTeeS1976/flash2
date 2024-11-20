//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@aave/core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

interface IQuoterV2 {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (
        uint256 amountOut,
        uint160 sqrtPriceX96After,
        uint32 initializedTicksCrossed,
        uint256 gasEstimate
    );
}

contract FlashloanMaximizerV3 is FlashLoanSimpleReceiverBase, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISwapRouter public immutable swapRouter;
    IQuoterV2 public immutable quoter;
    IUniswapV3Factory public immutable uniswapFactory;

    uint24 public constant poolFee = 3000;
    uint256 public constant MAX_SLIPPAGE = 1000;
    uint256 public slippageTolerance;
    uint256 public gasLimit;
    uint256 public gasPrice;

    error InvalidAddress();
    error InvalidPathLength();
    error InsufficientFunds();
    error InvalidCaller();
    error TransferFailed();
    error InvalidParameters();
    error SwapFailed();
    error GasEstimationFailed();
    error PoolNotFound();
    error InsufficientLiquidity();

    struct ArbitrageParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    event ArbitrageExecuted(uint256 profit, address tokenIn, address tokenOut);
    event ParametersUpdated(uint256 slippageTolerance, uint256 gasLimit, uint256 gasPrice);
    event FlashLoanReceived(address token, uint256 amount);
    event SwapExecuted(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event ExecutionStarted(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut);
    event GasEstimated(uint256 gasAmount);

    constructor(
        address _owner,
        address _swapRouter,
        address _quoter,
        address _uniswapFactory,
        address _lendingPoolAddressesProvider,
        uint256 _slippageTolerance,
        uint256 _gasLimit,
        uint256 _gasPrice
    )
        FlashLoanSimpleReceiverBase(IPoolAddressesProvider(_lendingPoolAddressesProvider))
        Ownable(_owner)
    {
        require(_owner != address(0), "Invalid owner address");
        require(_swapRouter != address(0), "Invalid router address");
        require(_quoter != address(0), "Invalid quoter address");
        require(_uniswapFactory != address(0), "Invalid factory address");
        require(_lendingPoolAddressesProvider != address(0), "Invalid provider address");
        require(_slippageTolerance > 0 && _slippageTolerance <= MAX_SLIPPAGE, "Invalid slippage");

        swapRouter = ISwapRouter(_swapRouter);
        quoter = IQuoterV2(_quoter);
        uniswapFactory = IUniswapV3Factory(_uniswapFactory);
        slippageTolerance = _slippageTolerance;
        gasLimit = _gasLimit;
        gasPrice = _gasPrice;
    }

    function calculateFlashLoanFee(uint256 amount) public pure returns (uint256) {
        return (amount * 9) / 10000; // 0.09% fee
    }

    function checkBasicConditions(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (bool valid, string memory reason) {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            return (false, "Invalid addresses");
        }

        address pool = uniswapFactory.getPool(tokenIn, tokenOut, poolFee);
        if (pool == address(0)) {
            return (false, "Pool not found");
        }

        uint256 flashLoanFee = calculateFlashLoanFee(amountIn);
        uint256 totalRequired = amountIn + flashLoanFee;

        uint256 poolBalance = IERC20(tokenIn).balanceOf(pool);
        if (poolBalance < totalRequired) {
            return (false, "Insufficient liquidity");
        }

        return (true, "Conditions met");
    }

    function checkArbitrageOpportunity(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (bool profitable, uint256 expectedProfit) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidAddress();

        address pool = uniswapFactory.getPool(tokenIn, tokenOut, poolFee);
        if (pool == address(0)) revert PoolNotFound();

        uint256 flashLoanFee = calculateFlashLoanFee(amountIn);
        uint256 totalRequired = amountIn + flashLoanFee;

        uint256 poolBalance = IERC20(tokenIn).balanceOf(pool);
        if (poolBalance < totalRequired) revert InsufficientLiquidity();

        try quoter.quoteExactInputSingle(
            tokenIn,
            tokenOut,
            poolFee,
            amountIn,
            0
        ) returns (
            uint256 amountOut,
            uint160 /* _sqrtPriceX96After */, // Commented out to indicate unused
            uint32 /* _initializedTicksCrossed */, // Commented out to indicate unused
            uint256 estimatedGas
        ) {
            uint256 estimatedGasCost = estimatedGas * gasPrice;
            uint256 minProfitRequired = flashLoanFee + estimatedGasCost;

            if (amountOut > minProfitRequired) {
                return (true, amountOut - minProfitRequired);
            }
            return (false, 0);
        } catch {
            revert GasEstimationFailed();
        }
    }
        function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address /* initiator */,
        bytes calldata params
    ) external override returns (bool) {
        if (msg.sender != address(POOL)) revert InvalidCaller();

        ArbitrageParams memory arbitrageParams = abi.decode(params, (ArbitrageParams));

        emit FlashLoanReceived(asset, amount);
        emit ExecutionStarted(arbitrageParams.tokenIn, arbitrageParams.tokenOut, amount, arbitrageParams.minAmountOut);

        // Approve the router to spend the borrowed tokens
        IERC20(asset).approve(address(swapRouter), amount);

        // Execute the swap
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: arbitrageParams.tokenIn,
            tokenOut: arbitrageParams.tokenOut,
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: arbitrageParams.minAmountOut,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut;
        try swapRouter.exactInputSingle(swapParams) returns (uint256 result) {
            amountOut = result;
        } catch {
            revert SwapFailed();
        }

        emit SwapExecuted(arbitrageParams.tokenIn, arbitrageParams.tokenOut, amount, amountOut);

        // Approve repayment
        uint256 amountToRepay = amount + premium;
        IERC20(asset).approve(address(POOL), amountToRepay);

        emit ArbitrageExecuted(amountOut, arbitrageParams.tokenIn, arbitrageParams.tokenOut);
        return true;
    }

    function executeArbitrage(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external onlyOwner whenNotPaused nonReentrant {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidAddress();
        if (amountIn == 0) revert InvalidParameters();
        if (minAmountOut == 0) revert InvalidParameters();
        
        // Check if tokens are valid ERC20
        try IERC20(tokenIn).totalSupply() {} catch {
            revert InvalidAddress();
        }
        try IERC20(tokenOut).totalSupply() {} catch {
            revert InvalidAddress();
        }
        
        // Check pool liquidity
        (bool hasLiquidity, string memory reason) = checkPoolLiquidity(tokenIn, tokenOut);
        if (!hasLiquidity) revert(reason);

        bytes memory params = abi.encode(
            ArbitrageParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                minAmountOut: minAmountOut
            })
        );

        // Emit event before execution
        emit ExecutionStarted(tokenIn, tokenOut, amountIn, minAmountOut);

        try IPool(POOL).flashLoanSimple(
            address(this),
            tokenIn,
            amountIn,
            params,
            0
        ) {
// Success
emit ArbitrageExecuted(minAmountOut, tokenIn, tokenOut);
} catch Error(string memory reason) {
    revert(string(abi.encodePacked("Flash loan failed: ", reason)));
} catch Panic(uint256 code) {
    revert(string(abi.encodePacked("Panic in flash loan: code=", _toString(code))));
} catch {
    revert("Flash loan failed with unknown error");
}

function _toString(uint256 value) internal pure returns (string memory) {
    if (value == 0) {
        return "0";
    }
    uint256 temp = value;
    uint256 digits;
    while (temp != 0) {
        digits++;
        temp /= 10;
    }
    bytes memory buffer = new bytes(digits);
    while (value != 0) {
        digits -= 1;
        buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
        value /= 10;
    }
    return string(buffer);
}

function getPoolInfo(
    address tokenIn,
    address tokenOut
) external view returns (
    address pool,
    uint256 balance0,
    uint256 balance1,
    bool exists
) {
    pool = uniswapFactory.getPool(tokenIn, tokenOut, poolFee);
    if (pool != address(0)) {
        balance0 = IERC20(tokenIn).balanceOf(pool);
        balance1 = IERC20(tokenOut).balanceOf(pool);
        exists = true;
    }
}

function checkPoolLiquidity(
    address tokenIn,
    address tokenOut
) public view returns (bool, string memory) {
    if (tokenIn == address(0) || tokenOut == address(0)) 
        return (false, "Invalid token addresses");
    
    address pool = uniswapFactory.getPool(tokenIn, tokenOut, poolFee);
    if (pool == address(0)) 
        return (false, "Pool does not exist");
    
    uint256 balance0;
    uint256 balance1;
    
    try IERC20(tokenIn).balanceOf(pool) returns (uint256 _balance0) {
        balance0 = _balance0;
    } catch {
        return (false, "Failed to get tokenIn balance");
    }
    
    try IERC20(tokenOut).balanceOf(pool) returns (uint256 _balance1) {
        balance1 = _balance1;
    } catch {
        return (false, "Failed to get tokenOut balance");
    }
    
    if (balance0 == 0 || balance1 == 0)
        return (false, "Insufficient pool liquidity");
        
    return (true, "Pool has sufficient liquidity");
}

function checkAllowances(
    address tokenIn,
    address tokenOut
) external view returns (uint256 poolAllowance, uint256 routerAllowance) {
    poolAllowance = IERC20(tokenIn).allowance(address(this), address(POOL));
    routerAllowance = IERC20(tokenIn).allowance(address(this), address(swapRouter));
}

function updateParameters(
    uint256 _slippageTolerance,
    uint256 _gasLimit,
    uint256 _gasPrice
) external onlyOwner {
    if (_slippageTolerance > MAX_SLIPPAGE) revert InvalidParameters();
    slippageTolerance = _slippageTolerance;
    gasLimit = _gasLimit;
    gasPrice = _gasPrice;
    emit ParametersUpdated(_slippageTolerance, _gasLimit, _gasPrice);
}

function withdrawToken(address token, uint256 amount) external onlyOwner {
    if (token == address(0)) revert InvalidAddress();
    IERC20(token).safeTransfer(owner(), amount);
}

function withdrawETH() external onlyOwner {
    uint256 balance = address(this).balance;
    (bool success, ) = owner().call{value: balance}("");
    if (!success) revert TransferFailed();
}

function pause() external onlyOwner {
    _pause();
}

function unpause() external onlyOwner {
    _unpause();
}

receive() external payable {}
}
