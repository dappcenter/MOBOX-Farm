// SPDX-License-Identifier: MIT

pragma solidity ^0.6.6;

import "./comm/Ownable.sol";
import "./comm/SafeMath.sol";
import "./comm/IERC20.sol";
import "./comm/SafeERC20.sol";
import "./comm/ReentrancyGuard.sol";

interface IStrategy {
    function sharesTotal() external view returns(uint256);
    function wantTotal() external view returns(uint256);
    function getTotal() external view returns(uint256, uint256);
    function deposit(uint256 amount_) external returns(uint256);
    function withdraw(address user_, uint256 amount_, uint256 feeRate_) external returns(uint256);
}

interface IStrategyBNB {
    function deposit(uint256 amount_) external payable returns(uint256);
}

interface IVeMobox {
    function booster(address user_, uint256 totalShare_, uint256 wantShare_) external returns(uint256);
}

interface IMoMoMinter {
    function addBox(address to_, uint256 amount_) external;
}

interface IKeyToken {
    function mint(address dest_, uint256 amount_) external;
}

contract MoboxFarm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event Staked(address indexed user, uint256 indexed pIndex, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed pIndex, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardRateChange(uint256 newRate);
    event AllocPointChange(uint256 indexed poolIndex, uint256 allocPoint, uint256 totalAllocPoint);

    struct UserInfo {
        uint128 rewardDebt;         // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of KEYs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.workingBalance * pool.rewardPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `rewardPerShare` (and `lastRewardTime`) gets updated
        //   2. User receives the pending reward sent to his/her address
        //   3. User's `workingBalance` gets updated
        //   4. User's `rewardDebt` gets updated
        uint128 workingBalance;         // Key, workingBalance = wantShares * mining bonus 
        uint128 wantShares;             // How many wantShares the user has get by LP Token provider.
        uint64  gracePeriod;            // timestamp of that users can receive the staked LP/Token without deducting the transcation fee
        uint64  lastDepositBlock;       // the blocknumber of the user's last deposit
    }

    struct PoolInfo {
        address wantToken;              // Address of LP token/token contract
        uint32  allocPoint;             // 1x = 100, 0.5x = 50
        uint64  lastRewardTime;         // Last unixtimestamp that CAKEs distribution occurs.
        uint128 rewardPerShare;         // Accumulated KEYs per share, times 1e12. See below
        uint128 workingSupply;          // Total mining points
        address strategy;               // Strategy
    }

    address constant public BNB = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    address public keyToken;   
    address public momoMinter;              // The contract for openning momo chests      
    address public rewardMgr;               // 'Key' mining rate management
    address public veMobox;                 // 'veCrv', mining weight   
    address public rewardHelper;            // If the user encounters a situation where there is not enough gas to receive the reward, the 'rewardHelper' can send the user's unclaimed 'Key' to the user
    uint256 public rewardRate;              // rewardRate per second for minning
    uint256 public rewardStart;             // reward start time
    uint256 public totalAllocPoint;         // total allocPoint for all pools

    PoolInfo[] public poolInfoArray;
    mapping (uint256 => mapping (address => UserInfo)) _userInfoMap;
    mapping (address => uint256) public rewardStore;        // Store rewards that the users did not withdraw
    function init(address key_, address rewardMgr_) external onlyOwner {
        require(keyToken == address(0) && rewardMgr == address(0), "only set once");
        require(key_ != address(0) && rewardMgr_ != address(0), "invalid param");
        keyToken = key_;
        rewardMgr = rewardMgr_;

        IERC20(keyToken).safeApprove(rewardMgr_, uint256(-1));

        // Discard the first pool
        if (poolInfoArray.length == 0) {
            poolInfoArray.push(PoolInfo(address(0), 0, 0, 0, 0, address(0)));
        }

        emit RewardRateChange(0);
    }

    function setRewardHelper(address addr_) external onlyOwner {
        require(addr_ != address(0), "invalid param");
        rewardHelper = addr_;
    }

    function setMoMoMinter(address addr_) external onlyOwner {
        require(keyToken != address(0) && addr_ != address(0), "invalid param");
        if (momoMinter != address(0)) {
            IERC20(keyToken).approve(momoMinter, 0);
        }
        momoMinter = addr_;
        // When the user exchanges the key for the box, 'momoMinter' will burn the specified number of keys. This method can be used to save gas, see 'getChestBox'
        IERC20(keyToken).safeApprove(momoMinter, uint256(-1));
    }

    modifier onlyRewardMgr() {
        require(_msgSender() == rewardMgr, "not rewardMgr");
        _;
    }
    
    // Add a new lp to the pool. Can only be called by the rewardMgr
    function addPool(address wantToken_, uint256 allocPoint_, address strategy_) external onlyRewardMgr {
        require(allocPoint_ <= 10000 && strategy_ != address(0), "invalid param");
        // solium-disable-next-line
        if (block.timestamp > rewardStart) {
            massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint.add(allocPoint_);
        uint256 poolIndex = poolInfoArray.length;
        poolInfoArray.push(PoolInfo({
            wantToken: wantToken_,
            allocPoint: SafeMathExt.safe32(allocPoint_),
            lastRewardTime: uint64(block.timestamp),
            rewardPerShare: 0,
            workingSupply: 0,
            strategy: strategy_
        }));

        if (wantToken_ != BNB) {
            IERC20(wantToken_).safeApprove(strategy_, uint256(-1));
        }
        
        emit AllocPointChange(poolIndex, allocPoint_, totalAllocPoint);
    }

    function setPool(uint256 pIndex_, address wantToken_, uint256 allocPoint_) external onlyRewardMgr {
        PoolInfo storage pool = poolInfoArray[pIndex_];
        // wantToken_ For verification only
        require(wantToken_ != address(0) && pool.wantToken == wantToken_, "invalid pool");
        require(allocPoint_ >= 0 && allocPoint_ <= 10000, "invalid param");

        massUpdatePools();

        totalAllocPoint = totalAllocPoint.sub(uint256(pool.allocPoint)).add(allocPoint_);
        pool.allocPoint = SafeMathExt.safe32(allocPoint_);
    
        emit AllocPointChange(pIndex_, allocPoint_, totalAllocPoint);
    }

    function getMaxPoolIndex() external view returns(uint256) {
        return poolInfoArray.length.sub(1);
    }

    function initReward(uint256 rewardRate_, uint256 rewardStart_) external onlyRewardMgr {
        require(rewardStart == 0, "only set once");
        // solium-disable-next-line
        uint256 tmNow = block.timestamp;
        require(rewardRate_ > 0 && rewardRate_ <= 2e18 && rewardStart_ > tmNow, "invalid param");

        rewardStart = rewardStart_;
        rewardRate = rewardRate_;

        emit RewardRateChange(rewardRate);
    }

    function changeRewardRate(uint256 rewardRate_) external onlyRewardMgr {
        require(rewardRate_ > 0 && rewardRate_ <= 2e18, "invalid param");
        // solium-disable-next-line
        if (block.timestamp > rewardStart) {
            massUpdatePools();
        }
        rewardRate = rewardRate_;

        emit RewardRateChange(rewardRate); 
    }

    function setVeMobox(address veMobox_) external onlyRewardMgr {
        require(veMobox == address(0), "only set once");
        veMobox = veMobox_;
    }

    function massUpdatePools() public {
        uint256 length = poolInfoArray.length;
        for (uint256 poolIndex = 0; poolIndex < length; ++poolIndex) {
            updatePool(poolIndex);
        }
    }

    function updatePool(uint256 pIndex_) public {
        PoolInfo storage pool = poolInfoArray[pIndex_];
        // solium-disable-next-line
        uint256 blockTimeStamp = block.timestamp;
 
        if (pIndex_ <= 0 || blockTimeStamp <= rewardStart || blockTimeStamp <= pool.lastRewardTime) {
            return;
        }

        if (pool.workingSupply == 0) {
            pool.lastRewardTime = SafeMathExt.safe64(blockTimeStamp);
            return;
        }

        uint256 rewardTime = blockTimeStamp.sub(Math.max(uint256(pool.lastRewardTime), rewardStart));
        uint256 keyReward = rewardTime.mul(rewardRate).mul(uint256(pool.allocPoint)).div(totalAllocPoint);
        IKeyToken(keyToken).mint(address(this), keyReward);
  
        pool.rewardPerShare = SafeMathExt.safe128(
            uint256(pool.rewardPerShare).add(keyReward.mul(1e12).div(uint256(pool.workingSupply)))
        );
        pool.lastRewardTime = SafeMathExt.safe64(blockTimeStamp);
    }

    // View function to see pending KEYs on frontend.
    function pendingKey(uint256 pIndex_, address user_) external view returns(uint256) {
        // solium-disable-next-line
        uint256 blockTimeStamp = block.timestamp;
        if (pIndex_ <= 0 || blockTimeStamp <= rewardStart) {
            return 0;
        }

        PoolInfo storage pool = poolInfoArray[pIndex_];
        if (blockTimeStamp < pool.lastRewardTime) {            
            return 0;     
        }
        UserInfo storage user = _userInfoMap[pIndex_][user_];
        if (pool.workingSupply == 0 || user.workingBalance == 0) {
            return 0;
        }

        uint256 rewardPerShare = uint256(pool.rewardPerShare);
        uint256 rewardTime = blockTimeStamp.sub(Math.max(uint256(pool.lastRewardTime), rewardStart));
        rewardPerShare = rewardPerShare.add(
            rewardTime.mul(rewardRate).mul(uint256(pool.allocPoint)).div(totalAllocPoint).mul(1e12).div(uint256(pool.workingSupply))
        );
        
        return uint256(user.workingBalance).mul(rewardPerShare).div(1e12).sub(user.rewardDebt);
    }

    function getUserInfo(uint256 pIndex_, address user_) 
        external 
        view 
        returns(
            address wantToken,
            uint256 wantShares,
            uint256 wantAmount,     
            uint256 workingBalance,
            uint256 gracePeriod
        )
    {
        if (pIndex_ > 0) { 
            PoolInfo storage pool = poolInfoArray[pIndex_];
            UserInfo storage user = _userInfoMap[pIndex_][user_];
            wantToken = pool.wantToken;
            wantShares = uint256(user.wantShares);
            workingBalance = uint256(user.workingBalance);
            gracePeriod = uint256(user.gracePeriod);
    
            uint256 wantTotal;
            uint256 shareTotal;
            (wantTotal, shareTotal) = IStrategy(pool.strategy).getTotal();
            if (shareTotal > 0) {
                wantAmount = wantShares.mul(wantTotal).div(shareTotal);
            } else {
                wantAmount = 0;
            }
        }
    }

    function _boostWorkingBalance(address strategy_, address user_, uint256 sharesUser_) internal returns(uint256) {
        if (veMobox == address(0)) {
            return 100;
        }
        uint256 sharesTotal = IStrategy(strategy_).sharesTotal();
        return IVeMobox(veMobox).booster(user_, sharesTotal, sharesUser_);
    }

    function _calcGracePeriod(uint256 gracePeriod, uint256 shareNew, uint256 shareAdd) internal view returns(uint256) {
        uint256 blockTime = block.timestamp;
        if (gracePeriod == 0) {
            // solium-disable-next-line
            return blockTime.add(180 days);
        }
        uint256 depositSec;
        // solium-disable-next-line
        if (blockTime >= gracePeriod) {
            depositSec = 180 days;
            return blockTime.add(depositSec.mul(shareAdd).div(shareNew));
        } else {
            // solium-disable-next-line
            depositSec = uint256(180 days).sub(gracePeriod.sub(blockTime));
            return gracePeriod.add(depositSec.mul(shareAdd).div(shareNew));
        }
    }

    function _calcFeeRateByGracePeriod(uint256 gracePeriod) internal view returns(uint256) {
        // solium-disable-next-line
        if (block.timestamp >= gracePeriod) {
            return 0;
        }
        // solium-disable-next-line
        uint256 leftSec = gracePeriod.sub(block.timestamp);

        if (leftSec < 90 days) {
            return 10;      // 0.1%
        } else if (leftSec < 150 days) {
            return 20;      // 0.2%
        } else if (leftSec < 166 days) {
            return 30;      // 0.3%
        } else if (leftSec < 173 days) {
            return 40;      // 0.4%
        } else {
            return 50;      // 0.5%
        }
    }

    function _depositFor(uint256 pIndex_, address lpFrom_, address lpFor_, uint256 amount_) internal {
        require(pIndex_ > 0 && amount_ > 0, "invalid param");
        updatePool(pIndex_);

        PoolInfo storage pool = poolInfoArray[pIndex_];
        UserInfo storage user = _userInfoMap[pIndex_][lpFor_];
        
        if (pool.wantToken != BNB) {
            IERC20(pool.wantToken).safeTransferFrom(lpFrom_, address(this), amount_);
        }
        
        uint256 workingBalance = uint256(user.workingBalance);
        if (workingBalance > 0) {
            uint256 pending = workingBalance.mul(uint256(pool.rewardPerShare)).div(1e12).sub(uint256(user.rewardDebt));
            if (pending > 0) {
                rewardStore[lpFor_] = pending.add(rewardStore[lpFor_]);
            }
        }

        // The return value of 'deposit' is the latest 'share' value
        uint256 wantSharesOld = uint256(user.wantShares);
        uint256 shareAdd;
        if (pool.wantToken == BNB) {
            shareAdd = IStrategyBNB(pool.strategy).deposit{value: amount_}(amount_);
        } else {
            shareAdd = IStrategy(pool.strategy).deposit(amount_);
        }
         
        user.wantShares = SafeMathExt.safe128(wantSharesOld.add(shareAdd));
        uint256 boost = _boostWorkingBalance(pool.strategy, lpFor_, uint256(user.wantShares));
        require(boost >= 100 && boost <= 300, "invalid boost");

        uint256 oldWorkingBalance = uint256(user.workingBalance);
        uint256 newWorkingBalance = uint256(user.wantShares).mul(boost).div(100);

        user.workingBalance = SafeMathExt.safe128(newWorkingBalance);
        pool.workingSupply = SafeMathExt.safe128(uint256(pool.workingSupply).sub(oldWorkingBalance).add(newWorkingBalance));

        user.rewardDebt = SafeMathExt.safe128(newWorkingBalance.mul(uint256(pool.rewardPerShare)).div(1e12));
        user.gracePeriod = SafeMathExt.safe64(_calcGracePeriod(user.gracePeriod, uint256(user.wantShares), shareAdd));
        user.lastDepositBlock = SafeMathExt.safe64(block.number);
        
        emit Staked(lpFor_, pIndex_, amount_);
    }

    // Deposit LP tokens/BEP20 tokens to MOBOXFarm for KEY allocation.
    function deposit(uint256 pIndex_, uint256 amount_) external nonReentrant {
        _depositFor(pIndex_, msg.sender, msg.sender, amount_);
    }

    // Deposit BNB to MOBOXFarm for KEY allocation.
    function deposit(uint256 pIndex_) external payable nonReentrant {
        _depositFor(pIndex_, msg.sender, msg.sender, msg.value);
    }

    // Deposit LP tokens/BEP20 tokens to MOBOXFarm for KEY allocation. 
    function depositFor(address lpFor_, uint256 pIndex_, uint256 amount_) external nonReentrant {
        _depositFor(pIndex_, msg.sender, lpFor_, amount_);
    }

    // Deposit BNB to MOBOXFarm for KEY allocation.
    function depositFor(address lpFor_, uint256 pIndex_) external payable nonReentrant {
        _depositFor(pIndex_, msg.sender, lpFor_, msg.value);
    }

    // Stake CAKE tokens to MoboxFarm 
    function withdraw(uint256 pIndex_, uint256 amount_) external nonReentrant {
        require(pIndex_ > 0 || amount_ > 0, "invalid param");
        updatePool(pIndex_);

        PoolInfo storage pool = poolInfoArray[pIndex_];
        UserInfo storage user = _userInfoMap[pIndex_][msg.sender];
        uint256 wantShares = uint256(user.wantShares);
        require(wantShares > 0, "insufficient wantShares");
        require(block.number > uint256(user.lastDepositBlock).add(2), "withdraw in 3 blocks");


        uint256[2] memory shareTotals;      // 0: wantTotal, 1: shareTotal
        (shareTotals[0], shareTotals[1]) = IStrategy(pool.strategy).getTotal();
        require(shareTotals[1] >= wantShares, "invalid share");

        uint256 pending = uint256(user.workingBalance).mul(uint256(pool.rewardPerShare)).div(1e12).sub(uint256(user.rewardDebt));

        uint256 wantWithdraw = wantShares.mul(shareTotals[0]).div(shareTotals[1]);
        if (wantWithdraw > amount_) {
            wantWithdraw = amount_;
        }
        require(wantWithdraw > 0, "insufficient wantAmount");

        uint256 feeRate = _calcFeeRateByGracePeriod(uint256(user.gracePeriod));
        uint256 shareSub = IStrategy(pool.strategy).withdraw(msg.sender, wantWithdraw, feeRate);
        user.wantShares = SafeMathExt.safe128(uint256(user.wantShares).sub(shareSub));
        uint256 boost = _boostWorkingBalance(pool.strategy, msg.sender, uint256(user.wantShares));
        require(boost >= 100 && boost <= 300, "invalid boost");

        uint256 oldWorkingBalance = uint256(user.workingBalance);
        uint256 newWorkingBalance = uint256(user.wantShares).mul(boost).div(100);
        user.workingBalance = SafeMathExt.safe128(newWorkingBalance);

        // Set 'rewardDebt' first and then increase 'rewardStore'
        user.rewardDebt = SafeMathExt.safe128(newWorkingBalance.mul(uint256(pool.rewardPerShare)).div(1e12));
        if (pending > 0) {
            rewardStore[msg.sender] = pending.add(rewardStore[msg.sender]);
        }
        // If user withdraws all the LPs, then gracePeriod is cleared
        if (user.wantShares == 0) {
            user.gracePeriod = 0;
        }

        pool.workingSupply = SafeMathExt.safe128(uint256(pool.workingSupply).sub(oldWorkingBalance).add(newWorkingBalance));
        emit Staked(msg.sender, pIndex_, amount_);
    }

    function getReward(uint256[] memory pIndexArray_) external nonReentrant {
        _getRward(pIndexArray_, msg.sender);
        uint256 keyAmount = rewardStore[msg.sender];
        if (keyAmount > 0) {
            rewardStore[msg.sender] = 0;
            IERC20(keyToken).safeTransfer(msg.sender, keyAmount);
        }
    }

    function getRewardFor(uint256[] memory pIndexArray_, address user_) external {
        require(msg.sender == rewardHelper, "not helper");
        _getRward(pIndexArray_, user_);

        uint256 keyAmount = rewardStore[user_];
        if (keyAmount > 0) {
            rewardStore[user_] = 0;
            IERC20(keyToken).safeTransfer(user_, keyAmount);
        }
    }

    function _getRward(uint256[] memory pIndexArray_, address user_) internal {
        require(pIndexArray_.length > 0 && user_ != address(0), "invalid param");
        uint256 poolIndex;
        uint256 keyAmount = rewardStore[user_];

        for (uint256 i = 0; i < pIndexArray_.length; ++i) {
            poolIndex = pIndexArray_[i];
            UserInfo storage user = _userInfoMap[poolIndex][user_];
            if (user.workingBalance <= 0) {
                continue;
            }
            updatePool(poolIndex);

            PoolInfo storage pool = poolInfoArray[poolIndex];
            uint256 workingBalance = uint256(user.workingBalance);
            uint256 pending = workingBalance.mul(uint256(pool.rewardPerShare)).div(1e12).sub(uint256(user.rewardDebt));
            // Need to check the change of boost rate
            if (veMobox != address(0)) {
                uint256 boost = _boostWorkingBalance(pool.strategy, user_, uint256(user.wantShares));
                require(boost >= 100 && boost <= 300, "invalid boost");
                uint256 oldWorkingBalance = workingBalance;
                uint256 newWorkingBalance = uint256(user.wantShares).mul(boost).div(100);
                if (oldWorkingBalance != newWorkingBalance) {
                    user.workingBalance = SafeMathExt.safe128(newWorkingBalance);
                    pool.workingSupply = SafeMathExt.safe128(uint256(pool.workingSupply).sub(oldWorkingBalance).add(newWorkingBalance));
                    
                    workingBalance = newWorkingBalance;
                }
            }
            user.rewardDebt = SafeMathExt.safe128(workingBalance.mul(uint256(pool.rewardPerShare)).div(1e12));
            keyAmount = keyAmount.add(pending);
        }
        rewardStore[user_] = keyAmount;
    }

    function getChestBox(uint256[] memory pIndexArray_, uint256 boxAmount_) external nonReentrant {
        require(boxAmount_ > 0 && boxAmount_ < 10000000 && momoMinter != address(0), "invalid param");
        if (rewardStore[msg.sender] < boxAmount_.mul(1e18)) {
            _getRward(pIndexArray_, msg.sender);
        }
    
        uint256 keyAmount = rewardStore[msg.sender];
        uint256 needKey = boxAmount_.mul(1e18);
        if (keyAmount >= needKey) {
            rewardStore[msg.sender] = keyAmount.sub(needKey);
            IMoMoMinter(momoMinter).addBox(msg.sender, boxAmount_);
            emit RewardPaid(msg.sender, needKey);
        }
    }
}
