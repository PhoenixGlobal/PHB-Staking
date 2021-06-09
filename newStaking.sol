pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "openzeppelin-solidity/contracts/math/Math.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";

import "./Pausable.sol";

contract PhbStaking is ReentrancyGuard, Pausable {

    /// @notice Emitted when setLevel
    event SetLevel(string name,uint256 min , uint256 max, uint256 weight);

    /// @notice Emitted when staking
    event Staked(address indexed user, uint256 amount);

    /// @notice Emitted when claiming
    event Claimed(address indexed user, uint256 amount);

    /// @notice Emitted when withdrawing
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when set lockdown duration
    event LockDownDurationUpdated(uint256 newLockDownDuration);

    /// @notice Emitted when set inflation speed
    event InflationSpeedUpdated(uint256 newSpeed);

    /// @notice Emitted when apply withdraw
    event ApplyWithdraw(address indexed user,uint256 amount, uint256 time);

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    uint256 public lockDownDuration = 5 seconds;
    uint256 public totalStakes ;
    
    uint256 public virtualTotalStakes;

    uint constant doubleScale = 1e36;

    // uint256 RateScale = 10000;
    uint256 phbDecimals = 1e18;
    uint256 WeightScale = 100;
    address public rewardProvider =0x26356Cb66F8fd62c03F569EC3691B6F00173EB02;

    //withdraw rate 5 for 0.05% 
    uint256 public withdrawRate = 0;
    uint256 public feeScale = 10000;

    //NOTE:modify me before mainnet
    address public feeCollector =0x26356Cb66F8fd62c03F569EC3691B6F00173EB02;

    /// @notice The initial global index
    uint256 public constant globalInitialIndex = 1e36;

    uint256 public inflationSpeed = 0;

    struct Double {
        uint mantissa;
    }
    
    string [] levels = ["Carbon","Genesis","Platinum","Zironium","Diamond"];


    struct RateLevel {
        uint256 min;
        uint256 max;
        uint256 weight;
    }

    mapping(string => RateLevel) _ratesLevel;
    mapping(string => uint256) levelAmount;

    mapping(address=>uint256) virtualUserbalance;

    struct withdrawApplication {
        uint256 amount;
        uint256 applyTime;
    }

    mapping(address => uint256) _userRewards;

    //this record the user withdraw application
    //according to the requirement, when user want to withdraw his staking phb, he needs to 
    //1. call applyWithdraw , this will add a lock period (7 days by default, can be changed by admin) 
    //2. call withdraw to withdraw the "withdrawable amounts"
    struct TimedWithdraw {
        uint256 totalApplied;                      //total user applied for withdraw
        mapping(uint256 => uint256) applications;  //apply detail time=>amount
        uint256[] applyTimes;                      //apply timestamp, used for the key of applications mapping
    }

    mapping(address => TimedWithdraw) timeApplyInfo;   //user => TimedWithdraw mapping
    mapping(address => uint256) _balances;

    struct Index {
        uint256 index;
        uint256 lastTime;
    }

    Index globalIndex;
    mapping(address => Index) userIndex;

    /* ========== CONSTRUCTOR ========== */
    constructor(
                address _owner,
                address _rewardsToken,
                address _stakingToken
    ) public Owned(_owner){
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        initLevel();
        globalIndex.index = globalInitialIndex;
        globalIndex.lastTime = now;
    }


    /* ========== internals ======== */
    function initLevel() internal {
        _ratesLevel[levels[0]] = RateLevel({min:100000,max:500000,weight:100});
        _ratesLevel[levels[1]] = RateLevel({min:500000,max:1000000,weight:250});
        _ratesLevel[levels[2]] = RateLevel({min:1000000,max:5000000,weight:400});
        _ratesLevel[levels[3]] = RateLevel({min:5000000,max:10000000,weight:600});
        _ratesLevel[levels[4]] = RateLevel({min:10000000,max:1000000000000,weight:800});

    }


    /* =========== views ==========*/

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    //to calculate the rewards by the gap of userindex and globalindx
    function getUserRewards(address account) public view returns(uint256){
        // updateGlobalIndex();
        uint256 rewardSpeed = inflationSpeed;
        uint256 deltaTime = now.sub(globalIndex.lastTime);

        uint256 rewardAccued = deltaTime.mul(rewardSpeed);
        // Double memory ratio = totalStakes > 0 ? fraction(rewardAccued,totalStakes):Double({mantissa:0});
        Double memory ratio = virtualTotalStakes > 0 ? fraction(rewardAccued,virtualTotalStakes):Double({mantissa:0});

        Double memory gIndex = add_(Double({mantissa: globalIndex.index}), ratio);

        Double memory uIndex = Double({mantissa:userIndex[account].index});

        if (uIndex.mantissa == 0 && gIndex.mantissa > 0) {
            uIndex.mantissa = globalInitialIndex;
        }

        Double memory deltaIndex = sub_(gIndex,uIndex);
      
        uint256 supplierDelta = mul_(virtualUserbalance[account],deltaIndex);

        return supplierDelta.add(_userRewards[account] );
    }

    //calculate the total amount which apply time already passed [7 days]
    function withdrawableAmount(address account)public view returns(uint256){
        uint256 amount = 0;
        TimedWithdraw storage withdrawApplies = timeApplyInfo[account];
        
        for (uint8 index = 0; index < withdrawApplies.applyTimes.length; index++) {
            uint256 key = withdrawApplies.applyTimes[index];
            if (now.sub(key) > lockDownDuration){
                amount = amount.add(withdrawApplies.applications[key]);
            }
        }
        return amount;
    }

    //for front end display, the following two method should be used together
    //
    //we return total applied, applied times and applied amounts here
    function getUserApplication(address account) external view returns(uint256, uint256[] memory, uint256[] memory){
        uint256[] memory applyTimes = timeApplyInfo[account].applyTimes;
        uint256[] memory applyAmounts = new uint256[](applyTimes.length);
        for (uint8 index = 0 ;index < applyTimes.length; index++){
            applyAmounts[index] = timeApplyInfo[account].applications[applyTimes[index]];
        }
        
        return (timeApplyInfo[account].totalApplied, applyTimes, applyAmounts);
    }

    //return levels config in contract
    function getLevelInfos() external view returns(string[] memory){
        return levels;
    }

    //return level detail,key is result of previous function
    function getLevelDetail(string calldata lv) external view returns(RateLevel memory){
        return _ratesLevel[lv];
    }

    //return the total staked amount for the given level
    function getLevelStakes(string calldata lv) external view returns(uint256){
        return levelAmount[lv];
    }


    /* ========== MUTATIVE FUNCTIONS ========== */
    function setLevel( string calldata lv,uint256 min,uint256 max,uint256 weight) external onlyOwner{
        _ratesLevel[lv] = RateLevel({min:min,max:max,weight:weight});
        emit SetLevel(lv,min,max,weight);
    }

    function stake(uint256 amount) external nonReentrant notPaused returns (bool){
        require(amount > 0, "Cannot stake 0");

        updateGlobalIndex();
        distributeReward(msg.sender);

        //we calculate the "vamount" first here
        updateVAmounts(msg.sender,amount,true);


        totalStakes = totalStakes.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 rewards = _userRewards[msg.sender];
        if (rewards > 0){
            require(rewardsToken.transferFrom(rewardProvider, msg.sender, rewards),"claim rewards failed");
            delete(_userRewards[msg.sender]);
            emit Claimed(msg.sender,rewards);
        }

        emit Staked(msg.sender,amount);
    }

    //add user withdraw application
    function applyWithdraw(uint256 amount) external nonReentrant{
        require(amount > 0, "Cannot withdraw 0");

        TimedWithdraw storage withdrawApplies = timeApplyInfo[msg.sender];
        //should have enough un-applied balance
        require(amount <= _balances[msg.sender], "exceeded user balance!");

        withdrawApplies.totalApplied = withdrawApplies.totalApplied.add(amount);
        withdrawApplies.applications[now] = amount;
        withdrawApplies.applyTimes.push(now);

        timeApplyInfo[msg.sender] = withdrawApplies;

        updateGlobalIndex();
        distributeReward(msg.sender);

        updateVAmounts(msg.sender,amount,false);

        totalStakes = totalStakes.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);

        uint256 rewards = _userRewards[msg.sender];
        if (rewards > 0){
            require(rewardsToken.transferFrom(rewardProvider, msg.sender, rewards),"claim rewards failed");
            delete(_userRewards[msg.sender]);
            emit Claimed(msg.sender,rewards);
        }

        emit ApplyWithdraw(msg.sender,amount,now);
    }

    //withdraw staked amount if possible
    function withdraw(uint256 amount) public nonReentrant {
        require(amount > 0, "Cannot withdraw 0");
        require(withdrawableAmount(msg.sender) >= amount,"not enough withdrawable balance");
        dealwithLockdown(amount,msg.sender);
        uint256 fee = amount.mul(withdrawRate).div(feeScale);
        stakingToken.safeTransfer(msg.sender, amount.sub(fee));
        if (fee > 0 ){
            stakingToken.safeTransfer(feeCollector, fee);
        }

        emit Withdrawn(msg.sender, amount.sub(fee));
    }

    function setLockDownDuration(uint256 _lockdownDuration) external onlyOwner {
        lockDownDuration = _lockdownDuration;
        emit LockDownDurationUpdated(_lockdownDuration);
    }

    function setWithdrawRate(uint256 _rate) external onlyOwner {
        require(_rate < 10000,"withdraw rate is too high");
        withdrawRate = _rate;
    }

    function setFeeCollector(address _feeCollector) external onlyOwner{
        feeCollector = _feeCollector;
    }

    function setRewardProvider(address _rewardProvider) external onlyOwner{
        rewardProvider = _rewardProvider;
    }

    function claimReward() external nonReentrant notPaused returns (bool) {
        updateGlobalIndex();
        distributeReward(msg.sender);
        uint256 rewards = _userRewards[msg.sender];
        require( rewards > 0,"no rewards for this account");
        require(rewardsToken.transferFrom(rewardProvider, msg.sender, rewards),"claim rewards failed");
        delete(_userRewards[msg.sender]);
        
        emit Claimed(msg.sender,rewards);
    }

    //calculate tokens per seconds

    function setInflationSpeed(uint256 speed) public onlyOwner {
        updateGlobalIndex();
        inflationSpeed = speed;
        emit InflationSpeedUpdated(speed);
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    function updateGlobalIndex() internal {
        uint256 rewardSpeed = inflationSpeed;
        uint256 deltaTime = now.sub(globalIndex.lastTime);

        if (deltaTime > 0 && rewardSpeed > 0) {
            uint256 rewardAccued = deltaTime.mul(rewardSpeed);
            // Double memory ratio = totalStakes > 0 ? fraction(rewardAccued,totalStakes):Double({mantissa:0});
            Double memory ratio = virtualTotalStakes > 0 ? fraction(rewardAccued,virtualTotalStakes):Double({mantissa:0});

            Double memory newIndex = add_(Double({mantissa: globalIndex.index}), ratio);
            globalIndex.index = newIndex.mantissa;
            globalIndex.lastTime = now;
        }else if(deltaTime > 0) {
            globalIndex.lastTime = now;
        }
    }

    function distributeReward(address account) internal {
        Double memory gIndex = Double({mantissa:globalIndex.index});
        Double memory uIndex = Double({mantissa:userIndex[account].index});

        userIndex[account].index = globalIndex.index;

        if (uIndex.mantissa == 0 && gIndex.mantissa > 0) {
            uIndex.mantissa = globalInitialIndex;
        }

        Double memory deltaIndex = sub_(gIndex,uIndex);
        // uint256 supplierDelta = mul_(_balances[account],deltaIndex);
        uint256 supplierDelta = mul_(virtualUserbalance[account],deltaIndex);

        // string memory lv = getBalanceLevel(_balances[account]);
        // uint weight = bytes(lv).length==0 ?0:_ratesLevel[lv].weight;
        // supplierDelta =  supplierDelta.mul(weight).div(WeightScale);
        _userRewards[account] = supplierDelta.add(_userRewards[account] );
    }


    function remove(uint256[] storage array, uint index) internal returns(uint256[] storage) {
        if (index >= array.length) return array;

        if(array.length == 1){
            delete(array[index]);
            return array;
        }        
        for (uint i = index; i<array.length-1; i++){
            array[i] = array[i+1];
        }
        array.length--;
        return array;
    }

    function dealwithLockdown(uint256 amount, address account) internal {
        uint256 _total = amount;
        TimedWithdraw storage withdrawApplies = timeApplyInfo[account];
        //applyTimesLen cannot be change
        uint256 applyTimesLen = withdrawApplies.applyTimes.length;
         for (uint8 index = 0; index < applyTimesLen; index++) {
           if (_total > 0){
              uint256 key = withdrawApplies.applyTimes[0];
              if (now.sub(key) > lockDownDuration){
                  if(_total >= withdrawApplies.applications[key]){
                      _total = _total.sub(withdrawApplies.applications[key]);
                      delete( withdrawApplies.applications[key]);
                      remove(withdrawApplies.applyTimes, 0);
                    //   delete( withdrawApplies.applyTimes[index]);
                  }else{
                      withdrawApplies.applications[key] = withdrawApplies.applications[key].sub(_total);
                      _total = 0;
                      break;
                  }
              }
           }
        }

        withdrawApplies.totalApplied  = withdrawApplies.totalApplied.sub(amount);
    }

    function getBalanceLevel(uint256 balance) view internal returns(string memory){
        for (uint8 index = 0 ;index < levels.length; index++){
            RateLevel memory tmp = _ratesLevel[levels[index]];
            if (balance >= tmp.min.mul(phbDecimals) && balance < tmp.max.mul(phbDecimals)){
                return levels[index];
            }
        }
        return "";
    }

    //optimise the stake weight based reward calculation
    //"virtualbalance" is record user real balance * level weight
    //if user total staked 100k, virtualbalance is 100k * 100% = 100k
    //if user total staked 1M virtualbalance si 1M * 250% = 2.5M
    //the staking reward is calculated based on this virtualbalance
    function updateVAmounts(address userAcct,uint256 amount,bool increase) internal {
        uint256 balanceBefore = _balances[userAcct];
        string memory lvBefore = getBalanceLevel(balanceBefore);
        uint weightBefore = bytes(lvBefore).length==0 ? 0 : _ratesLevel[lvBefore].weight;
        uint256 balanceAfter = increase ? balanceBefore.add(amount) : balanceBefore.sub(amount);

        string memory lvAfter = getBalanceLevel(balanceAfter);
        uint weightAfter = bytes(lvAfter).length==0 ?0:_ratesLevel[lvAfter].weight;

        //update vbalance
        uint256 vbalanceBefore =  virtualUserbalance[userAcct] ;
        virtualUserbalance[userAcct] = balanceAfter.mul(weightAfter).div(WeightScale);

        //update vtotalstake
        virtualTotalStakes = virtualTotalStakes.sub(vbalanceBefore).add( virtualUserbalance[userAcct]);

        if (weightBefore == weightAfter){
            //update amount to lv
            levelAmount[lvBefore] = levelAmount[lvBefore].sub(balanceBefore).add(balanceAfter);
        }else{
            levelAmount[lvBefore] = levelAmount[lvBefore].sub(balanceBefore);
            levelAmount[lvAfter] = levelAmount[lvAfter].add(balanceAfter);
        }

    }

    /*========Double============*/
    function fraction(uint a, uint b) pure internal returns (Double memory) {
        return Double({mantissa: div_(mul_(a, doubleScale), b)});
    }

    function add_(Double memory a, Double memory b) pure internal returns (Double memory) {
        return Double({mantissa: add_(a.mantissa, b.mantissa)});
    }

    function add_(uint a, uint b) pure internal returns (uint) {
        return add_(a, b, "addition overflow");
    }

    function add_(uint a, uint b, string memory errorMessage) pure internal returns (uint) {
        uint c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub_(Double memory a, Double memory b) pure internal returns (Double memory) {
        return Double({mantissa: sub_(a.mantissa, b.mantissa)});
    }

    function sub_(uint a, uint b) pure internal returns (uint) {
        return sub_(a, b, "subtraction underflow");
    }

    function sub_(uint a, uint b, string memory errorMessage) pure internal returns (uint) {
        require(b <= a, errorMessage);
        return a - b;
    }


    function mul_(Double memory a, Double memory b) pure internal returns (Double memory) {
        return Double({mantissa: mul_(a.mantissa, b.mantissa) / doubleScale});
    }
   function mul_(Double memory a, uint b) pure internal returns (Double memory) {
        return Double({mantissa: mul_(a.mantissa, b)});
    }

    function mul_(uint a, Double memory b) pure internal returns (uint) {
        return mul_(a, b.mantissa) / doubleScale;
    }

    function mul_(uint a, uint b) pure internal returns (uint) {
        return mul_(a, b, "multiplication overflow");
    }

    function mul_(uint a, uint b, string memory errorMessage) pure internal returns (uint) {
        if (a == 0 || b == 0) {
            return 0;
        }
        uint c = a * b;
        require(c / a == b, errorMessage);
        return c;
    }
    function div_(Double memory a, Double memory b) pure internal returns (Double memory) {
        return Double({mantissa: div_(mul_(a.mantissa, doubleScale), b.mantissa)});
    }
    function div_(Double memory a, uint b) pure internal returns (Double memory) {
        return Double({mantissa: div_(a.mantissa, b)});
    }

    function div_(uint a, Double memory b) pure internal returns (uint) {
        return div_(mul_(a, doubleScale), b.mantissa);
    }

    function div_(uint a, uint b) pure internal returns (uint) {
        return div_(a, b, "divide by zero");
    }

    function div_(uint a, uint b, string memory errorMessage) pure internal returns (uint) {
        require(b > 0, errorMessage);
        return a / b;
    }


}