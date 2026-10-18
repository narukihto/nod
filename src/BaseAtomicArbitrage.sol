// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10 <0.9.0;

error NotAuthorized();
error NotOwner();
error UntrustedLender();
error UntrustedInitiator();
error UntrustedOriginalInitiator();
error UntrustedAavePool();
error LengthMismatch();
error SelfCallBlocked();
error TargetUnauthorized(address target);
error ExternalCallFailed(bytes reason);
error ArbitrageUnprofitable(uint256 required, uint256 actual);
error BalancerRepaymentFailed();
error AaveApproveFailed();
error NoBalance();
error NoEthBalance();
error TransferFailed();
error EthTransferFailed();

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

interface IBalancerVault {
    function flashLoan(
        IFlashLoanRecipient recipient,
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

contract BaseAtomicArbitrage is IFlashLoanRecipient, IFlashLoanSimpleReceiver {
    address private constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address public constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

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

        whitelistedTargets[_parseAddress("0xcf77A3bA9Aab7D3E44917635033322DF3f564171")] = true; // Uniswap V3 Router
        whitelistedTargets[_parseAddress("0x2626664c2603336E57B271c5C0b26F421741e481")] = true; // Aerodrome Router
        whitelistedTargets[_parseAddress("0xcA1F7645EF1077CC178dFb42Cf5d2f840457DDBb")] = true; // BaseSwap Router
        whitelistedTargets[_parseAddress("0x1b81D678ffb9C0263b24A97847620C99d213eB14")] = true; // PancakeSwap V3 Router
    }

    function _parseAddress(string memory _a) internal pure returns (address) {
        bytes memory tmp = bytes(_a);
        uint160 iaddr = 0;
        uint160 b1;
        uint160 b2;
        for (uint256 i = 2; i < 42; i += 2) {
            iaddr *= 256;
            b1 = uint160(uint8(tmp[i]));
            b2 = uint160(uint8(tmp[i + 1]));
            if ((b1 >= 97) && (b1 <= 102)) b1 -= 87;
            else if ((b1 >= 65) && (b1 <= 70)) b1 -= 55;
            else b1 -= 48;
            if ((b2 >= 97) && (b2 <= 102)) b2 -= 87;
            else if ((b2 >= 65) && (b2 <= 70)) b2 -= 55;
            else b2 -= 48;
            iaddr += (b1 * 16 + b2);
        }
        return address(iaddr);
    }

    function setTargetWhitelist(address target, bool status) external onlyOwner {
        whitelistedTargets[target] = status;
    }

    function triggerBalancerArbitrage(
        address tokenToBorrow, 
        uint256 loanAmount, 
        bytes calldata swapPathData 
    ) external onlyAuthorized {
        IBalancerVault vault = IBalancerVault(BALANCER_VAULT);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(tokenToBorrow); 

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = loanAmount;           

        uint256 exactBalanceBefore = IERC20(tokenToBorrow).balanceOf(address(this));

        bytes memory protectedData = abi.encode(msg.sender, exactBalanceBefore, tokenToBorrow, swapPathData);
        vault.flashLoan(this, tokens, amounts, protectedData);
    }

    function triggerAaveArbitrage(
        address tokenToBorrow,
        uint256 loanAmount,
        bytes calldata swapPathData 
    ) external onlyAuthorized {
        uint256 exactBalanceBefore = IERC20(tokenToBorrow).balanceOf(address(this));
        bytes memory encodedParams = abi.encode(msg.sender, exactBalanceBefore, tokenToBorrow, swapPathData);

        IPool(AAVE_POOL).flashLoanSimple(
            address(this),
            tokenToBorrow,
            loanAmount,
            encodedParams,
            0
        );
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        if (msg.sender != BALANCER_VAULT) revert UntrustedLender();

        (address originalInitiator, , address tokenBorrowed, bytes memory realSwapPathData) = abi.decode(userData, (address, uint256, address, bytes));
        if (originalInitiator != owner && originalInitiator != botAddress) revert UntrustedOriginalInitiator();

        IERC20 token = tokens[0]; 
        uint256 amountToRepay = amounts[0] + feeAmounts[0]; 

        _approveRouters(tokenBorrowed, _parseAddress("0x4200000000000000000000000000000000000006"));

        _executeUniversalArbitrage(realSwapPathData);

        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter < amountToRepay) revert ArbitrageUnprofitable(amountToRepay, balanceAfter);

        if (!token.transfer(BALANCER_VAULT, amountToRepay)) revert BalancerRepaymentFailed();
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator, 
        bytes calldata params
    ) external override returns (bool) {
        if (msg.sender != AAVE_POOL) revert UntrustedAavePool();
        if (initiator != address(this) && initiator != owner && initiator != botAddress) revert UntrustedInitiator();

        (address originalInitiator, , address tokenBorrowed, bytes memory realSwapPathData) = abi.decode(params, (address, uint256, address, bytes));
        if (originalInitiator != owner && originalInitiator != botAddress) revert UntrustedOriginalInitiator();

        IERC20 token = IERC20(asset);
        uint256 amountToRepay = amount + premium;

        _approveRouters(tokenBorrowed, _parseAddress("0x4200000000000000000000000000000000000006"));

        _executeUniversalArbitrage(realSwapPathData);

        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter < amountToRepay) revert ArbitrageUnprofitable(amountToRepay, balanceAfter);

        token.approve(AAVE_POOL, 0);
        if (!token.approve(AAVE_POOL, amountToRepay)) revert AaveApproveFailed();

        return true;
    }

    function _approveRouters(address token1, address token2) internal {
        address uniswapRouter = _parseAddress("0xcf77A3bA9Aab7D3E44917635033322DF3f564171");
        address aerodromeRouter = _parseAddress("0x2626664c2603336E57B271c5C0b26F421741e481");
        address baseswapRouter = _parseAddress("0xcA1F7645EF1077CC178dFb42Cf5d2f840457DDBb");
        address pancakeswapRouter = _parseAddress("0x1b81D678ffb9C0263b24A97847620C99d213eB14");

        if (whitelistedTargets[uniswapRouter]) {
            IERC20(token1).approve(uniswapRouter, type(uint256).max);
            IERC20(token2).approve(uniswapRouter, type(uint256).max);
        }
        if (whitelistedTargets[aerodromeRouter]) {
            IERC20(token1).approve(aerodromeRouter, type(uint256).max);
            IERC20(token2).approve(aerodromeRouter, type(uint256).max);
        }
        if (whitelistedTargets[baseswapRouter]) {
            IERC20(token1).approve(baseswapRouter, type(uint256).max);
            IERC20(token2).approve(baseswapRouter, type(uint256).max);
        }
        if (whitelistedTargets[pancakeswapRouter]) {
            IERC20(token1).approve(pancakeswapRouter, type(uint256).max);
            IERC20(token2).approve(pancakeswapRouter, type(uint256).max);
        }
    }

    function _executeUniversalArbitrage(bytes memory realSwapPathData) internal {
        if(realSwapPathData.length == 0) return; 

        (address[] memory targets, bytes[] memory payloads) = abi.decode(realSwapPathData, (address[], bytes[]));
        uint256 length = targets.length;

        if (length != payloads.length) revert LengthMismatch();

        for (uint256 i = 0; i < length; i++) {
            address target = targets[i];

            if (target == address(this)) revert SelfCallBlocked();
            if (!whitelistedTargets[target]) revert TargetUnauthorized(target);

            (bool success, bytes memory returnData) = target.call(payloads[i]);

            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        let returndata_size := mload(returnData)
                        revert(add(returnData, 32), returndata_size)
                    }
                } else {
                    revert ExternalCallFailed(returnData);
                }
            }
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
