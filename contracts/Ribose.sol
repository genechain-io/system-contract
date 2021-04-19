// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "./libraries/SafeMath.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/Logarithm.sol";

contract Ribose {
    using SafeMath for uint256;
    
    // System params
    uint16 public constant MaxValidators = 21;
    uint16 public constant MaxTopCandidates = 50;
    uint16 public constant MaxStakeCount = 5;

    uint32 public constant FullProfitShare = 1_000_000_000;

    uint256 public constant MinimalStakingRNA = 1 ether;
    uint256 public constant MinimalStakingARM = 1 ether;

    uint256 public constant PunishThreshold = 24;
    uint256 public constant PunishDecreaseInterval = 1200;
    uint256 public constant JailThreshold = 48;
    uint256 public constant JailReleaseThreshold = 12;
    
    uint64 public constant StakingLockPeriod = 86400;   // 72 hours, stakers have to wait StakingLockPeriod blocks to withdraw staking
    uint64 public constant PendingSettlePeriod = 28800; // 24 hours, pending income will be punished
    
    uint256 public constant ProfitValueScale = 1_000_000_000;
    
    uint256 public constant BlockProfitCycle = 20_000_000;
    uint256[] public BlockProfits; // Predefined block profit, index grow every 20,000,000 blocks(2 year)
    address public constant ARMAddr = 0x000000000000000000000000000000000000c000; // ARM ERC20 contract address
    bool public initialized;
        
    struct Candidate {
        string website;                 // website of this candidate
        string email;                   // email of this candidate
        string details;                 // detailed info of this candidate

        address payable profitTaker;    // who tasks validator's part of profit
        uint32 stakerShare;             // ratio of profit send to stakers (stakerShare/FullProfitShare)

        uint256 stakePower;             // total stake power (∑(RNA * ln(ARM)))
        uint256 stakeRNA;               // total RNA staked for this candidate;
        uint256 stakeARM;               // total ARM staked for this candidate;

        uint256 profitValue;            // current profit value

        uint256 totalMined;             // block profit mined by this candidate
        uint256 totalFee;               // block fee gathered by this candidate

        uint256 minerProfit;            // unwithdrew profit of this miner(validator share)
        uint256 pendingProfit;          // profit of this candidate in pending state
        uint256 pendingSettleBlock;     // last time we settle profit 
        
        uint256 missedBlocks;           // blocks we should produce but missed
        bool jailed;                    // wether this candidate is jailed state
        uint256 punishedAtBlock;        // when did this miner get punished last time
        
        uint256 createTime;             // registration timestamp of this candidate
    }

    struct StakeingInfo {
        uint256 rna;            // amount of RNA staked
        uint256 arm;            // amount of ARM staked
        uint256 bookAtValue;    // booked value since last time 
        uint256 lockBlock;      // last time we stake/unstake, staked assets will be locked since this record
    }
    
    mapping(address => Candidate) candidates;                       // all candidates list
    mapping(address => mapping(address => StakeingInfo)) stakes;    // all stakes (map[candidate][staker]StakeInfo)
    mapping(address => address[]) stakers;                          // all stakers (map[candidate]candidatesArray)
    mapping(address => uint256) profitBook;                         // profits to be claimed (map[staker]profitValue)

    address[] public topCandidates; // top (MaxTopCandidates) top candidates that may become validator
    address[] public validators;    // top (MaxValidators) validators who is mining

    enum Operations {Distribute, UpdateValidators}
    mapping(uint256 => mapping(uint8 => bool)) operationsDone;

    mapping(uint256 => bool) punished;
    mapping(uint256 => bool) decreased;

    // event ARMSet(
    //     address indexed armAddr
    // );
    
    event LogRegister(
        address indexed candidate,
        uint256 time
    );

    event LogCandidateUpdate(
        address indexed candidate,
        uint256 time
    );

    event LogShareRateUpdate(
        address indexed candidate,
        uint256 time
    );

    event LogStake(
        address indexed candidate,
        address indexed staker,
        uint256 rna,
        uint256 arm,
        uint256 time
    );

    event LogUnstake(
        address indexed candidate,
        address indexed staker,
        uint256 rna,
        uint256 arm,
        uint256 time
    );

    event LogStakerWithdraw(
        address indexed staker,
        uint256 indexed amount,
        uint256 time
    );

    event LogMinerWithdraw(
        address indexed candidate,
        address indexed withdrawer,
        uint256 indexed amount,
        uint256 time
    );

    event LogPunishValidator(address indexed val, uint256 time);
    event LogJailValidator(address indexed val, uint256 time);

    event LogTopCandidatesAdd(address indexed val, uint256 time);
    event LogTopCandidatesRemove(address indexed val, uint256 time);
    
    event LogDistributeBlockReward(
        address indexed coinbase,
        uint256 indexed blockReward,
        uint256 time
    );

    event LogUpdateValidator(address[] newSet);
    
    modifier onlyNotInitialized() {
        require(!initialized, "Already initialized");
        _;
    }

    modifier onlyInitialized() {
        require(initialized, "Not init yet");
        _;
    }
    
    modifier onlyMiner() {
        require(msg.sender == block.coinbase, "Miner only");
        _;
    }
    
    modifier onlyNotRewarded() {
        require(
            operationsDone[block.number][uint8(Operations.Distribute)] == false,
            "Block is already rewarded"
        );
        _;
    }

    modifier onlyNotUpdated() {
        require(
            operationsDone[block.number][uint8(Operations.UpdateValidators)] ==
                false,
            "Validators already updated"
        );
        _;
    }
    
    modifier onlyBlockEpoch(uint256 epoch) {
        require(block.number % epoch == 0, "Block epoch only");
        _;
    }
    
    modifier onlyNotPunished() {
        require(!punished[block.number], "Already punished");
        _;
    }

    // init validators by genesis config
    function initialize(address[] calldata vals) external onlyNotInitialized {
        require(vals.length <= MaxValidators, "Too many validators");
        // initialize predefined block profits
        BlockProfits.push(2 ether);
        BlockProfits.push(1 ether);
        BlockProfits.push(500_000_000 gwei);
        BlockProfits.push(250_000_000 gwei);
        BlockProfits.push(125_000_000 gwei);
        BlockProfits.push(125_000_000 gwei);
        // init validators
        for (uint256 i = 0; i < vals.length; i++) {
            require(vals[i] != address(0), "Invalid validator address");
            address payable val = payable(vals[i]);
            // create a candidate
            if (candidates[val].profitTaker == address(0)) {
                Candidate memory candidate;
                candidate.profitTaker = val; // set oneself as taker
                candidate.createTime = block.timestamp;
                candidate.pendingSettleBlock = block.number;
                candidates[vals[i]] = candidate;
            }
            // add it into validators array
            if (!isValidator(val)) {
                validators.push(val);
            }
            // add it into topCandidates array
            if (!isTopCandidate(val)) {
                topCandidates.push(val);
            }
        }
        initialized = true;
    }
    
    // register as validator candidate
    function register(/*uint32 stakerShare*/) external onlyInitialized returns (bool) {
        address payable nominee = msg.sender;
        require(candidates[nominee].createTime == 0, "Already registered");
        // require(stakerShare <= FullProfitShare, "Staker share overflow");
        
        Candidate memory candidate;
        candidate.profitTaker = nominee;
        candidate.stakerShare = 800_000_000; //stakerShare;
        candidate.createTime = block.timestamp;
        candidate.pendingSettleBlock = block.number;
        candidates[nominee] = candidate;

        emit LogRegister(nominee, block.timestamp);
        return true;
    }

    // update candidate's description
    function updateCandidateDescription(
        string calldata website,
        string calldata email,
        string calldata details
    ) external onlyInitialized returns (bool) {
        address candidate = msg.sender;
        require(candidates[candidate].createTime > 0, "Candidate not registered");
        require(bytes(website).length <= 256, "Invalidate website length");
        require(bytes(email).length <= 256, "Invalidate email length");
        require(bytes(details).length <= 4096, "Invalidate details length");

        candidates[candidate].website = website;
        candidates[candidate].email = email;
        candidates[candidate].details = details;
        
        emit LogCandidateUpdate(candidate, block.timestamp);

        return true;
    }

    // get candidate's description
    function getCandidateDescription(address candidate)
        external view returns (
            string memory,
            string memory,
            string memory
        ) {
        Candidate memory c = candidates[candidate];
        return (
            c.website,
            c.email,
            c.details
        );
    }
    
    // get stake state of a candidate
    function getCandidateStakeInfo(address candidate)
        external view returns (
            uint256,    // stakerShare
            uint256,    // stakePower
            uint256,    // stakeRNA
            uint256,    // stakeARM
            uint256     // profitValue
        ) {
        Candidate memory c = candidates[candidate];
        return(
            c.stakerShare,
            c.stakePower,
            c.stakeRNA,
            c.stakeARM,
            c.profitValue
        );
    }
            

    // get state of a candidate
    function getCandidateState(address candidate)
        external view returns (
            address,    // profitTaker
            uint256,    // totalMined
            uint256,    // totalFee
            uint256,    // createTime
            uint256,    // minerProfit
            uint256,    // pendingProfit
            uint256,    // pendingSettleBlock
            bool        // jailed
        ) {
        Candidate memory c = candidates[candidate];
        return (
            c.profitTaker,
            c.totalMined,
            c.totalFee,
            c.createTime,
            c.minerProfit,
            c.pendingProfit,
            c.pendingSettleBlock,
            c.jailed
        );
    }

    // calculate stake power from RNA & ARM amount
    function _calcStakePower(uint256 rna, uint256 arm) internal pure returns (uint256) {
        if (rna == 0) {
            return 0;
        }
        // ARM less than e(2.718281828459045236) will be ignored
        if (arm <= 0x25B946EBC0B36174) { 
            return rna;
        }
        // RNA * ln(ARM)
        uint256 decimalScale = 1 ether;
        int128 armValue = Logarithm.divu(arm, decimalScale);
        int128 powerScale = Logarithm.ln(armValue);
        return Logarithm.mulu(powerScale, rna);
    }

    // calculate profit from value delta & power
    function _calcStakerProfit(uint256 valueDelta, uint256 power) internal pure returns (uint256) {
        uint256 profit = power.mul(valueDelta).div(ProfitValueScale);
        return profit;
    }

    // calculate reward of a block by block number
    function _currentBlockReward() internal view returns (uint256) {
        // 20,000,000 blocks(2 year, 347.22 days) per cycle
        uint256 index = block.number.div(BlockProfitCycle);
        if (index < BlockProfits.length) {
            // first 0-12 years(first 6 cycles)
            return BlockProfits[index];
        }
        return 0;
    }

    // book profits of a staker up to now
    function _bookStakerProfit(address candidate, address staker) internal {
        uint256 currentValue = candidates[candidate].profitValue;
        uint256 lastValue = stakes[candidate][staker].bookAtValue;
        uint256 valueDelta = currentValue - lastValue;
        if (valueDelta > 0) {
            uint256 power = _calcStakePower(stakes[candidate][staker].rna, stakes[candidate][staker].arm);
            uint256 profit = _calcStakerProfit(valueDelta, power);
            // write this profit into profit book
            profitBook[staker] += profit;
            stakes[candidate][staker].bookAtValue = currentValue;
        }
    }
    
    // try settle a miner's profit in pending state
    function _trySettleMinerProfit(address candidate) internal {
        if (
            candidates[candidate].pendingSettleBlock + PendingSettlePeriod <= block.number
            && candidates[candidate].pendingProfit > 0
        ) {
            // only settle half of pending profit, others will be reserved for punishment
            uint256 halfProfit = candidates[candidate].pendingProfit.div(2);
            candidates[candidate].minerProfit += (candidates[candidate].pendingProfit - halfProfit);
            candidates[candidate].pendingProfit = halfProfit;
            candidates[candidate].pendingSettleBlock = block.number;
        }
    }
    
    // update candidate's punish status
    function _updatePunishRecord(address candidate) internal {
        if (candidates[candidate].punishedAtBlock > 0) {
            // calculate punish decrease since last update
            uint256 alreadyDecrease = (block.number - candidates[candidate].punishedAtBlock).div(PunishDecreaseInterval);
            if (alreadyDecrease > 0) {
                if (candidates[candidate].missedBlocks > alreadyDecrease) {
                    // still has punish after decrease
                    candidates[candidate].missedBlocks -= alreadyDecrease;
                    candidates[candidate].punishedAtBlock = block.number;
                } else {
                    // punish cleared
                    candidates[candidate].missedBlocks = 0;
                    candidates[candidate].punishedAtBlock = 0;
                }
            }
        }
        if (candidates[candidate].jailed && candidates[candidate].missedBlocks <= JailReleaseThreshold) {
            // release from jail if reach release threshold
            candidates[candidate].jailed = false;
        }
    }

    // update top list when a candidate's power changes
    function _updateTopList(address candidate) internal {
        if (candidates[candidate].jailed) {
            return;
        }
        // check if candidate is already in list
        for (uint256 i = 0; i < topCandidates.length; i++) {
            if (topCandidates[i] == candidate) {
                // already in topCandidates
                return;
            }
        }
        // list not full yet, add it into list
        if (topCandidates.length < MaxTopCandidates) {
            topCandidates.push(candidate);
            return;
        }
        // list is full, try to replace the lowest one
        uint256 lowestIndex = 0;
        uint256 lowestPower = candidates[topCandidates[0]].stakePower;
        
        for (uint256 i = 1; i < topCandidates.length; i++) {
            if (lowestPower > candidates[topCandidates[i]].stakePower) {
                lowestPower = candidates[topCandidates[i]].stakePower;
                lowestIndex = i;
            }
        }
        if (lowestPower < candidates[candidate].stakePower) {
            emit LogTopCandidatesRemove(topCandidates[lowestIndex], block.timestamp);
            topCandidates[lowestIndex] = candidate;
            emit LogTopCandidatesAdd(candidate, block.timestamp);
        }
    }
    
    // add a candidate record to a staker
    function _addStakedCandidate(address staker, address candidate) internal {
        for (uint256 i = 0; i < stakers[staker].length; i++) {
            if (stakers[staker][i] == candidate) {
                return;
            }
        }
        stakers[staker].push(candidate);
    }
    
    // remove a candidate record to a staker
    function _removeStakedCandidate(address staker, address candidate) internal {
        for (uint256 i = 0; i < stakers[staker].length; i++) {
            if (stakers[staker][i] == candidate) {
                stakers[staker][i] = stakers[staker][stakers[staker].length - 1];
                stakers[staker].pop();
                return;
            }
        }
    }
    
    // stake for a candidate
    function _stake(
        address candidate,
        address staker,
        uint256 rnaAmount,
        uint256 armAmount
    ) internal returns (bool) {
        require(candidates[candidate].createTime > 0, "Candidate not registered");
        require(rnaAmount >= MinimalStakingRNA || armAmount >= MinimalStakingARM, "Staking RNA/ARM not enough");

        // transfer specified amount of ARM ERC20 token to this contract
        // should appove first
        if (armAmount > 0) {
            TransferHelper.safeTransferFrom(ARMAddr, staker, address(this), armAmount);
        }

        // update stake info
        if (stakes[candidate][staker].lockBlock == 0) {
            // not staked for this candidate yet
            require(stakers[staker].length < MaxStakeCount, "Staked too many candidates");
            _addStakedCandidate(staker, candidate);
            StakeingInfo memory stakeInfo;
            stakeInfo.rna = rnaAmount;
            stakeInfo.arm = armAmount;
            stakeInfo.bookAtValue = candidates[candidate].profitValue;
            stakeInfo.lockBlock = block.number;
            stakes[candidate][staker] = stakeInfo;
            uint256 power = _calcStakePower(rnaAmount, armAmount);
            candidates[candidate].stakePower += power;
        } else {
            // try book profits up to now first
            _bookStakerProfit(candidate, staker);
            // update stake power
            uint256 oldPower = _calcStakePower(stakes[candidate][staker].rna, stakes[candidate][staker].arm);
            stakes[candidate][staker].rna += rnaAmount;
            stakes[candidate][staker].arm += armAmount;
            stakes[candidate][staker].lockBlock = block.number;
            uint256 newPower = _calcStakePower(stakes[candidate][staker].rna, stakes[candidate][staker].arm);
            uint256 delta = newPower - oldPower;
            candidates[candidate].stakePower += delta;
        }
        candidates[candidate].stakeRNA += rnaAmount;
        candidates[candidate].stakeARM += armAmount;
        emit LogStake(candidate, staker, rnaAmount, armAmount, block.timestamp);
        _updatePunishRecord(candidate);
        _updateTopList(candidate);
        return true;
    }
    
    
    // stake RNA for a candidate
    function stakeRNA(
        address candidate
    ) external payable onlyInitialized returns (bool) {
        return _stake(candidate, msg.sender, msg.value, 0);
    }
    
    function stakeARM(
        address candidate, 
        uint256 armAmount
    ) external onlyInitialized returns (bool) {
        return _stake(candidate, msg.sender, 0, armAmount);
    }

    // stake for a candidate
    function stake(
        address candidate, 
        uint256 armAmount
    ) external payable onlyInitialized returns (bool) {
        return _stake(candidate, msg.sender, msg.value, armAmount);
    }

    // query a staker's stake info
    function getStakingInfo(address candidate, address staker)
        external
        view
        returns (
            uint256,    // RNA
            uint256,    // ARM
            uint256,    // power
            uint256,    // bookAtValue
            uint256     // lockBlock
        ) {
        uint256 power = _calcStakePower(stakes[candidate][staker].rna, stakes[candidate][staker].arm);
        return (
            stakes[candidate][staker].rna,
            stakes[candidate][staker].arm,
            power,
            stakes[candidate][staker].bookAtValue,
            stakes[candidate][staker].lockBlock
        );
    }

    // get a list of candidates staker support
    function getStakedCandidates(address staker) external view returns (address[] memory) {
        return stakers[staker];
    }
    
    // unstake for a candidate
    function _unstake(
        address candidate, 
        address payable staker, 
        uint256 rnaAmount, 
        uint256 armAmount
    ) internal returns (bool) {
        require(stakes[candidate][staker].rna >= rnaAmount, "Not enough RNA to unstake");
        require(stakes[candidate][staker].arm >= armAmount, "Not enough ARM to unstake");
        require(stakes[candidate][staker].lockBlock + StakingLockPeriod <= block.number, "Cannot unstake when in locking");
        require(rnaAmount > 0 || armAmount > 0, "Unstake amount should not be 0");

        _bookStakerProfit(candidate, staker);
        
        uint256 oldPower = _calcStakePower(stakes[candidate][staker].rna, stakes[candidate][staker].arm);
        stakes[candidate][staker].rna -= rnaAmount;
        stakes[candidate][staker].arm -= armAmount;
        stakes[candidate][staker].lockBlock = block.number;

        uint256 newPower = 0;
        if (stakes[candidate][staker].rna != 0) {
            newPower = _calcStakePower(stakes[candidate][staker].rna, stakes[candidate][staker].arm);
        }

        if (rnaAmount > 0) {
            staker.transfer(rnaAmount);
        }
        if (armAmount > 0) {
            TransferHelper.safeTransferFrom(ARMAddr, address(this), staker, armAmount);
        }

        uint256 delta = oldPower - newPower;
        candidates[candidate].stakePower -= delta;
        
        // nolonger staking for this candidate
        if (stakes[candidate][staker].rna == 0 && stakes[candidate][staker].arm == 0) {
            _removeStakedCandidate(staker, candidate);
        }
        
        emit LogUnstake(candidate, staker, rnaAmount, armAmount, block.timestamp);
        
        return true;
    }    
    
    function unstakeRNA(
        address candidate, 
        uint256 rnaAmount
    ) external onlyInitialized returns (bool) {
        return _unstake(candidate, msg.sender, rnaAmount, 0);
    }
    
    // unstake for a candidate
    function unstakeARM(
        address candidate,
        uint256 armAmount
    ) external onlyInitialized returns (bool) {
        return _unstake(candidate, msg.sender, 0, armAmount);
    }    

    // unstake for a candidate
    function unstake(
        address candidate, 
        uint256 rnaAmount, 
        uint256 armAmount
    ) external onlyInitialized returns (bool) {
        return _unstake(candidate, msg.sender, rnaAmount, armAmount);
    }
    
    // query unsettled staker profit for a candidate
    function getStakerUnsettledProfit(address candidate, address staker) external view returns (uint256) {
        uint256 currentValue = candidates[candidate].profitValue;
        uint256 lastValue = stakes[candidate][staker].bookAtValue;
        uint256 valueDelta = currentValue - lastValue;
        if (valueDelta > 0) {
            uint256 power = _calcStakePower(stakes[candidate][staker].rna, stakes[candidate][staker].arm);
            uint256 profit = _calcStakerProfit(valueDelta, power);
            return profit;
        }
        return 0;
    }
    
    // settle one's stake profit manually
    function settleStakerProfit(
        address candidate
    ) external onlyInitialized returns (bool) {
        address staker = msg.sender;
        _bookStakerProfit(candidate, staker);
        return true;
    }

    // withdraw staker profit
    function withdrawStakerProfits(
        address payable staker
    ) external onlyInitialized returns (bool) {
        uint256 amount = profitBook[staker];
        require(amount > 0, "No profit to withdraw");
        staker.transfer(amount);
        profitBook[staker] = 0;
        emit LogStakerWithdraw(staker, amount, block.timestamp);
        return true;
    }

    // withdraw candidate profit
    function withdrawMinerProfits(
        address candidate
    ) external onlyInitialized returns (bool) {
        require(candidates[candidate].createTime > 0, "Candidate not registered");
        address payable withdrawer = msg.sender;
        require(
            candidates[candidate].profitTaker == withdrawer,
            "Only specified profitTaker can withdraw minerminer profit"
        );
        
        _trySettleMinerProfit(candidate);
        uint256 amount = candidates[candidate].minerProfit;
        require(amount > 0, "No profit to withdraw");
        withdrawer.transfer(amount);
        candidates[candidate].minerProfit = 0;
        
        emit LogMinerWithdraw(candidate, withdrawer, amount,  block.timestamp);
        return true;
    }

    // get current validators
    function getValidators() external view returns (address[] memory) {
        return validators;
    }

    // get current top candidates
    function getTopCandidates() external view returns (address[] memory, uint256[] memory) {
        uint256[] memory powers = new uint256[](topCandidates.length);
        // if getTopCandidates returns 0, we should keep validators of last epoch
        for (uint256 i = 0; i < topCandidates.length; i++) {
            powers[i] = candidates[topCandidates[i]].stakePower;
        }
        return (topCandidates, powers);
    }

    // check if a candidate is a validator
    function isValidator(address candidate) public view returns (bool) {
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i] == candidate) {
                return true;
            }
        }
        return false;
    }

    // check if a candidate is in top list
    function isTopCandidate(address candidate) public view returns (bool) {
        for (uint256 i = 0; i < topCandidates.length; i++) {
            if (topCandidates[i] == candidate) {
                return true;
            }
        }
        return false;
    }
    
    // check if a candidate is jailed
    function isJailed(address candidate) public view returns (bool) {
        return candidates[candidate].jailed;
    }
    
    // update Validator set
    function updateValidatorSet(
        address[] memory newSet, 
        uint256 epoch
    ) external onlyInitialized onlyMiner onlyNotUpdated onlyBlockEpoch(epoch) {
        operationsDone[block.number][uint8(Operations.UpdateValidators)] = true;
        require(newSet.length > 0, "Validator set empty!");
        require(newSet.length <= MaxValidators, "Validator set too large!");
        validators = newSet;
        emit LogUpdateValidator(newSet);
    }    

    // calculate value chanege of staker's profit
    function _calcValueChange(uint256 stakerShare, uint256 totalPower, uint256 reward) internal pure returns (uint256) {
        return reward.mul(stakerShare).div(FullProfitShare).mul(ProfitValueScale).div(totalPower);
    }
    
    // distributeBlockReward distributes block reward to all active validators
    function distributeBlockReward() external payable onlyMiner onlyNotRewarded onlyInitialized {
        operationsDone[block.number][uint8(Operations.Distribute)] = true;
        address miner = msg.sender;
        
        uint256 fee = msg.value;                     // tx fees collected by this block
        uint256 blockReword = _currentBlockReward(); // new reward of this block

        candidates[miner].totalMined += blockReword;
        candidates[miner].totalFee += fee;
        uint256 totalProfit = fee + blockReword;
        
        if (candidates[miner].jailed) {
            uint256 totalShared = _addSharablePunishedProfit(totalProfit, miner);
            uint256 remain = totalProfit.div(totalShared);
            if (remain > 0) {
                candidates[miner].pendingProfit.add(remain);
            }
        } else {
            if (candidates[miner].stakerShare > 0 && candidates[miner].stakePower > 0) {
                // share profit with stakers by share rate
                uint256 stakerValue = _calcValueChange(candidates[miner].stakerShare, candidates[miner].stakePower, totalProfit);
                candidates[miner].profitValue += stakerValue;
                uint256 stakerProfit = stakerValue.mul(candidates[miner].stakePower).div(ProfitValueScale); // CHECK
                uint256 validatorProfit = totalProfit - stakerProfit;
                candidates[miner].pendingProfit += validatorProfit;
            } else {
                // do not share with stakers
                candidates[miner].pendingProfit += totalProfit;
            }
            _trySettleMinerProfit(miner);
        }

        emit LogDistributeBlockReward(miner, totalProfit, block.timestamp);
    }
    
    // punish a validator who failed to produce block
    function punish(address val) external onlyMiner onlyInitialized onlyNotPunished {
        punished[block.number] = true;
        candidates[val].missedBlocks += 1;
        if (candidates[val].punishedAtBlock > 0) {
            // adjust punish block by decrease record
            uint256 alreadyDecreased = (block.number - candidates[val].punishedAtBlock).div(PunishDecreaseInterval);
            if (candidates[val].missedBlocks > alreadyDecreased) {
                candidates[val].missedBlocks -= alreadyDecreased;
            } else {
                candidates[val].missedBlocks = 1;
            }
        }
        candidates[val].punishedAtBlock = block.number;
        if (candidates[val].missedBlocks % JailThreshold == 0) {
            // reach the jail threshold
            _removeValidatorProfit(val, msg.sender); 
            _tryJailValidator(val);
        } else if (
            // reach punish threshold
            candidates[val].missedBlocks % PunishThreshold == 0
        ) {
            _removeValidatorProfit(val, msg.sender);
        }
        emit LogPunishValidator(val, block.timestamp);
    }
    
    // remove a validators pending profit when get punished
    function _removeValidatorProfit(address val, address excutor) internal {
        if (candidates[val].pendingProfit > 0) {
            uint256 totalShared = _addSharablePunishedProfit(candidates[val].pendingProfit, val);
            // remained profit share is rewarded to the excutor
            candidates[excutor].pendingProfit += (candidates[val].pendingProfit - totalShared);
            candidates[val].pendingProfit = 0;
            candidates[val].pendingSettleBlock = block.number;
        }
    }

    // share punished validator's profit with all others
    function _addSharablePunishedProfit(uint256 profit, address except) internal returns(uint256) {
        uint256 shareCount = 0;
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i] == except || candidates[validators[i]].jailed) {
                continue;
            }
            shareCount.add(1);
        }
        uint256 totalShared = 0;
        if (shareCount > 0) {
            uint256 valShare = profit.div(shareCount);
            for (uint256 i = 0; i < validators.length; i++) {
                if (validators[i] == except || candidates[validators[i]].jailed) {
                    continue;
                }
                candidates[validators[i]].pendingProfit += valShare;
                totalShared += valShare;
            }
        }
        return totalShared;
    }

    // try put a validator into jail
    function _tryJailValidator(address candidate) internal {
        // already jailed
        if (candidates[candidate].jailed) {
            return;
        }
        // it's the last validator, cannot jail it
        if (validators.length == 1 && validators[0] == candidate) {
            return;
        }
        // remove from validator list
        for (uint256 i = 0; i < validators.length; i++) {
            if (validators[i] == candidate) {
                // swap last item with current
                validators[i] = validators[validators.length - 1];    
                validators.pop();
                break;
            }
        }
        // remove from top candidates list
        for (uint256 i = 0; i < topCandidates.length; i++) {
            if (topCandidates[i] == candidate) {
                topCandidates[i] = topCandidates[topCandidates.length - 1];
                topCandidates.pop();
                break;
            }
        }
        candidates[candidate].jailed = true;
        emit LogJailValidator(candidate, block.timestamp);
    }
}
