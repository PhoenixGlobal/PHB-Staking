# PHB-Staking

## 1. 构造函数参数需要以下3个：

    合约owner的地址
    phb token地址
    phb token地址

 ## 2. 部署合约以后需要使用owner设置增发的速率 ：
```
 function setInflationSpeed(uint256 speed) external;
 //每秒的token数量， 如1 phb/秒 则设置 1000000000000000000(1e18)
```

 ## 3. staking:
```
 function stake(uint256 amount) external;
```

 ## 4. 可解除质押的数量
     function withdrawableAmount(address account)external view returns(uint256);

## 5. 提取质押
    function applyWithdraw(uint256 amount) external nonReentrant; //先申请提取
    function withdraw(uint256 amount) external; //申请后超过锁定时间可以提取

以上3，4，5逻辑和hzn staking合约相同

## 6. 取得的reward数量
    function getUserRewards(address account) external view returns(uint256);
    //如果该用户的质押总量小于最低等级100000 则无奖励    

## 7. 提取reward
    function claimReward() external;
    //这步操作是从rewardProvider的账户中transferFrom用户的奖励Phb,所以需要rewardProvider将每期的inflation数量增量的approve给合约（当前的allownace + 本期应增发数量）。	

## 8. this staking contract reward calculation is based Compound algorithm
    we maintains 2 (kinds) index:
    globalIndex: means how many rewards per staking token,has 2 fields: index and last updated timestamp
    userIndex: user share from the total staking
    every time the total staking amount changed ,user claimed rewards and inflation speed changed, we need to update the globalIndex
    initial status: we ignore the decimals of tokens 
    globalindex = 1, total staking = 0, speed = 0, we do the operation every 10 seconds
    
    1) admin set speed to 100 (100 phb per seconds), since still now staking, we only update the globalindex timestamp to now.
    2) user A stakes 10000 phb, previous total staking  = 0, globalindex = 1, previous balance(A) = 0,distributed reward = 0, then set user A's index = 1
    3) user B stakes 10000 phb, previous total staking = 10000 , globalindex = 1 + delta(time) * speed/ 10000 = 1.1, set user B's index = 1 ,previous balance(b) = 0,distributed reward = 0, then set user B's index = 1.1
    4) query/claim user A's reward now(also 10 seconds past) ,the new globalindex = 1.1 + 10 * 100/20000 = 1.15
        (if for the getUserReward function, the globalindex is not saved to storage since it's a 'view' function)   
        so the rewards is delta(index) * balance(A) = (1.15-1)*10000 = 1500 phb    
    5) at the same time user B's reward is delta(index) * balance(B) = (1.15-1.1) * 10000 = 500 phb
    now let's check the result(***NOTE since no one staked in the 1st 10 seconds, so the 1st 1000 phb is wasted!!!!!)


| time | total reward | user A staking | user B staking | user A reward | user B reward | gIdex | AIdx | BIdx|
|:----:|:----:| :----: |:----: | :----: | :----: |:----: | :----: | :----: |
| 0 | 0 | 0 |0 | 0 | 0 |1 | 0 | 0 |
| 10 | 1000 | 10000 |0 | 0 | 0 |1 | 1 | 0 |
| 20 | 2000 | 10000 |10000 | 1000 | 0 |1.1 | 1 | 1.1 |
| 30 | 3000 | 10000 |10000 | 500 | 500 |1.15 | 1 | 1.1 |
| 40 | 4000 | 10000 |10000 | 500 | 500 |1.2 | 1 | 1.1 |
| 500 | 6000 | 10000 |10000 | 1000 | 1000 |1.3 | 1 | 1.1 |


    for refresh speed is the same
    6) admin change speed to 200, then global index = 1.1(assume step 5 is query operation, didn't change the storage) + delta(time) * oldspeed / 20000 = 1.1+20 *100/20000 = 1.2
    7) user A query reward: current global index = 1.2+ delta(time) * newspeed / 20000 = 1.2 + 10 * 200/20000 = 1.3, so the reward should be (1.3 - 1)* 10000 = 3000
    user B query reward: so the reward should be (1.3 - 1.1)* 10000 = 2000