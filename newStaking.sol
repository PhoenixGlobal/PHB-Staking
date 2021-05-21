pragma solidity ^0.5.16;

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

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public rewardsToken;
    IERC20 public stakingToken;

    uint256 public lockDownDuration = 5 seconds;
    uint256 public totalStakes ;

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

    struct userStaking {
        uint256 amount;
        uint256 stakingTime;
    }

    mapping(address => uint256) _userRewards;

    struct TimedStake {
      mapping(uint256 => uint256) stakes;
      uint256[] stakeTimes;
    }

    mapping(address => TimedStake) timeStakeInfo;
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
        _ratesLevel[levels[0]] = RateLevel({min:100000,max:499999,weight:100});
        _ratesLevel[levels[1]] = RateLevel({min:500000,max:999999,weight:250});
        _ratesLevel[levels[2]] = RateLevel({min:1000000,max:4999999,weight:400});
        _ratesLevel[levels[3]] = RateLevel({min:5000000,max:9999999,weight:600});
        _ratesLevel[levels[4]] = RateLevel({min:10000000,max:999999999999,weight:1100});
    }


    /* =========== views ==========*/

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function getUserRewards(address account) public view returns(uint256){
        // updateGlobalIndex();
        uint256 rewardSpeed = inflationSpeed;
        uint256 deltaTime = now.sub(globalIndex.lastTime);

        uint256 rewardAccued = deltaTime.mul(rewardSpeed);
        Double memory ratio = totalStakes > 0 ? fraction(rewardAccued,totalStakes):Double({mantissa:0});
        Double memory gIndex = add_(Double({mantissa: globalIndex.index}), ratio);

        Double memory uIndex = Double({mantissa:userIndex[account].index});

        if (uIndex.mantissa == 0 && gIndex.mantissa > 0) {
            uIndex.mantissa = globalInitialIndex;
        }

        Double memory deltaIndex = sub_(gIndex,uIndex);
        uint256 supplierDelta = mul_(_balances[account],deltaIndex);

        string memory lv = getBalanceLevel(account);
        uint weight = bytes(lv).length==0 ?0:_ratesLevel[lv].weight;
        supplierDelta =  supplierDelta.mul(weight).div(WeightScale);

        return supplierDelta.add(_userRewards[account] );
    }

    function withdrawableAmount(address account)public view returns(uint256){
        uint256 amount = 0;
        TimedStake storage _timedStake = timeStakeInfo[account];
        
        for (uint8 index = 0; index < _timedStake.stakeTimes.length; index++) {
            uint256 key = _timedStake.stakeTimes[index];
            if (now.sub(key) > lockDownDuration){
                amount = amount.add(_timedStake.stakes[key]);
            }
        }
        return amount;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function setLevel( string calldata lv,uint256 min,uint256 max,uint256 weight) external onlyOwner{
        _ratesLevel[lv] = RateLevel({min:min,max:max,weight:weight});
        emit SetLevel(lv,min,max,weight);
    }

    function stake(uint256 amount) external nonReentrant notPaused returns (bool){
        require(amount > 0, "Cannot stake 0");
        totalStakes = totalStakes.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        TimedStake storage _timedStake = timeStakeInfo[msg.sender];
        _timedStake.stakes[now] = amount;
        _timedStake.stakeTimes.push(now);
        timeStakeInfo[msg.sender] = _timedStake;

        updateGlobalIndex();
        distributeReward(msg.sender);

        emit Staked(msg.sender,amount);
    }
   
    function withdraw(uint256 amount) public nonReentrant {
        require(amount > 0, "Cannot withdraw 0");
        totalStakes = totalStakes.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);

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
        inflationSpeed = speed;
        emit InflationSpeedUpdated(speed);
    }

    /* ========== INTERNAL FUNCTIONS ========== */
    function updateGlobalIndex() internal {
        uint256 rewardSpeed = inflationSpeed;
        uint256 deltaTime = now.sub(globalIndex.lastTime);

        if (deltaTime > 0 && rewardSpeed > 0) {
            uint256 rewardAccued = deltaTime.mul(rewardSpeed);
            Double memory ratio = totalStakes > 0 ? fraction(rewardAccued,totalStakes):Double({mantissa:0});
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
        uint256 supplierDelta = mul_(_balances[account],deltaIndex);

        string memory lv = getBalanceLevel(account);
        uint weight = bytes(lv).length==0 ?0:_ratesLevel[lv].weight;
        supplierDelta =  supplierDelta.mul(weight).div(WeightScale);
        _userRewards[account] = supplierDelta.add(_userRewards[account] );
    }


    function dealwithLockdown(uint256 amount,address account) internal {
        uint256 _total = amount;
        TimedStake storage _timedStake = timeStakeInfo[account];
         for (uint8 index = 0; index < _timedStake.stakeTimes.length; index++) {
           if (_total > 0){
              uint256 key = _timedStake.stakeTimes[index];
              if (now.sub(key) > lockDownDuration){
                  if(_total >= _timedStake.stakes[key]){
                      _total = _total.sub(_timedStake.stakes[key]);
                      delete( _timedStake.stakes[key]);
                      delete( _timedStake.stakeTimes[index]);
                  }else{
                      _timedStake.stakes[key] = _timedStake.stakes[key].sub(_total);
                      _total = 0;
                      break;
                  }
              }
           }
        }
    }

    function getBalanceLevel(address account) view public returns(string memory){
        uint256 balance = _balances[account];
        for (uint8 index = 0 ;index < levels.length; index++){
            RateLevel memory tmp = _ratesLevel[levels[index]];
            if (balance >= tmp.min.mul(phbDecimals) && balance <= tmp.max.mul(phbDecimals)){
                return levels[index];
            }
        }
        return "";
    }

    function getLevels(string memory level) view public returns(uint256, uint256, uint256){
        uint256 min = _ratesLevel[level].min;
        uint256 max = _ratesLevel[level].max;
        uint256 weight = _ratesLevel[level].weight;
        return (min, max, weight);
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
