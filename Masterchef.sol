// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/ICougarReferral.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./CougarToken.sol";

// Masterchef is the master of Cougar. He can make Cougar and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once TEST is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract Masterchef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of COUGARs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCougarPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCougarPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. COUGARs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that COUGARs distribution occurs.
        uint256 accCougarPerShare;   // Accumulated COUGARs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The COUGAR TOKEN!
    CougarToken public cougar;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // COUGAR tokens created per block.
    uint256 public cougarPerBlock;
    // Bonus muliplier for early cougar makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Max deposit fee: 3%.
    uint16 public constant MAXIMUM_DEPOSIT_FEE = 400;
    // Burn address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when COUGAR mining starts.
    uint256 public startBlock;

    // Cougar referral contract address.
    ICougarReferral public cougarReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 200;
    // Max referral commission rate: 3%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 300;
    // Max Cougar Supply
    uint256 public CougarMaxSupply = 200000000e18;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor(
        CougarToken _cougar,
        uint256 _startBlock,
        uint256 _cougarPerBlock
    ) public {
        cougar = _cougar;
        startBlock = _startBlock;
        cougarPerBlock = _cougarPerBlock;

        devAddress = msg.sender;
        feeAddress = msg.sender;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function currentBlock() external view returns (uint256) {
        return block.number;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accCougarPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's COUGAR allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= MAXIMUM_DEPOSIT_FEE, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (IBEP20(cougar).totalSupply() >= CougarMaxSupply) {return 0;}
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending COUGARs on frontend.
    function pendingCougar(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCougarPerShare = pool.accCougarPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 cougarReward = multiplier.mul(cougarPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accCougarPerShare = accCougarPerShare.add(cougarReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accCougarPerShare).div(1e12).sub(user.rewardDebt);
        return pending;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 cougarReward = multiplier.mul(cougarPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        cougar.mint(devAddress, cougarReward.div(20));
        cougar.mint(address(this), cougarReward);
        pool.accCougarPerShare = pool.accCougarPerShare.add(cougarReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to Masterchef for COUGAR allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (_amount > 0 && address(cougarReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            cougarReferral.recordReferral(msg.sender, _referrer);
        }

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accCougarPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeCougarTransfer(msg.sender, pending);
                payReferralCommission(msg.sender, pending);
            }
        }

        if (_amount > 0) {
            uint256 beforeDeposit = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
            uint256 afterDeposit = pool.lpToken.balanceOf(address(this));
            _amount = afterDeposit.sub(beforeDeposit); // real amount of LP transfer to this address

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(1e4);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accCougarPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    
    // Safe cougar transfer function, just in case if rounding error causes pool to not have enough COUGARs.
    function safeCougarTransfer(address _to, uint256 _amount) internal {
        uint256 cougarBal = cougar.balanceOf(address(this));
        if (_amount > cougarBal) {
            cougar.transfer(_to, cougarBal);
        } else {
            cougar.transfer(_to, _amount);
        }
    }
    
    // Withdraw LP tokens from Masterchef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accCougarPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeCougarTransfer(msg.sender, pending);
            payReferralCommission(msg.sender, pending);
        }

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accCougarPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
    }
    
    // Update Fee Address
    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
    }

    // Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _cougarPerBlock) public onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, cougarPerBlock, _cougarPerBlock);
        cougarPerBlock = _cougarPerBlock;
    }

    // Update the cougar referral contract address by the owner
    function setCougarReferral(ICougarReferral _cougarReferral) public onlyOwner {
        cougarReferral = _cougarReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(cougarReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = cougarReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(1e4);

            if (referrer != address(0) && commissionAmount > 0) {
                cougar.mint(referrer, commissionAmount);
                cougarReferral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Only update before start of farm
    function updateStartBlock(uint256 _startBlock) external onlyOwner {
	    require(startBlock > block.number, "Farm already started");
        startBlock = _startBlock;
        
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardBlock = startBlock;
        }
    }
}
