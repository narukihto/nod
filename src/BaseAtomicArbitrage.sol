// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10 <0.9.0;

error NotAuthorized();
error NotOwner();
error LengthMismatch();
error ArbitrageUnprofitable(uint256 required, uint256 actual);
error NoBalance();
error NoEthBalance();
error TransferFailed();
error EthTransferFailed();

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

// ==========================================
// BALANCER V3 BATCHROUTER INTERFACES
// ==========================================
struct SwapPathStep {
    address pool;
    address tokenOut;
    bytes userData;
}

struct SwapPathExactAmountIn {
    address tokenIn;
    uint256 exactAmountIn;
    SwapPathStep[] steps;
}

interface IBalancerV3BatchRouter {
    function swapExactIn(
        SwapPathExactAmountIn[] memory paths,
        uint256 deadline,
        uint256 minAmountOut
    ) external payable returns (uint256 totalAmountOut);
}

contract BaseAtomicArbitrage {
    address public constant BALANCER_V3_BATCH_ROUTER = 0x136f1efcc3f8f88516b9e94110d56fdbfb1778d1;

    address public owner;                      
    address public botAddress;                 
    mapping(address => bool) public whitelistedTargets; 

    modifier onlyAuthorized() {
        if (msg.sender != owner && msg.sender != botAddress) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    receive() external payable {}

    constructor(address _botAddress) {
        owner = 0x63Fd24a09B2d8eAa2eb16277B7C3B17512294143;
        botAddress = _botAddress;
    }

    function setTargetWhitelist(address target, bool status) external onlyOwner {
        whitelistedTargets[target] = status;
    }

    // ==========================================
    // OFFICIAL BALANCER V3 BATCHROUTER ARBITRAGE
    // ==========================================
    function executeBatchRouterArbitrage(
        address baseToken,
        uint256 initialAmountIn,
        uint256 minProfit,
        SwapPathExactAmountIn[] calldata paths
    ) external onlyAuthorized {
        // 1. Approve BatchRouter to spend the baseToken if needed
        IERC20 token = IERC20(baseToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        
        // Ensure approval is set for the official BatchRouter
        token.approve(BALANCER_V3_BATCH_ROUTER, initialAmountIn);

        uint256 minRequiredOut = initialAmountIn + minProfit;

        // 2. Execute swap through official BatchRouter
        uint256 totalAmountOut = IBalancerV3BatchRouter(BALANCER_V3_BATCH_ROUTER).swapExactIn(
            paths,
            block.timestamp + 60, // Deadline
            minRequiredOut
        );

        // 3. Profit Verification & Settlement
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 netProfit = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;

        if (totalAmountOut < minRequiredOut || netProfit < minProfit) {
            revert ArbitrageUnprofitable(minRequiredOut, totalAmountOut);
        }

        // 4. Send net profit to owner
        if (netProfit > 0) {
            if (!token.transfer(owner, netProfit)) revert TransferFailed();
        }
    }

    function withdrawToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NoBalance();
        if (!IERC20(token).transfer(owner, balance)) revert TransferFailed();
    }

    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoEthBalance();
        (bool success, ) = owner.call{value: balance}("");
        if (!success) revert EthTransferFailed();
    }

    function updateBotAddress(address _newBot) external onlyOwner {
        botAddress = _newBot;
    }
}
