// SPDX-License-Identifier: MIT

pragma solidity ^0.6.6;

import "./comm/Ownable.sol";
import "./comm/Pausable.sol";
import "./comm/ReentrancyGuard.sol";
import "./comm/SafeMath.sol";
import "./comm/ERC20.sol";
import "./comm/IERC20.sol";
import "./comm/SafeERC20.sol";

interface IPancakeMasterChef {
    // Info of each MasterChef staking pool
    function poolInfo(uint256 _pid) external returns(address, uint256, uint256, uint256);
    // Deposit LP tokens to Pancake MasterChef for CAKE allocation
    function deposit(uint256 _pid, uint256 _amount) external;
    // Withdraw LP tokens from Pancake MasterChef
    function withdraw(uint256 _pid, uint256 _amount) external;
}

interface IPancakeSwapRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract MoboxStrategyP is Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // WBNB Token address
    address public constant wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // PancakeSwap Token(CAKE) address
    address public constant cake = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    // Pancake MasterChef
    address public constant pancakeFarmer = 0x73feaa1eE314F8c655E354234017bE2193C9E24E;
    // Pancake Swap rounter
    address public constant pancakeRouter = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F;
    uint256 public constant maxBuyBackRate = 600;   // max 6%
    uint256 public constant maxDevFeeRate = 200;    // max 2%

    uint256 public shareTotal;
    uint256 public wantTotal;

    address public moboxFarm;
    uint256 public pancakePid;
    address public wantToken;
    address public tokenA;
    address public tokenB;
    address public strategist;      // Control investment strategies
    address public buyBackPool;
    address public devAddress;
    uint256 public buyBackRate;
    uint256 public devFeeRate;
    bool public recoverPublic;
    uint256 public maxMarginTriggerDeposit;

    constructor() public {

    }

    function init(
        address moboxFarm_,
        address strategist_,
        uint256 pId_,
        address wantToken_,
        address tokenA_,
        address tokenB_,
        address buyBackPool_,
        address devAddress_,
        uint256 buyBackRate_,
        uint256 devFeeRate_,
        uint256 margin_
    ) external onlyOwner {
        require(pancakePid == 0 && moboxFarm == address(0), "may only be init once");
        require(pId_ > 0 && moboxFarm_ != address(0) && buyBackPool_ != address(0), "invalid param");
        require(buyBackRate_ < maxBuyBackRate && devFeeRate_ < maxDevFeeRate, "invalid param");
        moboxFarm = moboxFarm_;
        strategist = strategist_;
        pancakePid = pId_;
        wantToken = wantToken_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        buyBackPool = buyBackPool_;
        devAddress = devAddress_;
        buyBackRate = buyBackRate_;
        devFeeRate = devFeeRate_;
        maxMarginTriggerDeposit = margin_;

        transferOwnership(moboxFarm_);

        // MasterChef and PancakeRouter are trusted contracts
        IERC20(wantToken_).safeApprove(pancakeFarmer, uint256(-1)); 
        IERC20(cake).safeApprove(pancakeRouter, uint256(-1));
        if (tokenA_ != cake) {
            IERC20(tokenA_).safeApprove(pancakeRouter, uint256(-1));
        }
        if (tokenB_ != cake) {
            IERC20(tokenB_).safeApprove(pancakeRouter, uint256(-1));
        }
    }

    function getTotal() external view returns(uint256 wantTotal_, uint256 sharesTotal_) {
        wantTotal_ = wantTotal;
        sharesTotal_ = shareTotal;
    }

    // Deposit wantToken for user, can only call from moboxFarm
    // Just deposit and waiting for harvest to stake to pancake
    function deposit(uint256 amount_) external onlyOwner whenNotPaused nonReentrant returns(uint256) {
        IERC20(wantToken).safeTransferFrom(moboxFarm, address(this), amount_);
        
        uint256 shareAdd;
        if (shareTotal == 0 || wantTotal == 0) {
            shareAdd = amount_;
        } else {
            // shareAdd / (shareAdd + shareTotal) = amount_ / (amount_ + wantTotal)
            shareAdd = amount_.mul(shareTotal).div(wantTotal); 
        }
        wantTotal = wantTotal.add(amount_);
        shareTotal = shareTotal.add(shareAdd);

        uint256 lpAmount = IERC20(wantToken).balanceOf(address(this));
        if (lpAmount >= maxMarginTriggerDeposit) {
            IPancakeMasterChef(pancakeFarmer).deposit(pancakePid, lpAmount);
        }

        return shareAdd;
    }

    // Deposit wantToken for user, can only call from moboxFarm
    function withdraw(address user_, uint256 amount_, uint256 feeRate_) 
        external 
        onlyOwner 
        nonReentrant 
        returns(uint256) 
    {
        require(amount_ > 0 && feeRate_ <= 50, "invalid param");
        uint256 lpBalance = IERC20(wantToken).balanceOf(address(this));
        if (lpBalance < amount_) {
            IPancakeMasterChef(pancakeFarmer).withdraw(pancakePid, amount_.sub(lpBalance));
        }

        lpBalance = IERC20(wantToken).balanceOf(address(this));
        uint256 wantAmount = lpBalance;
        if (wantTotal < wantAmount) {
            wantAmount = wantTotal;
        }
        // shareSub / shareTotal = wantAmount / wantTotal;
        uint256 shareSub = wantAmount.mul(shareTotal).div(wantTotal);
        wantTotal = wantTotal.sub(wantAmount);
        shareTotal = shareTotal.sub(shareSub);

        if (feeRate_ > 0) {
            uint256 feeAmount = wantAmount.mul(feeRate_).div(10000);
            wantAmount = wantAmount.sub(feeAmount);
            uint256 buyBackAmount = feeAmount.mul(maxBuyBackRate).div(maxBuyBackRate.add(maxDevFeeRate));
            if (buyBackAmount > 0) {
                IERC20(wantToken).safeTransfer(buyBackPool, buyBackAmount);
            }
            uint256 devAmount = feeAmount.sub(buyBackAmount);
            if (devAmount > 0) {
                IERC20(wantToken).safeTransfer(devAddress, devAmount);
            }
        } 
        IERC20(wantToken).safeTransfer(user_, wantAmount);
        
        return shareSub;
    }

    // _tokenA != _tokenB
    function _makePath(address _tokenA, address _tokenB) internal pure returns(address[] memory path) {
        if (_tokenA == wbnb) {
            path = new address[](2);
            path[0] = wbnb;
            path[1] = _tokenB;
        } else if(_tokenB == wbnb) {
            path = new address[](2);
            path[0] = _tokenA;
            path[1] = wbnb;
        } else {
            path = new address[](3);
            path[0] = _tokenA;
            path[1] = wbnb;
            path[2] = _tokenB;
        }
    }

    function harvest() whenNotPaused external {
        if (!recoverPublic) {
            require(_msgSender() == strategist, "not strategist");
        }
        IPancakeMasterChef(pancakeFarmer).withdraw(pancakePid, 0);
        uint256 cakeAmount = IERC20(cake).balanceOf(address(this));
        
        uint256 lpAmountBeforeHarvest = IERC20(wantToken).balanceOf(address(this));
        if (cakeAmount > 0) {
            uint256 buyBackAmount = cakeAmount.mul(buyBackRate).div(10000);
            if (buyBackAmount > 0) {
                IERC20(cake).safeTransfer(buyBackPool, buyBackAmount);
            }
            uint256 devAmount = cakeAmount.mul(devFeeRate).div(10000);
            if (devAmount > 0) {
                IERC20(cake).safeTransfer(devAddress, devAmount);
            }

            cakeAmount = cakeAmount.sub(buyBackAmount).sub(devAmount);
            if (cakeAmount > 0) {
                // swap cake to tokenA and tokenB
                if (cake != tokenA) {
                    IPancakeSwapRouter(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        cakeAmount.div(2),
                        0,
                        _makePath(cake, tokenA),
                        address(this),
                        block.timestamp + 60
                    );
                }

                if (cake != tokenB) {
                    IPancakeSwapRouter(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        cakeAmount.div(2),
                        0,
                        _makePath(cake, tokenB),
                        address(this),
                        block.timestamp + 60
                    );
                }
                uint256 tokenAAmount = IERC20(tokenA).balanceOf(address(this));
                uint256 tokenBAmount = IERC20(tokenB).balanceOf(address(this));
                if (tokenAAmount > 0 && tokenBAmount > 0) {
                    IPancakeSwapRouter(pancakeRouter).addLiquidity(
                        tokenA,
                        tokenB,
                        tokenAAmount,
                        tokenBAmount,
                        0,
                        0,
                        address(this),
                        now + 60
                    ); 
                }
            } 
        }

        uint256 lpAmountAfterHarvest = IERC20(wantToken).balanceOf(address(this));
        // Deposit the unstaked LP and the reinvested LP into pancake together
        wantTotal = wantTotal.add(lpAmountAfterHarvest.sub(lpAmountBeforeHarvest));
        IPancakeMasterChef(pancakeFarmer).deposit(pancakePid, lpAmountAfterHarvest);
    }
    /**
     *  @dev Stake the user deposits in but unstaked LP to Pancake for mining (LP directly transferred to this strategy will be treated as 'dustToken')
     * If the number of LPs is too small, they will be processed together in the next havest
     */
    function farm() external {
        if (!recoverPublic) {
            require(_msgSender() == strategist, "not strategist");
        }
        
        uint256 lpAmount = IERC20(wantToken).balanceOf(address(this));
        IPancakeMasterChef(pancakeFarmer).deposit(pancakePid, lpAmount);
    } 

    /**
     * @dev Throws if called by any account other than the strategist
     */
    modifier onlyStrategist() {
        require(_msgSender() == strategist, "not strategist");
        _;
    }

    /**
     * @dev Transfer dustTokens out of cake, and wait for the next reinvestment to convert to LP
     */
    function dustToEarnToken(address dustToken_) external onlyStrategist {
        require(dustToken_ != cake && dustToken_ != wantToken, "invalid param");
        uint256 dustAmount = IERC20(dustToken_).balanceOf(address(this));
        if (dustAmount > 0) {
            IERC20(dustToken_).safeIncreaseAllowance(pancakeRouter, dustAmount);
            IPancakeSwapRouter(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                dustAmount,
                0,
                _makePath(dustToken_, cake),
                address(this),
                block.timestamp + 60
            );
        }
    }

    function setStrategist(address strategist_) external onlyStrategist {
        strategist = strategist_;
    }

    function setFeeRate(uint256 buyBackRate_, uint256 devFeeRate_) external onlyStrategist {
        require(buyBackRate_ <= maxBuyBackRate && devFeeRate_ <= maxDevFeeRate, "invalid param");
        buyBackRate = buyBackRate_;
        devFeeRate = devFeeRate_;
    }

    function setRecoverPublic(bool val_) external onlyStrategist {
        recoverPublic = val_;
    } 

    function pause() external onlyStrategist {
        _pause();
    }

    function unpause() external onlyStrategist {
        _unpause();
    }
}

