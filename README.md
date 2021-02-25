# PHB-Staking

phb staking:
1. 构造函数参数需要以下3个：
 	合约owner的地址
 	phb token地址
 	phb token地址
 	
 2. 部署合约以后需要使用owner设置增发的速率 ：
     function setInflationSpeed(uint256 speed) external;
     每秒的token数量， 如1 phb/秒 则设置 1000000000000000000(1e18)
     
 3. staking:
     function stake(uint256 amount) external;
     
 4. 可解除质押的数量
     function withdrawableAmount(address account)external view returns(uint256);

5. 提取质押
    function withdraw(uint256 amount) external;

以上3，4，5逻辑和hzn staking合约相同

6. 取得的reward数量
    function getUserRewards(address account) external view returns(uint256);
    如果该用户的质押总量小于最低等级100000 则无奖励    
 	
7. 提取reward
    function claimReward() external;
    这步操作是从rewardProvider的账户中transferFrom用户的奖励Phb,所以需要rewardProvider将每期的inflation数量增量的approve给合约（当前的allownace + 本期应增发数量）。	
