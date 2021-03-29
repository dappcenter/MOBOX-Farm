// SPDX-License-Identifier: MIT

pragma solidity ^0.6.6;

import "./comm/Ownable.sol";
import "./comm/SafeMath.sol";
import "./comm/ReentrancyGuard.sol";
import "./comm/IERC20.sol";

interface IMoMoToken {
    function transferFrom(address from_, address to_, uint256 tokenId_) external;
    function getMomoSimpleByTokenId(uint256 tokenId_) external view returns(uint256, uint256);
    function levelUp(uint256 tokenId_, uint256[] memory protosV1V2V3_, uint256[] memory amountsV1V2V3_, uint256[] memory tokensV4V5_) external;
    function setMomoName(uint256 tokenId_, bytes memory name_) external payable;
    function addMomoStory(uint256 tokenId_, bytes memory story_) external payable;
}

interface IMoMoMToken {
    function setApprovalForAll(address operator_, bool approved_) external;
    function safeBatchTransferFrom(address from_, address to_, uint256[] calldata ids_, uint256[] calldata amounts_, bytes calldata data_) external;
}

interface IMoMoMinter {
    function mintByStaker(address minter, uint256 amount_) external returns(uint256[] memory ids, uint256[] memory vals, uint256[] memory tokenIds); 
}


contract MoMoStaker is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    event StakeRewardChange(uint256 rate, uint256 timestamp);
    event WithdrawReward(address indexed user, uint256 reward);
    // changeType: 1 stake/2 mint and stake/3 withdraw/4 level up/5 create auction/6 cancel auction/7 bid auction
    event HashrateChange(address indexed user, uint256 changeType, uint256 oldhashRate, uint256 newHashRate);

    event MintStake(
        address indexed owner,
        uint256[] ids,                  // ERC1155 prototypes
        uint256[] amounts,              // ERC1155 amounts
        uint256[] tokenIds              // ERC721 tokenIds
    );

    event LevelUpBurnStake(
        address indexed owner,
        uint256[] ids,                  // ERC1155 prototypes
        uint256[] amounts,              // ERC1155 amounts
        uint256[] tokenIds              // ERC721 tokenIds
    );

    // User mining data related
    struct UserRewardInfo {
        uint128 userHashrateFixed;      // user's fixed hashrate
        uint128 userHashratePercent;    // user's hashrate percentage (Mainly obtained through fetters)       
        uint128 userRewardPerTokenPaid; // the rewardPerTokenStored recorded in the user's last operation
        uint128 userReward;             // 'Mbox' acquired since the user's last operation
    }

    // This data structure counts the number of staked ERC721 NFT from users, and is used to calculate user fetters
    struct UserMomoCount {
        uint64 amountV4;                // the number of V4 version NFTs obtained by users
        uint64 amountV5;                // the number of V5 version NFTs obtained by users
        uint64 amountV6;                // the number of V6 version NFTs obtained by users
    }

    // Used to record part of the user's NFT data
    struct NftOwner {
        address addr;                   // user's address
        uint64  index;                  //  _stakingMomoArray index of the array
    }

    // V4 Fetters fixed increase of 100 points of hashrate
    uint256 constant HASHRATE_CREW = 100;    
    // Distributed 20% of MoboxToken to develpers simultaneously  
    uint256 constant devTeamRate = 2000;

    // MoMo-ERC721 Token address, this type of NFT is divided into three types: V4, V5, and V6. V4 and V5 are probabilistically opened after the momoMinter contract burns the KeyToken. The V6 version of the NFT will be mined in a limited amount
    // The prototype ranges of V4-V6 are 4xxxx, 5xxxx, 6xxxx respectively
    IMoMoToken _momoToken;
    // MoMo-ERC1155 Token contract address. This type of NFT is divided into 3 types: V1, V2, and V3, all of which are probabilistically opened after the momoMinter contract burns the KeyToken
    // The prototype (token id) ranges of V1-V3 are 1xxxx, 2xxxx, 3xxxx
    IMoMoMToken _momomToken;
    // Mobox-ERC20 Token address
    IERC20 _moboxToken;
    // MOMO contract for openning chests
    IMoMoMinter public momoMinter;
    // The Mobox mining pool contract is used to manage the mining rate change/open/open for the second time.
    address public rewardMgr;
 
    // The auction staking contract (during the auction process, MOMO is still held by this contract)
    address public stakerAuction;

    // UnixtimeStamp of the end time of this round of mining
    uint256 public periodFinish;
    // The current player's mining output per second, plus the developer's simultaneous distribution, the actual mining rate is rewardRate * 1.25 (player: developer=4:1)
    uint256 public rewardRate;
    // Mining duration of this round (seconds)
    uint256 public rewardsDuration;
    // UnixtimeStamp of the start time of this round of mining
    uint256 public rewardStartTime;

    uint256 public lastUpdateTime;

    uint256 public rewardPerTokenStored;

    uint256 public rewardsReleasedForDev;

    uint256 public lastUpdateTimeForDev;
    // 
    address public devTeam;

    uint256 public totalHashrate;
    // uint256 public totalHashrate;
    // The number of different NFT prototypes of users V1-V4 is counted, and the mapping key is user address << 96 + NFT prototype. 
    //This recording method can avoid the use of nested mapping to record the information

    mapping (uint256 => uint256) _stakingMomoAmountMap;
    // ERC721(V4-V6) NFT, user address => ERC721 tokenId Array
    mapping (address => uint256[]) _stakingMomoArray;
    // NFT owner's info, ERC721 tokend => NftOwner        
    mapping (uint256 => NftOwner) _momoIdToOwnerAndIndex;
    
    mapping (address => UserRewardInfo) _userRewardInfoMap;

    mapping (address => UserMomoCount) _userMomoCounter;

    
    constructor() public {
        
    }

    function setRewardMgr(address addr_) external onlyOwner {
        require(address(_moboxToken) != address(0) && addr_ != rewardMgr, "invalid param");
        if (rewardMgr != address(0)) {
            _moboxToken.approve(rewardMgr, 0);
        }
        rewardMgr = addr_;
     
        // If the output of mobox is reduced, the mining pool 'rewardMgr' will retrieve the excess 'Mbox'
        // If the output of mobox increases, the mining pool 'rewardMgr' will send the missing 'Mbox' to the current contract
        _moboxToken.approve(rewardMgr, uint256(-1));
    }

    function setTokens(address momoToken_, address momomToken_, address moboxToken_) external onlyOwner {
        _momoToken = IMoMoToken(momoToken_);
        _momomToken = IMoMoMToken(momomToken_);
        _moboxToken = IERC20(moboxToken_);

        // The authorization is used to upgrade ERC721 NFT in this contract by users. Upgrading ERC721 requires ERC1155 specified by burn
        _momomToken.setApprovalForAll(momoToken_, true);     
    }

    function getTokens() external view returns(address momoToken, address momomToken, address moboxToken) {
        momoToken = address(_momoToken);
        momomToken = address(_momomToken);
        moboxToken = address(_moboxToken);
    }
    
    function setMoMoMinter(address addr_) external onlyOwner {
        momoMinter = IMoMoMinter(addr_);
    }

    function setMoMoStakerAuction(address addr_) external onlyOwner {
        stakerAuction = addr_;
    }

    function setDevTeam(address addr_) external onlyOwner {
        devTeam = addr_;
    }

    function _userHashrate(uint256 fixed_, uint256 _percent) internal pure returns(uint256) {
        return fixed_.mul(_percent + 10000).div(10000);
    }

    function userHashrate(address user_) external view returns(uint256) {
        UserRewardInfo memory info = _userRewardInfoMap[user_];
        return _userHashrate(uint256(info.userHashrateFixed), uint256(info.userHashratePercent));
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        if (block.timestamp < rewardStartTime) {
            return rewardStartTime;
        } else {
            return Math.min(block.timestamp, periodFinish);
        }
    }

    function _rewardPerHashrate(uint256 lastTimeRewardApplicable_) internal view returns (uint256) {
        if (totalHashrate == 0 || block.timestamp <= rewardStartTime) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored.add(
            lastTimeRewardApplicable_.sub(lastUpdateTime).mul(rewardRate).div(totalHashrate)
        );
    }

    function rewardPerHashrate() external view returns (uint256) {
        return _rewardPerHashrate(lastTimeRewardApplicable());
    }

    function _earned(address user_, uint256 rewardPerHashrate_) internal view returns (uint256) {
        UserRewardInfo memory info = _userRewardInfoMap[user_];
        uint256 userHashRate = uint256(info.userHashrateFixed).mul(uint256(info.userHashratePercent) + 10000).div(10000);
        return userHashRate.mul(rewardPerHashrate_.sub(uint256(info.userRewardPerTokenPaid))).add(uint256(info.userReward));
    }

    function earned(address user_) external view returns(uint256) {
        return _earned(user_, _rewardPerHashrate(lastTimeRewardApplicable()));
    }

    function devTeamEarned() external view returns(uint256) {
        if (lastUpdateTimeForDev >= periodFinish) {
            return rewardsReleasedForDev;
        } else {
            uint256 lastUpdateDev = Math.max(rewardStartTime, lastUpdateTimeForDev);
            uint256 currentUpdateTime = Math.min(block.timestamp, periodFinish);
            if (currentUpdateTime <= lastUpdateDev) {
                return rewardsReleasedForDev;
            } else {
                return rewardsReleasedForDev.add(
                    currentUpdateTime.sub(lastUpdateDev).mul(rewardRate).mul(devTeamRate).div(10000 - devTeamRate)
                );
            }
        }
    }

    function _updateReward(address user_) internal {
        uint256 lastTimeReward = lastTimeRewardApplicable();
        rewardPerTokenStored = _rewardPerHashrate(lastTimeReward);
        lastUpdateTime = lastTimeReward;

        if (user_ != address(0)) {
            UserRewardInfo storage info = _userRewardInfoMap[user_];
            info.userReward = SafeMathExt.safe128(_earned(user_, rewardPerTokenStored));
            info.userRewardPerTokenPaid = SafeMathExt.safe128(rewardPerTokenStored);
        }
    }

    function _updateDevTeamReward() internal {
        if (block.timestamp > rewardStartTime && lastUpdateTimeForDev < periodFinish) {
            uint256 minTime = Math.min(block.timestamp, periodFinish);
            uint256 lastUpdateDev = Math.max(rewardStartTime, lastUpdateTimeForDev);
            rewardsReleasedForDev = rewardsReleasedForDev.add(minTime.sub(lastUpdateDev).mul(rewardRate).mul(devTeamRate).div(10000 - devTeamRate));
            lastUpdateTimeForDev = minTime;
        } 
    }

    // Start a new round of mining every time, need to call 'initReward' first
    function initReward(uint256 rewardPerDay_, uint256 rewardStart_, uint256 days_) external {
        require(msg.sender == rewardMgr, "invalid caller");
        require(block.timestamp > periodFinish, "stake not finish");
        require(rewardStart_ > periodFinish && days_ > 0, "invalid start");
        
        _updateDevTeamReward();
        _updateReward(address(0));

        rewardStartTime = rewardStart_;
        rewardsDuration = days_.mul(86400);
        rewardRate = rewardPerDay_.mul(10000 - devTeamRate).div(10000).div(86400);

        uint256 balance = _moboxToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "not enough mbox");

        lastUpdateTime = rewardStartTime;
        periodFinish = rewardStartTime.add(rewardsDuration);
        lastUpdateTimeForDev = rewardStartTime;

        emit StakeRewardChange(rewardRate, block.timestamp);
    }

    function changeRewardRate(uint256 rewardPerDay_) external {
        require(msg.sender == rewardMgr, "invalid caller");
        require(block.timestamp > rewardStartTime && block.timestamp < periodFinish, "invaild call");
        _changeRewardRate(rewardPerDay_);
    }

    function _changeRewardRate(uint256 rewardPerDay_) internal {
        //  Update the calculation of developer's simultaneous release reward before the rewardRate update
        _updateDevTeamReward();

        // updateReward
        uint256 lastTimeReward = lastTimeRewardApplicable();
        rewardPerTokenStored = _rewardPerHashrate(lastTimeReward);
        lastUpdateTime = lastTimeReward;

        rewardRate = rewardPerDay_.mul(10000 - devTeamRate).div(10000).div(86400);

        uint256 balance = _moboxToken.balanceOf(address(this));
        require(rewardRate <= balance.div(periodFinish.sub(block.timestamp)), "not enough mbox");

        emit StakeRewardChange(rewardRate, block.timestamp);   
    }

    function getDevTeamReward() external {
        require(msg.sender == owner() || msg.sender == devTeam, "invalid caller");
        _updateDevTeamReward();
        uint256 amount = rewardsReleasedForDev;
        rewardsReleasedForDev = 0;

        _moboxToken.transfer(devTeam, amount);
    }
    
    function _checkCrew(uint256 prototype_, uint256 addrPrefix_) internal view returns(bool) {
        for (uint256 i = 1; i <= 4; ++i) {
            if (i != prototype_ / 10000 && _stakingMomoAmountMap[addrPrefix_ + 10000 * i + (prototype_ % 10000)] == 0) {
                return false;
            }
        }
        return true;
    }

    function _checkCollection(address user_) internal view returns(uint256 percent) {
        UserMomoCount storage counter = _userMomoCounter[user_];
        // V4 collection
        uint256 amount = uint256(counter.amountV4);
        if (amount > 0) {
            if (amount <= 10) {
                percent = amount / 5 * 200;                     // 0% ~ 4%
            } else if (amount <= 50) {
                percent = (amount - 10) / 5 * 100 + 400;        // 4% ~ 12%
            } else if (amount <= 100) {
                percent = (amount - 50) / 10 * 100 + 1200;      // 12% ~ 17%
            } else if (amount <= 200) {
                percent = (amount - 100) / 25 * 100 + 1700;     // 17% ~ 21%
            } else if (amount <= 500) {
                percent = (amount - 200) / 50 * 100 + 2100;     // 21% ~ 27%
            } else {
                percent = 2700;                                 // 27%
            }
        }
        // V5 collection
        amount = uint256(counter.amountV5);
        if (amount > 0) {
            if (amount <= 6) {
                percent += (amount / 3 * 500);                   // 0% ~ 10%
            } else if (amount <= 30) {
                percent += ((amount - 6) / 3 * 250 + 1000);     // 10% ~ 30%
            } else if (amount <= 60) {
                percent += ((amount - 30) / 6 * 250 + 3000);    // 30% ~ 42.5%
            } else if (amount <= 120) {
                percent += ((amount - 60) / 15 * 250 + 4250);   // 42.5% ~ 52.5%
            } else {
                percent += 5250;                                // 52.5%
            }
        }
        // V6 collection
        amount = uint256(counter.amountV6);
        if (amount > 1) {
            if (amount <= 2) {
                percent += (amount * 300);                      // 0% ~ 6%
            } else if (amount <= 10) {
                percent += ((amount - 2) * 300 + 600);          // 6% ~ 30%
            } else if (amount <= 20) {
                percent += ((amount - 10) / 2 * 300 + 3000);    // 30% ~ 45%
            } else if (amount <= 30) {
                percent += ((amount - 20) / 5 * 300 + 4500);    // 45% ~ 51%
            } else {
                percent += 5100;                                // 51%
            }
        }
    }

    function _stakeNft(
        address user_,
        uint256[] memory ids_, 
        uint256[] memory amounts_, 
        uint256[] memory tokenIds_, 
        bool doTransfer_, 
        uint256 changeType_
    ) internal {
        require(ids_.length == amounts_.length, "invalid param");
        
        uint256 addrPrefix = uint256(user_) << 96;
        uint256 prototype;
        uint256 i;
        uint256 oldAmount;
        uint256 hashrateFixed;
        
        if (ids_.length > 0) {
            if (doTransfer_) {
                _momomToken.safeBatchTransferFrom(user_, address(this), ids_, amounts_, "");
            }
            
            for (i = 0; i < ids_.length; ++i) {
                if (ids_[i] > 0 && amounts_[i] > 0) {
                    require(ids_[i] > 10000 && ids_[i] < 40000 && amounts_[i] < 0x08000000, "invalid 1155");
                    hashrateFixed = hashrateFixed.add((ids_[i] / 10000).mul(amounts_[i]));

                    prototype = uint256(addrPrefix + ids_[i]);
                    oldAmount = _stakingMomoAmountMap[prototype];
                    _stakingMomoAmountMap[prototype] = oldAmount.add(amounts_[i]);
                    if (oldAmount == 0) {
                        if (_checkCrew(ids_[i], addrPrefix)) {
                            hashrateFixed = hashrateFixed.add(HASHRATE_CREW);
                        }
                    }
                }
            }
        }
        
        if (tokenIds_.length > 0) {
            uint256 hashrate;
            uint256[] storage momos = _stakingMomoArray[user_];
            UserMomoCount storage counter = _userMomoCounter[user_];
            for (i = 0; i < tokenIds_.length; ++i) {
                require(tokenIds_[i] > 0 && tokenIds_[i] < 0x0100000000, "invalid momo");
                if (doTransfer_) {
                    _momoToken.transferFrom(user_, address(this), tokenIds_[i]);
                }
                (prototype, hashrate) = _momoToken.getMomoSimpleByTokenId(tokenIds_[i]);
                require(prototype > 40000 && prototype < 65536, "invalid momo");
                hashrateFixed = hashrateFixed.add(hashrate);

                _momoIdToOwnerAndIndex[tokenIds_[i]] = NftOwner(user_, SafeMathExt.safe64(momos.length));
                momos.push(tokenIds_[i]);

                if (prototype / 10000 == 4) {
                    counter.amountV4 = SafeMathExt.add64(counter.amountV4, uint64(1));

                    oldAmount = _stakingMomoAmountMap[addrPrefix + prototype];
                    _stakingMomoAmountMap[addrPrefix + prototype] = oldAmount.add(1);
                    if (oldAmount == 0) {
                        if (_checkCrew(prototype, addrPrefix)) {
                            hashrateFixed = hashrateFixed.add(HASHRATE_CREW);
                        }
                    }
                } else if (prototype / 10000 == 5) {
                    counter.amountV5 = SafeMathExt.add64(counter.amountV5, 1);
                } else {
                    counter.amountV6 = SafeMathExt.add64(counter.amountV6, 1);
                } 
            }
        }

        uint256 oldHashRate;
        uint256 newHashRate;
        (oldHashRate, newHashRate) = _calcHashrate(user_, hashrateFixed, 0); 
        emit HashrateChange(user_, changeType_, oldHashRate, newHashRate);
    }

    // options: doTransfer 0x01
    //          realRemove 0x02
    function _removeNft(
        address user_,
        uint256[] memory ids_, 
        uint256[] memory amounts_, 
        uint256[] memory tokenIds_, 
        uint256 options, 
        uint256 changeType_
    ) internal returns(uint256 hashrateFixed) {
        require(ids_.length == amounts_.length, "invalid param");

        uint256[4] memory shareParams;          // addressPrefix|oldAmount|hashrate1|hashrate2, for lower stack
        shareParams[0] = uint256(user_) << 96;
        uint256 prototype;
        uint256 i;
        
        if (ids_.length > 0) {
            for (i = 0; i < ids_.length; ++i) {
                require(ids_[i] > 10000 && ids_[i] < 40000 && amounts_[i] > 0 && amounts_[i] < 0x08000000, "invalid 1155");
                prototype = uint256(shareParams[0] + ids_[i]);
                shareParams[1] = _stakingMomoAmountMap[prototype];
                _stakingMomoAmountMap[prototype] = shareParams[1].sub(amounts_[i]);

                hashrateFixed = hashrateFixed.add((ids_[i] / 10000).mul(amounts_[i]));
                
                // need amounts_[i] > 0
                if (shareParams[1] == amounts_[i]) {
                    if (_checkCrew(ids_[i], shareParams[0])) {
                        hashrateFixed = hashrateFixed.add(HASHRATE_CREW);
                    }
                }
            }
            // doTransfer
            if ((options & 0x01) > 0) {
                _momomToken.safeBatchTransferFrom(address(this), user_, ids_, amounts_, "");
            }
        }

        
        if (tokenIds_.length > 0) {
            uint256[] storage momos = _stakingMomoArray[user_];
            UserMomoCount storage counter = _userMomoCounter[user_];
            for (i = 0; i < tokenIds_.length; ++i) {
                NftOwner storage nfto = _momoIdToOwnerAndIndex[tokenIds_[i]];
                require(user_ == address(nfto.addr), "invalid 721");
                
                (prototype, shareParams[1]) = _momoToken.getMomoSimpleByTokenId(tokenIds_[i]);
                hashrateFixed = hashrateFixed.add(shareParams[1]);
                
                if (uint256(nfto.index) != momos.length.sub(1)) {
                    momos[uint256(nfto.index)] = momos[momos.length.sub(1)]; 
                    _momoIdToOwnerAndIndex[momos[uint256(nfto.index)]].index = nfto.index;
                }
                momos.pop();
                // realRemove
                if ((options & 0x02) > 0) {
                    delete _momoIdToOwnerAndIndex[tokenIds_[i]];
                } else {
                    // for save gas
                    nfto.addr = address(0);  
                    nfto.index = 0xffffffffffffffff;
                }
                // doTransfer
                if ((options & 0x01) > 0) {
                    _momoToken.transferFrom(address(this), user_, tokenIds_[i]);
                }
                
                if (prototype / 10000 == 4) {
                    counter.amountV4 = SafeMathExt.sub64(counter.amountV4, uint64(1));

                    shareParams[1] = _stakingMomoAmountMap[shareParams[0] + prototype];
                    _stakingMomoAmountMap[shareParams[0] + prototype] = shareParams[1].sub(1);
                    if (shareParams[1] == 1) {
                        if (_checkCrew(prototype, shareParams[0])) {
                            hashrateFixed = hashrateFixed.add(HASHRATE_CREW);
                        }
                    }
                } else if (prototype / 10000 == 5) {
                    counter.amountV5 = SafeMathExt.sub64(counter.amountV5, 1);
                } else {
                    counter.amountV6 = SafeMathExt.sub64(counter.amountV6, 1);
                } 
            }
        }

        if (changeType_ > 0) {
            (shareParams[2], shareParams[3]) = _calcHashrate(user_, 0, hashrateFixed); 
            emit HashrateChange(user_, changeType_, shareParams[2], shareParams[3]);
        }
    }

    function stakeNftByAuction(
        address user_, 
        uint256[] memory ids_, 
        uint256[] memory amounts_, 
        uint256[] memory tokenIds_, 
        bool doTransfer_, 
        uint256 changeType_
    ) external {
        require(msg.sender == stakerAuction, "not auction caller");
        _updateReward(user_); 
        _stakeNft(user_, ids_, amounts_, tokenIds_, doTransfer_, changeType_);
    }

    function removeNftByAuction(
        address user_,
        uint256[] memory ids_, 
        uint256[] memory amounts_, 
        uint256[] memory tokenIds_, 
        uint256 options_, 
        uint256 changeType_
    ) external {
        require(msg.sender == stakerAuction, "not auction caller");
        _updateReward(user_);
        _removeNft(user_, ids_, amounts_, tokenIds_, options_, changeType_);
    }

    function _calcHashrate(address user_, uint256 hashrateFixedAdd_, uint256 hashrateFixedSub_) internal returns(uint256 oldHashRate, uint256 newHashRate) {
        UserRewardInfo storage info = _userRewardInfoMap[user_];
        oldHashRate = _userHashrate(uint256(info.userHashrateFixed), uint256(info.userHashratePercent));

        if (hashrateFixedSub_ > 0) {
            info.userHashrateFixed = SafeMathExt.sub128(info.userHashrateFixed, SafeMathExt.safe128(hashrateFixedSub_));
        }

        if (hashrateFixedAdd_ > 0) {
            info.userHashrateFixed = SafeMathExt.add128(info.userHashrateFixed, SafeMathExt.safe128(hashrateFixedAdd_));
        }
        
        info.userHashratePercent = SafeMathExt.safe128(_checkCollection(user_));
        newHashRate = _userHashrate(uint256(info.userHashrateFixed), uint256(info.userHashratePercent));
        totalHashrate = totalHashrate.add(newHashRate).sub(oldHashRate);
    }

    function stake(uint256[] memory ids_, uint256[] memory amounts_, uint256[] memory tokenIds_) external nonReentrant {
        _updateReward(msg.sender);
        _stakeNft(msg.sender, ids_, amounts_, tokenIds_, true, 1); 
    }

    function mintAndStake(uint256 amount_) external nonReentrant {
        _updateReward(msg.sender);

        uint256[] memory ids;
        uint256[] memory vals;
        uint256[] memory tokenIds;

        (ids, vals, tokenIds) = momoMinter.mintByStaker(msg.sender, amount_);
        _stakeNft(msg.sender, ids, vals, tokenIds, false, 2);
        emit MintStake(msg.sender, ids, vals, tokenIds);
    }

    function levelUp(uint256 tokenId_, uint256[] memory protosV1V2V3_, uint256[] memory amountsV1V2V3_, uint256[] memory tokensV4V5_) 
        external 
        nonReentrant 
    {        
        require(msg.sender == address(_momoIdToOwnerAndIndex[tokenId_].addr), "not owner");
        _updateReward(msg.sender);

         // doTransfer = false, realRemove = true
        uint256 hashrateFixedSub = _removeNft(msg.sender, protosV1V2V3_, amountsV1V2V3_, tokensV4V5_, 0x02, 0);
        uint256 hashrateOldLevel;
        (, hashrateOldLevel) = _momoToken.getMomoSimpleByTokenId(tokenId_);
         
        _momoToken.levelUp(tokenId_, protosV1V2V3_, amountsV1V2V3_, tokensV4V5_);
        uint256 hashrateLevelUp;
        (, hashrateLevelUp) = _momoToken.getMomoSimpleByTokenId(tokenId_);
        hashrateLevelUp = hashrateLevelUp.sub(hashrateOldLevel);
        uint256 oldHashRate;
        uint256 newHashRate;
        (oldHashRate, newHashRate) = _calcHashrate(msg.sender, hashrateLevelUp, hashrateFixedSub); 
        emit LevelUpBurnStake(msg.sender, protosV1V2V3_, amountsV1V2V3_, tokensV4V5_);
        emit HashrateChange(msg.sender, 4, oldHashRate, newHashRate);
    }

    function setMomoName(uint256 tokenId_, bytes memory name_) external payable {
        require(msg.sender == address(_momoIdToOwnerAndIndex[tokenId_].addr), "not 721 owner");
        _momoToken.setMomoName{value: msg.value}(tokenId_, name_);
    }

    function addMomoStory(uint256 tokenId_, bytes memory story_) external payable {
        require(msg.sender == address(_momoIdToOwnerAndIndex[tokenId_].addr), "not 721 owner");
        _momoToken.addMomoStory{value: msg.value}(tokenId_, story_);
    }

    function withdraw(uint256[] memory ids_, uint256[] memory amounts_, uint256[] memory tokenIds_) external nonReentrant {
        _updateReward(msg.sender);
        // doTransfer = true, realRemove = true
        _removeNft(msg.sender, ids_, amounts_, tokenIds_, 0x03, 3);
    } 

    function getReward() external nonReentrant {
        _updateReward(msg.sender);

        UserRewardInfo storage info = _userRewardInfoMap[msg.sender];
        uint256 userReward = uint256(info.userReward);
        if (userReward > 0) {
            info.userReward = 0;
            _moboxToken.transfer(msg.sender, userReward);
            emit WithdrawReward(msg.sender, userReward);
        }
    }

    function balanceOfOneBatch(address owner_, uint256[] memory ids_) external view returns(uint256[] memory batchBalances) {
        batchBalances = new uint256[](ids_.length);
        uint256 addrPrefix = uint256(owner_) << 96;
        for (uint256 i = 0; i < ids_.length; ++i) {
            batchBalances[i] = _stakingMomoAmountMap[addrPrefix + ids_[i]];
        }
    }

    function balanceOfMomo(address owner_) external view returns(uint256) {
        return _stakingMomoArray[owner_].length;
    }

    function tokenOfOwnerByIndex(address owner_, uint256 index_) external view returns(uint256) {
        return _stakingMomoArray[owner_][index_];
    }

    function tokensOfOwner(address owner_) external view returns(uint256[] memory tokenIds) {
        tokenIds = _stakingMomoArray[owner_];
    }
}

