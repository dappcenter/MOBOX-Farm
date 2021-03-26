// SPDX-License-Identifier: MIT

pragma solidity ^0.6.6;

import "./comm/Ownable.sol";
import "./comm/Pausable.sol";
import "./comm/ReentrancyGuard.sol";
import "./comm/SafeMath.sol";
import "./comm/ERC20.sol";
import "./comm/IERC20.sol";
import "./comm/SafeERC20.sol";

interface IPancakeSwapRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IVenusDistribution {
    function claimVenus(address holder) external;

    function enterMarkets(address[] memory _vtokens) external;

    function exitMarket(address _vtoken) external;
}

interface IWBNB {
    function deposit() external payable;
}

interface IVBNB {
    function mint() external payable;

    function redeem(uint256 redeemTokens) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function borrow(uint256 borrowAmount) external returns (uint256);

    function repayBorrow() external payable;

    function balanceOfUnderlying(address owner) external returns (uint256);

    function borrowBalanceCurrent(address account) external returns (uint256);
}

contract MoboxStrategyVBNB is Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct VenusData {
        uint128 totalSupply;
        uint128 totalBorrow;
    }

    // WBNB Token address
    address public constant wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // Pancake Swap rounter
    address public constant pancakeRouter = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F;
    // Venus XVS token address
    address public constant venusXvs = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;
    // Venus distribution address
    address public constant venusDistribution = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    uint256 public constant maxBuyBackRate = 600;   // max 6%
    uint256 public constant maxDevFeeRate = 200;    // max 2%
    uint256 public constant borrow_rate_max_hard = 5990;

    uint256 public shareTotal;
    address public moboxFarm;
    address public vToken;          // 'vBNB' here
    address public strategist; 
    address public buyBackPool;
    address public devAddress;
    uint256 public buyBackRate;
    uint256 public devFeeRate;
    bool public recoverPublic;

    VenusData public venusData;
    uint256 public borrowRate;
    uint256 public borrowDepth;
    //  after deposit, if the margin exceeds maxMarginTriggerDeposit, a deposit to venus will be triggered
    //  if the margin is not enough when withdrawing funds, take out a part of the token to the vault when withdrawing funds so that keep the margin reaching baseMarginForWithdraw
    uint256 public baseMarginForWithdraw;      
    uint256 public maxMarginTriggerDeposit;
    

    constructor() public {

    }

    receive() external payable {}

    function init(
        address moboxFarm_,
        address strategist_,
        address vToken_,
        address buyBackPool_,
        address devAddress_,
        uint256 buyBackRate_,
        uint256 devFeeRate_,
        uint256 margin_
    ) external {
        require(moboxFarm == address(0), "may only be init once");
        require(vToken_ != address(0) && moboxFarm_ != address(0) && buyBackPool_ != address(0), "invalid param");
        require(buyBackRate_ < maxBuyBackRate && devFeeRate_ < maxDevFeeRate, "invalid param");

        moboxFarm = moboxFarm_;
        strategist = strategist_;
        vToken = vToken_;
        buyBackPool = buyBackPool_;
        devAddress = devAddress_;
        buyBackRate = buyBackRate_;
        devFeeRate = devFeeRate_;

        borrowRate = 5800;
        borrowDepth = 3;
        baseMarginForWithdraw = margin_;
        maxMarginTriggerDeposit = margin_.mul(2);

        transferOwnership(moboxFarm_);

        IERC20(venusXvs).safeApprove(pancakeRouter, uint256(-1));
        address[] memory venusMarkets = new address[](1);
        venusMarkets[0] = vToken;
        IVenusDistribution(venusDistribution).enterMarkets(venusMarkets);
    }

    // Deposit to venus
    function _supply(uint256 amount_) internal {
        IVBNB(vToken).mint{value: amount_}();
    }

 
    function _removeSupply(uint256 amount_) internal {
        IVBNB(vToken).redeemUnderlying(amount_);
    }


    function _borrow(uint256 amount_) internal {
        IVBNB(vToken).borrow(amount_);
    }

    function _repayBorrow(uint256 amount_) internal {
        IVBNB(vToken).repayBorrow{value: amount_}();
    }

    function _safeTransferETH(address user_, uint256 value_) internal {
        (bool success, ) = user_.call{value: value_, gas: 3000}(new bytes(0));
        require(success, "user can't receive BNB with gas 3000");
    }

    function wantLocal() public view returns(uint256) {
        return address(this).balance;
    }

    function wantTotal() public view returns(uint256) {
        // Margin + Deposit-Borrow
        return wantLocal().add(uint256(venusData.totalSupply)).sub(uint256(venusData.totalBorrow));
    }

    function getTotal() public view returns(uint256 wantTotal_, uint256 shareTotal_) {
        wantTotal_ = wantTotal();
        shareTotal_ = shareTotal;
    }

    function deposit(uint256 amount_) 
        external 
        payable
        onlyOwner
        whenNotPaused 
        nonReentrant 
        returns(uint256) 
    {
        updateBalance();
        uint256 oldWantTotal = wantTotal();
        uint256 shareAdd;
        if (oldWantTotal == 0 || shareTotal == 0) {
            shareAdd = amount_;
        } else {
            // shareAdd / (shareAdd + shareTotal) = amount_ / (amount_ + wantTotal)
            shareAdd = amount_.mul(shareTotal).div(oldWantTotal);  
        }
        shareTotal = shareTotal.add(shareAdd);

        _farm(true);

        return shareAdd;
    }

    function withdraw(address user_, uint256 amount_, uint256 feeRate_) 
        external
        onlyOwner
        nonReentrant
        returns(uint256)
    {
        require(user_ != address(0) && amount_ > 0 && feeRate_ <= 50, "invalid param");
        updateBalance();
        uint256 wantTotalAmount = wantTotal();
        uint256 wantAmount = amount_ > wantTotalAmount ? wantTotalAmount : amount_;
    
        uint256 shareSub = wantAmount.mul(shareTotal).div(wantTotalAmount);
        shareTotal = shareTotal.sub(shareSub);

        uint256 wantBalance = address(this).balance;
        if (wantBalance < wantAmount) {
            // Withdraw more funds for preparation by the way
            _deleverage(wantAmount.sub(wantBalance).add(baseMarginForWithdraw));
            wantBalance = address(this).balance;
        }

        if (wantBalance < wantAmount) {
            wantAmount = wantBalance;
        }

        if (feeRate_ > 0) {
            uint256 feeAmount = wantAmount.mul(feeRate_).div(10000);
            if (feeAmount > 0) {
                wantAmount = wantAmount.sub(feeAmount);
                
                uint256 buyBackAmount = feeAmount.mul(maxBuyBackRate).div(maxBuyBackRate.add(maxDevFeeRate));
                if (buyBackAmount > 0) {
                    // Converted to wbnb to the Buyback pool
                    IWBNB(wbnb).deposit{value: buyBackAmount}();
                    IERC20(wbnb).safeTransfer(buyBackPool, buyBackAmount);
                }
                uint256 devAmount = feeAmount.sub(buyBackAmount);
                if (devAmount > 0) {
                    _safeTransferETH(devAddress, devAmount);
                }
            }
        }

        _safeTransferETH(user_, wantAmount);

        if (!_farm(true)) {
            // If the farm is not carried out, the leverage ratio needs to be monitored
            updateBalance();
            _deleverageUntilNotOverLevered();
        }

        return shareSub;
    }

    function updateBalance() public {
        uint256 totalSupply = IVBNB(vToken).balanceOfUnderlying(address(this));
        uint256 totalBorrow = IVBNB(vToken).borrowBalanceCurrent(address(this));
        venusData.totalSupply = SafeMathExt.safe128(totalSupply);
        venusData.totalBorrow = SafeMathExt.safe128(totalBorrow);
    }

    function _farm(bool withLeverage_) internal returns(bool) {
        // Before calling this function, need to call 'updateBalance'
        uint256 wantLocalAmount = wantLocal();
        if (wantLocalAmount < maxMarginTriggerDeposit) {
            return false;
        }

        uint256 investAmount = wantLocalAmount.sub(baseMarginForWithdraw);

        _leverage(investAmount, withLeverage_);

        updateBalance();
        // Check the leverage ratio, if the leverage is too high, try to deleverage
        _deleverageUntilNotOverLevered();
        
        return true;
    }

    function _leverage(uint256 amount_, bool withLeverage_) internal {
        uint256 amount = amount_;
        if (withLeverage_) {
            for (uint256 i = 0; i < borrowDepth; ++i) {
                _supply(amount);
                amount = amount.mul(borrowRate).div(10000);
                _borrow(amount);
            }
        }
        _supply(amount);
    }

    /**
     * @dev Redeem to the desired leverage amount, then use it to repay borrow.
     * If already over leverage, redeem max amt redeemable, then use it to repay borrow.
     * Need call updateBalance before call this function
     */
    function _deleverageOnce() internal {
        if (!recoverPublic) {
            require(_msgSender() == strategist, "not strategist");
        }

        uint256 balanceBeforeSupply = wantLocal();
        
        uint256 totalBorrow = uint256(venusData.totalBorrow);
        uint256 supplyTargeted = totalBorrow.mul(10000).div(borrowRate);
        if (venusData.totalSupply <= supplyTargeted) {
            // Remove deposits for repayment according to the highest leverage
            uint256 supplyMin = totalBorrow.mul(10000).div(borrow_rate_max_hard);
            _removeSupply(uint256(venusData.totalSupply).sub(supplyMin));
        } else {
            _removeSupply(uint256(venusData.totalSupply).sub(supplyTargeted));
        }

        uint256 balanceAfterRemoveSupply = wantLocal();
        _repayBorrow(balanceAfterRemoveSupply.sub(balanceBeforeSupply));
        
        // After the operation is completed, update the balance
        updateBalance();
    }

    /**
     * @dev Need call updateBalance before call this function
     */
    function _deleverageUntilNotOverLevered() internal {
        uint256 totalBorrow = uint256(venusData.totalBorrow);
        uint256 supplyTargeted = totalBorrow.mul(10000).div(borrowRate);
        while (venusData.totalSupply > 0 && venusData.totalSupply <= supplyTargeted) {
            _deleverageOnce();
        }
    }

    function deleverageOnce() external {
        updateBalance();
        _deleverageOnce();
    }

    function deleverageUntilNotOverLevered() external {
        updateBalance();
        _deleverageUntilNotOverLevered();
    }

    /**
     * @dev Need call updateBalance before call this function
     */
    function _deleverage(uint256 minLocal_) internal {
        _deleverageUntilNotOverLevered();

        uint256 supplyMin = uint256(venusData.totalBorrow).mul(10000).div(borrow_rate_max_hard);
        _removeSupply(uint256(venusData.totalSupply).sub(supplyMin));
        uint256 wantLocalAmount = wantLocal();
        while (wantLocalAmount < venusData.totalBorrow) {
            if (wantLocalAmount >= minLocal_) {
                return;
            }
            _repayBorrow(wantLocalAmount);
            updateBalance();

            supplyMin = uint256(venusData.totalBorrow).mul(10000).div(borrow_rate_max_hard);
            // removeSupply won't affect totalBorrow
            _removeSupply(uint256(venusData.totalSupply).sub(supplyMin));

            wantLocalAmount = wantLocal();
        }

        if (wantLocalAmount >= minLocal_) {
            return;
        }

        _repayBorrow(uint256(venusData.totalBorrow));

        uint256 vTokenAmount = IERC20(vToken).balanceOf(address(this));
        IVBNB(vToken).redeem(vTokenAmount);
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

        IVenusDistribution(venusDistribution).claimVenus(address(this));
        uint256 xvsAmount = IERC20(venusXvs).balanceOf(address(this));
        if (xvsAmount <= 0) {
            return;
        }
        uint256 buyBackAmount = xvsAmount.mul(buyBackRate).div(10000);
        if (buyBackAmount > 0) {
            IERC20(venusXvs).safeTransfer(buyBackPool, buyBackAmount);
        }
        uint256 devAmount = xvsAmount.mul(devFeeRate).div(10000);
        if (devAmount > 0) {
            IERC20(venusXvs).safeTransfer(devAddress, devAmount);
        }
        xvsAmount = xvsAmount.sub(buyBackAmount).sub(devAmount);

        if (xvsAmount <= 0) {
            return;
        }

        IPancakeSwapRouter(pancakeRouter).swapExactTokensForETHSupportingFeeOnTransferTokens(
            xvsAmount,
            0,
            _makePath(venusXvs, wbnb),
            address(this),
            block.timestamp + 60
        );
        
        _farm(false);
    }

    function farm() external {
        if (!recoverPublic) {
            require(_msgSender() == strategist, "not strategist");
        }
        _farm(true);
    }

    /**
     * @dev Throws if called by any account other than the strategist
     */
    modifier onlyStrategist() {
        require(_msgSender() == strategist, "not strategist");
        _;
    }

    function rebalance(uint256 borrowRate_, uint256 borrowDepth_) external onlyStrategist {
        require(borrowRate_ <= 5950 && borrowDepth_ <= 5, "invalid param");
        _deleverage(uint256(-1));
        borrowRate = borrowRate_;
        borrowDepth = borrowDepth_;
        _farm(true);
    }

    // Transfer dustTokens out of xvs and wait for the next reinvestment to convert to bnb
    function dustToEarnToken(address dustToken_) external onlyStrategist {
        require(dustToken_ != venusXvs, "invalid param");
        uint256 dustAmount = IERC20(dustToken_).balanceOf(address(this));
        if (dustAmount > 0) {
            IERC20(dustToken_).safeIncreaseAllowance(pancakeRouter, dustAmount);
            IPancakeSwapRouter(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                dustAmount,
                0,
                _makePath(dustToken_, venusXvs),
                address(this),
                block.timestamp + 60
            );
        }
        // _Farm is not called here
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
