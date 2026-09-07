// SPDX-License-Identifier: MIT
pragma solidity >=0.8.10 <0.9.0;

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
        require(msg.sender == owner || msg.sender == botAddress, "Not authorized");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    receive() external payable {}

    constructor(address _botAddress) {
        // تعيين عنوانك الحقيقي المالك الأساسي للعقد
        owner = 0x63Fd24a09B2d8eAa2eb16277B7C3B17512294143;
        botAddress = _botAddress;

        whitelistedTargets[_parseAddress("0xcf77A3bA9Aab7D3E44917635033322DF3f564171")] = true;
        whitelistedTargets[_parseAddress("0x2626664c2603336E57B271c5C0b26F421741e481")] = true;
        whitelistedTargets[_parseAddress("0x198FEe7650eAC16286848227e24eC0DFA5e51DA5")] = true;
        whitelistedTargets[_parseAddress("0x327Df1e6de05895D2Ab08513aADD931325260A99")] = true;
        whitelistedTargets[_parseAddress("0x089A8e0F6fCE8e00138F9b6E7Ff5B2FCC4Ac9D94")] = true;
        whitelistedTargets[_parseAddress("0x1b81D678ffb9C0263b24A97847620C99d213eB14")] = true;
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
        require(msg.sender == BALANCER_VAULT, "Untrusted lender");

        (address originalInitiator, , , bytes memory realSwapPathData) = abi.decode(userData, (address, uint256, address, bytes));
        require(originalInitiator == owner || originalInitiator == botAddress, "Untrusted original initiator");

        IERC20 token = tokens[0]; 
        uint256 amountToRepay = amounts[0] + feeAmounts[0]; 

        _executeUniversalArbitrage(realSwapPathData);

        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= amountToRepay, "Arbitrage unprofitable");

        require(token.transfer(BALANCER_VAULT, amountToRepay), "Balancer repayment failed");
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator, 
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == AAVE_POOL, "Untrusted Aave pool");
        require(initiator == address(this) || initiator == owner || initiator == botAddress, "Untrusted initiator");

        (address originalInitiator, , , bytes memory realSwapPathData) = abi.decode(params, (address, uint256, address, bytes));
        require(originalInitiator == owner || originalInitiator == botAddress, "Untrusted original initiator");

        IERC20 token = IERC20(asset);
        uint256 amountToRepay = amount + premium;

        _executeUniversalArbitrage(realSwapPathData);

        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= amountToRepay, "Arbitrage unprofitable");

        token.approve(AAVE_POOL, 0);
        require(token.approve(AAVE_POOL, amountToRepay), "Aave approve failed");

        return true;
    }

    function _executeUniversalArbitrage(bytes memory realSwapPathData) internal {
        if(realSwapPathData.length == 0) return; 

        (address[] memory targets, bytes[] memory payloads) = abi.decode(realSwapPathData, (address[], bytes[]));
        uint256 length = targets.length;

        require(length == payloads.length, "Length mismatch");

        for (uint256 i = 0; i < length; i++) {
            address target = targets[i];

            require(target != address(this), "Self-call blocked");
            require(whitelistedTargets[target], "Target unauthorized");

            (bool success, bytes memory returnData) = target.call(payloads[i]);

            if (!success) {
                if (returnData.length > 0) {
                    assembly {
                        let returndata_size := mload(returnData)
                        revert(add(returnData, 32), returndata_size)
                    }
                } else {
                    revert("External call failed");
                }
            }
        }
    }

    function withdrawToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No balance");
        require(IERC20(token).transfer(owner, balance), "Transfer failed");
    }

    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH balance");
        (bool success, ) = owner.call{value: balance}("");
        require(success, "ETH Transfer failed");
    }

    function updateBotAddress(address _newBot) external onlyOwner {
        botAddress = _newBot;
    }
}
