// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "src/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SwapRouterMock is ISwapRouter {
    address private tokenIn;
    address private tokenOut;
    uint24 private fee;
    address private recipient;
    uint256 private deadline;
    uint256 private amountIn;
    uint256 private amountOutMinimum;
    uint160 private sqrtPriceLimitX96;
    uint256 private txValue;

    struct MockSwapData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        uint256 txValue;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut) {
        tokenIn = params.tokenIn;
        tokenOut = params.tokenOut;
        fee = params.fee;
        recipient = params.recipient;
        deadline = params.deadline;
        amountIn = params.amountIn;
        amountOutMinimum = params.amountOutMinimum;
        sqrtPriceLimitX96 = params.sqrtPriceLimitX96;
        txValue = msg.value;
    }

    function receivedSwap(address pool) external {
        UniswapV3PoolMock(pool).swap(tokenIn, tokenOut, amountIn, amountOutMinimum, recipient, deadline);
    }
}


// very simpliest mock for UniswapV3Pool for the tesing purposes. both function names and function implementations
// is very different in real pool contract. 
contract UniswapV3PoolMock{
    address public token0;
    address public token1;

    address public swapRouter;
    uint256 public reserve0;
    uint256 public reserve1;
    address public owner;

    constructor(address _token0, address _token1, address _swapRouter) {
        token0 = _token0;
        token1 = _token1;
        swapRouter = _swapRouter;
        owner = msg.sender;
    }

    // add the liquidity to the pool
    function addLiquidity(uint256 amount0, uint256 amount1) external payable {
        IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        IERC20(token1).transferFrom(msg.sender, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;
    }

    // remove the liquidity from the pool
    function removeLiquidity(uint256 amount0, uint256 amount1) external payable {
        reserve0 -= amount0;
        reserve1 -= amount1;
    }

    // token price should be calculated correctly
    function getQuote(address token) public view returns (uint256) {
        if (token == token0) {
            return reserve1 / reserve0;
        } else {
            return reserve0 / reserve1;
        }
    }

    // swap tokens
    function swap(address tokenIn,address tokenOut, uint256 amountIn, uint256 amountOutMinimum, address recipient, uint256 deadline) external payable {
        // transfer the tokens to the pool
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        
        // transfer the tokens to the recipient
        uint256 tokenOutAmount = getQuote(tokenOut);
        if(tokenOutAmount < amountOutMinimum){
            revert("UniswapV3Pool: INSUFFICIENT_OUTPUT_AMOUNT");
        }

        if(tokenOutAmount > IERC20(tokenOut).balanceOf(address(this))){
            revert("UniswapV3Pool: INSUFFICIENT_LIQUIDITY");
        }
        IERC20(tokenOut).transfer(recipient, tokenOutAmount);
    }
}