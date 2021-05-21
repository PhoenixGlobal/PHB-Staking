pragma solidity >=0.4.24;

// https://docs.synthetix.io/contracts/source/interfaces/istakingrewards
interface IPhbStaking {
    // Views
    function getUserRewards(address account) external view returns(uint256);
    function withdrawableAmount(address account)external view returns(uint256);
    function totalStakes() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getBalanceLevel(address account) view external returns(string memory);
    function getLevels(string calldata level) view external returns(uint256, uint256, uint256);

    // Mutative

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function claimReward() external;

    function setInflationSpeed(uint256 speed) external;
    function setLevel( string calldata lv,uint256 min,uint256 max,uint256 weight) external ;
    function setLockDownDuration(uint256 _lockdownDuration) external ;
    function setRewardProvider(address _rewardProvider) external ;


}
