// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract RCCStake is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    // ************************************** 自定义错误 **************************************

    error WithdrawPaused();
    error ClaimPaused();
    error InvalidParameters();
    error WithdrawAlreadyPaused();
    error WithdrawNotPaused();
    error ClaimAlreadyPaused();
    error ClaimNotPaused();
    error StartBlockMustBeSmallerThanEndBlock();
    error InvalidStakingTokenAddress();
    error InvalidWithdrawLockedBlocks();
    error AlreadyEnded();
    error InvalidPoolWeight();
    error InvalidBlockRange();
    error EndBlockMustBeGreaterThanStartBlock();
    error MultiplierOverflow();
    error NotEnoughStakingTokenBalance();
    error UserStAmountMulAccRCCPerSTOverflow();
    error AccSTDiv1EtherOverflow();
    error AccSTSubFinishedRCCOverflow();
    error UserPendingRCCOverflow();
    error UserStAmountOverflow();
    error PoolStTokenAmountOverflow();
    error FinishedRCCDiv1EtherOverflow();
    error NativeCurrencyTransferFailed();
    error NativeCurrencyTransferOperationDidNotSucceed();
    error InvalidPid();

    // ************************************** 不变量 **************************************

    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");

    uint256 public constant nativeCurrency_PID = 0;

    // ************************************** 数据结构 **************************************
    /*
    基本上，在任何时间点，一个用户有权获得但尚未分发的 RCC 数量为：

    pending RCC = (user.stAmount * pool.accRCCPerST) - user.finishedRCC

    每当用户向池中存入或取出质押代币时，会发生以下情况：
    1. 池的 `accRCCPerST`（和 `lastRewardBlock`）会更新。
    2. 用户收到发送到其地址的待分发 RCC。
    3. 用户的 `stAmount` 会更新。
    4. 用户的 `finishedRCC` 会更新。
    */
    struct Pool {
        // 质押代币地址
        address stTokenAddress;
        // 池的权重
        uint256 poolWeight;
        // 上一次 RCC 分发的区块号
        uint256 lastRewardBlock;
        // 每个质押代币的累计 RCC
        uint256 accRCCPerST;
        // 质押代币数量
        uint256 stTokenAmount;
        // 最小质押金额
        uint256 minDepositAmount;
        // 取款锁定区块数
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        // 请求取款金额
        uint256 amount;
        // 请求取款金额可释放的区块号
        uint256 unlockBlocks;
    }

    struct User {
        // 用户质押的代币数量
        uint256 stAmount;
        // 已分发给用户的 RCC
        uint256 finishedRCC;
        // 待领取的 RCC
        uint256 pendingRCC;
        // 取款请求列表
        UnstakeRequest[] requests;
    }

    // ************************************** 状态变量 **************************************
    // RCCStake 开始的第一个区块
    uint256 public startBlock;
    // RCCStake 结束的第一个区块
    uint256 public endBlock;
    // 每区块的 RCC 奖励
    uint256 public RCCPerBlock;

    // 暂停取款功能
    bool public withdrawPaused;
    // 暂停领取功能
    bool public claimPaused;

    // RCC 代币
    IERC20 public RCC;

    // 总池权重 / 所有池权重之和
    uint256 public totalPoolWeight;
    Pool[] public pool;

    // 池 ID => 用户地址 => 用户信息
    mapping (uint256 => mapping (address => User)) public user;

    // ************************************** 事件 **************************************

    event SetRCC(IERC20 indexed RCC);

    event PauseWithdraw();

    event UnpauseWithdraw();

    event PauseClaim();

    event UnpauseClaim();

    event SetStartBlock(uint256 indexed startBlock);

    event SetEndBlock(uint256 indexed endBlock);

    event SetRCCPerBlock(uint256 indexed RCCPerBlock);

    event AddPool(address indexed stTokenAddress, uint256 indexed poolWeight, uint256 indexed lastRewardBlock, uint256 minDepositAmount, uint256 unstakeLockedBlocks);

    event UpdatePoolInfo(uint256 indexed poolId, uint256 indexed minDepositAmount, uint256 indexed unstakeLockedBlocks);

    event SetPoolWeight(uint256 indexed poolId, uint256 indexed poolWeight, uint256 totalPoolWeight);

    event UpdatePool(uint256 indexed poolId, uint256 indexed lastRewardBlock, uint256 totalRCC);

    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);

    event RequestUnstake(address indexed user, uint256 indexed poolId, uint256 amount);

    event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount, uint256 indexed blockNumber);

    event Claim(address indexed user, uint256 indexed poolId, uint256 RCCReward);

    // ************************************** 修饰符 **************************************

    modifier checkPid(uint256 _pid) {
        if (_pid >= pool.length) revert InvalidPid();
        _;
    }

    modifier whenNotClaimPaused() {
        if (claimPaused) revert ClaimPaused();
        _;
    }

    modifier whenNotWithdrawPaused() {
        if (withdrawPaused) revert WithdrawPaused();
        _;
    }

    /**
     * @notice 设置 RCC 代币地址。在部署时设置基本信息。
     */
    function initialize(
        IERC20 _RCC,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _RCCPerBlock
    ) public initializer {
        if (!(_startBlock <= _endBlock && _RCCPerBlock > 0)) revert InvalidParameters();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        setRCC(_RCC);

        startBlock = _startBlock;
        endBlock = _endBlock;
        RCCPerBlock = _RCCPerBlock;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADE_ROLE)
        override
    {
        // 授权升级逻辑
    }

    // ************************************** 管理函数 **************************************

    /**
     * @notice 设置 RCC 代币地址。仅管理员可调用。
     */
    function setRCC(IERC20 _RCC) public onlyRole(ADMIN_ROLE) {
        RCC = _RCC;

        emit SetRCC(RCC);
    }

    /**
     * @notice 暂停取款功能。仅管理员可调用。
     */
    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        if (withdrawPaused) revert WithdrawAlreadyPaused();

        withdrawPaused = true;

        emit PauseWithdraw();
    }

    /**
     * @notice 取消暂停取款功能。仅管理员可调用。
     */
    function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
        if (!withdrawPaused) revert WithdrawNotPaused();

        withdrawPaused = false;

        emit UnpauseWithdraw();
    }

    /**
     * @notice 暂停领取功能。仅管理员可调用。
     */
    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        if (claimPaused) revert ClaimAlreadyPaused();

        claimPaused = true;

        emit PauseClaim();
    }

    /**
     * @notice 取消暂停领取功能。仅管理员可调用。
     */
    function unpauseClaim() public onlyRole(ADMIN_ROLE) {
        if (!claimPaused) revert ClaimNotPaused();

        claimPaused = false;

        emit UnpauseClaim();
    }

    /**
     * @notice 更新质押开始区块。仅管理员可调用。
     */
    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        if (!(_startBlock <= endBlock)) revert StartBlockMustBeSmallerThanEndBlock();

        startBlock = _startBlock;

        emit SetStartBlock(_startBlock);
    }

    /**
     * @notice 更新质押结束区块。仅管理员可调用。
     */
    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        if (!(startBlock <= _endBlock)) revert StartBlockMustBeSmallerThanEndBlock();

        endBlock = _endBlock;

        emit SetEndBlock(_endBlock);
    }

    /**
     * @notice 更新每区块的 RCC 奖励数量。仅管理员可调用。
     */
    function setRCCPerBlock(uint256 _RCCPerBlock) public onlyRole(ADMIN_ROLE) {
        if (!(_RCCPerBlock > 0)) revert InvalidParameters();

        RCCPerBlock = _RCCPerBlock;

        emit SetRCCPerBlock(_RCCPerBlock);
    }

    /**
     * @notice 添加新的质押池。仅管理员可调用。
     * 请勿多次添加相同的质押代币地址，否则 RCC 奖励分配将混乱。
     */
    function addPool(address _stTokenAddress, uint256 _poolWeight, uint256 _minDepositAmount, uint256 _unstakeLockedBlocks,  bool _withUpdate) public onlyRole(ADMIN_ROLE) {
        // 默认第一个池为 nativeCurrency 池，因此第一个池必须使用 stTokenAddress = address(0x0)
        if (pool.length > 0) {
            if (_stTokenAddress == address(0x0)) revert InvalidStakingTokenAddress();
        } else {
            if (_stTokenAddress != address(0x0)) revert InvalidStakingTokenAddress();
        }
        // 允许最小质押金额为 0
        // require(_minDepositAmount > 0, "invalid min deposit amount");
        if (!(_unstakeLockedBlocks > 0)) revert InvalidWithdrawLockedBlocks();
        if (!(block.number < endBlock)) revert AlreadyEnded();

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalPoolWeight = totalPoolWeight + _poolWeight;

        pool.push(Pool({
            stTokenAddress: _stTokenAddress,
            poolWeight: _poolWeight,
            lastRewardBlock: lastRewardBlock,
            accRCCPerST: 0,
            stTokenAmount: 0,
            minDepositAmount: _minDepositAmount,
            unstakeLockedBlocks: _unstakeLockedBlocks
        }));

        emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock, _minDepositAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice 更新指定池的信息（minDepositAmount 和 unstakeLockedBlocks）。仅管理员可调用。
     */
    function updatePool(uint256 _pid, uint256 _minDepositAmount, uint256 _unstakeLockedBlocks) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;

        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }

    /**
     * @notice 更新指定池的权重。仅管理员可调用。
     */
    function setPoolWeight(uint256 _pid, uint256 _poolWeight, bool _withUpdate) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        if (!(_poolWeight > 0)) revert InvalidPoolWeight();

        if (_withUpdate) {
            massUpdatePools();
        }

        totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
        pool[_pid].poolWeight = _poolWeight;

        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }

    // ************************************** 查询函数 **************************************

    /**
     * @notice 获取池的数量
     */
    function poolLength() external view returns(uint256) {
        return pool.length;
    }

    /**
     * @notice 返回从 _from 到 _to 区块的奖励乘数。区间为 [_from, _to)
     *
     * @param _from    起始区块号（包含）
     * @param _to      结束区块号（不包含）
     */
    function getMultiplier(uint256 _from, uint256 _to) public view returns(uint256 multiplier) {
        if (!(_from <= _to)) revert InvalidBlockRange();
        if (_from < startBlock) {_from = startBlock;}
        if (_to > endBlock) {_to = endBlock;}
        if (!(_from <= _to)) revert EndBlockMustBeGreaterThanStartBlock();
        bool success;
        (success, multiplier) = (_to - _from).tryMul(RCCPerBlock);
        if (!success) revert MultiplierOverflow();
    }

    /**
     * @notice 获取用户在指定池中的待领取 RCC 数量
     */
    function pendingRCC(uint256 _pid, address _user) external checkPid(_pid) view returns(uint256) {
        return pendingRCCByBlockNumber(_pid, _user, block.number);
    }

    /**
     * @notice 根据区块号获取用户在指定池中的待领取 RCC 数量
     */
    function pendingRCCByBlockNumber(uint256 _pid, address _user, uint256 _blockNumber) public checkPid(_pid) view returns(uint256) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];
        uint256 accRCCPerST = pool_.accRCCPerST;
        uint256 stSupply = pool_.stTokenAmount;

        if (_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            uint256 multiplier = getMultiplier(pool_.lastRewardBlock, _blockNumber);
            uint256 RCCForPool = multiplier * pool_.poolWeight / totalPoolWeight;
            accRCCPerST = accRCCPerST + RCCForPool * (1 ether) / stSupply;
        }

        return user_.stAmount * accRCCPerST / (1 ether) - user_.finishedRCC + user_.pendingRCC;
    }

    /**
     * @notice 获取用户在指定池中的质押金额
     */
    function stakingBalance(uint256 _pid, address _user) external checkPid(_pid) view returns(uint256) {
        return user[_pid][_user].stAmount;
    }

    /**
     * @notice 获取用户在指定池中的取款金额信息，包括锁定的取款金额和已解锁的取款金额
     */
    function withdrawAmount(uint256 _pid, address _user) public checkPid(_pid) view returns(uint256 requestAmount, uint256 pendingWithdrawAmount) {
        User storage user_ = user[_pid][_user];

        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks <= block.number) {
                pendingWithdrawAmount = pendingWithdrawAmount + user_.requests[i].amount;
            }
            requestAmount = requestAmount + user_.requests[i].amount;
        }
    }

    // ************************************** 公共函数 **************************************

    /**
     * @notice 更新指定池的奖励变量，使其保持最新。
     */
    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid];

        if (block.number <= pool_.lastRewardBlock) {
            return;
        }

        (bool success1, uint256 totalRCC) = getMultiplier(pool_.lastRewardBlock, block.number).tryMul(pool_.poolWeight);
        if (!success1) revert MultiplierOverflow();

        (success1, totalRCC) = totalRCC.tryDiv(totalPoolWeight);
        if (!success1) revert MultiplierOverflow();

        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            (bool success2, uint256 totalRCC_) = totalRCC.tryMul(1 ether);
            if (!success2) revert MultiplierOverflow();

            (success2, totalRCC_) = totalRCC_.tryDiv(stSupply);
            if (!success2) revert MultiplierOverflow();

            (bool success3, uint256 accRCCPerST) = pool_.accRCCPerST.tryAdd(totalRCC_);
            if (!success3) revert PoolStTokenAmountOverflow();
            pool_.accRCCPerST = accRCCPerST;
        }

        pool_.lastRewardBlock = block.number;

        emit UpdatePool(_pid, pool_.lastRewardBlock, totalRCC);
    }

    /**
     * @notice 更新所有池的奖励变量。注意 gas 消耗！
     */
    function massUpdatePools() public {
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; pid++) {
            updatePool(pid);
        }
    }

    /**
     * @notice 存入原生货币以获取 RCC 奖励
     */
    function depositnativeCurrency() public whenNotPaused() payable {
        Pool storage pool_ = pool[nativeCurrency_PID];
        if (pool_.stTokenAddress != address(0x0)) revert InvalidStakingTokenAddress();

        uint256 _amount = msg.value;
        if (_amount < pool_.minDepositAmount) revert InvalidParameters();

        _deposit(nativeCurrency_PID, _amount);
    }

    /**
     * @notice 存入质押代币以获取 RCC 奖励
     * 在存入之前，用户需要批准该合约能够支配或转移其质押代币
     *
     * @param _pid       要存入的池的 ID
     * @param _amount    要存入的质押代币数量
     */
    function deposit(uint256 _pid, uint256 _amount) public whenNotPaused() checkPid(_pid) {
        if (_pid == 0) revert InvalidParameters();
        Pool storage pool_ = pool[_pid];
        if (_amount <= pool_.minDepositAmount) revert InvalidParameters();

        if(_amount > 0) {
            IERC20(pool_.stTokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }

        _deposit(_pid, _amount);
    }

    /**
     * @notice 取出质押代币
     *
     * @param _pid       要取出的池的 ID
     * @param _amount    要取出的质押代币数量
     */
    function unstake(uint256 _pid, uint256 _amount) public whenNotPaused() checkPid(_pid) whenNotWithdrawPaused() {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        if (user_.stAmount < _amount) revert NotEnoughStakingTokenBalance();

        updatePool(_pid);

        uint256 pendingRCC_ = user_.stAmount * pool_.accRCCPerST / (1 ether) - user_.finishedRCC;

        if(pendingRCC_ > 0) {
            user_.pendingRCC = user_.pendingRCC + pendingRCC_;
        }

        if(_amount > 0) {
            user_.stAmount = user_.stAmount - _amount;
            user_.requests.push(UnstakeRequest({
                amount: _amount,
                unlockBlocks: block.number + pool_.unstakeLockedBlocks
            }));
        }

        pool_.stTokenAmount = pool_.stTokenAmount - _amount;
        user_.finishedRCC = user_.stAmount * pool_.accRCCPerST / (1 ether);

        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    /**
     * @notice 提取已解锁的取款金额
     *
     * @param _pid       要提取的池的 ID
     */
    function withdraw(uint256 _pid) public whenNotPaused() checkPid(_pid) whenNotWithdrawPaused() {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingWithdraw_;
        uint256 popNum_;
        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks > block.number) {
                break;
            }
            pendingWithdraw_ = pendingWithdraw_ + user_.requests[i].amount;
            popNum_++;
        }

        for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }

        for (uint256 i = 0; i < popNum_; i++) {
            user_.requests.pop();
        }

        if (pendingWithdraw_ > 0) {
            if (pool_.stTokenAddress == address(0x0)) {
                _safenativeCurrencyTransfer(msg.sender, pendingWithdraw_);
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(msg.sender, pendingWithdraw_);
            }
        }

        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }

    /**
     * @notice 领取 RCC 代币奖励
     *
     * @param _pid       要领取的池的 ID
     */
    function claim(uint256 _pid) public whenNotPaused() checkPid(_pid) whenNotClaimPaused() {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        uint256 pendingRCC_ = user_.stAmount * pool_.accRCCPerST / (1 ether) - user_.finishedRCC + user_.pendingRCC;

        if(pendingRCC_ > 0) {
            user_.pendingRCC = 0;
            _safeRCCTransfer(msg.sender, pendingRCC_);
        }

        user_.finishedRCC = user_.stAmount * pool_.accRCCPerST / (1 ether);

        emit Claim(msg.sender, _pid, pendingRCC_);
    }

    // ************************************** 内部函数 **************************************

    /**
     * @notice 存入质押代币以获取 RCC 奖励
     *
     * @param _pid       要存入的池的 ID
     * @param _amount    要存入的质押代币数量
     */
    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        if (user_.stAmount > 0) {
            // uint256 accST = user_.stAmount.mulDiv(pool_.accRCCPerST, 1 ether);
            (bool success1, uint256 accST) = user_.stAmount.tryMul(pool_.accRCCPerST);
            if (!success1) revert UserStAmountMulAccRCCPerSTOverflow();
            (success1, accST) = accST.tryDiv(1 ether);
            if (!success1) revert AccSTDiv1EtherOverflow();

            (bool success2, uint256 pendingRCC_) = accST.trySub(user_.finishedRCC);
            if (!success2) revert AccSTSubFinishedRCCOverflow();

            if(pendingRCC_ > 0) {
                (bool success3, uint256 _pendingRCC) = user_.pendingRCC.tryAdd(pendingRCC_);
                if (!success3) revert UserPendingRCCOverflow();
                user_.pendingRCC = _pendingRCC;
            }
        }

        if(_amount > 0) {
            (bool success4, uint256 stAmount) = user_.stAmount.tryAdd(_amount);
            if (!success4) revert UserStAmountOverflow();
            user_.stAmount = stAmount;
        }

        (bool success5, uint256 stTokenAmount) = pool_.stTokenAmount.tryAdd(_amount);
        if (!success5) revert PoolStTokenAmountOverflow();
        pool_.stTokenAmount = stTokenAmount;

        // user_.finishedRCC = user_.stAmount.mulDiv(pool_.accRCCPerST, 1 ether);
        (bool success6, uint256 finishedRCC) = user_.stAmount.tryMul(pool_.accRCCPerST);
        if (!success6) revert UserStAmountMulAccRCCPerSTOverflow();

        (success6, finishedRCC) = finishedRCC.tryDiv(1 ether);
        if (!success6) revert FinishedRCCDiv1EtherOverflow();

        user_.finishedRCC = finishedRCC;

        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
     * @notice 安全的 RCC 转账函数，以防止舍入误差导致池中没有足够的 RCC
     *
     * @param _to        接收 RCC 的地址
     * @param _amount    要转账的 RCC 数量
     */
    function _safeRCCTransfer(address _to, uint256 _amount) internal {
        uint256 RCCBal = RCC.balanceOf(address(this));

        if (_amount > RCCBal) {
            RCC.transfer(_to, RCCBal);
        } else {
            RCC.transfer(_to, _amount);
        }
    }

    /**
     * @notice 安全的原生货币转账函数
     *
     * @param _to        接收原生货币的地址
     * @param _amount    要转账的原生货币数量
     */
    function _safenativeCurrencyTransfer(address _to, uint256 _amount) internal {
        (bool success, bytes memory data) = address(_to).call{
            value: _amount
        }("");

        if (!success) revert NativeCurrencyTransferFailed();
        if (data.length > 0) {
            bool successDecoded = abi.decode(data, (bool));
            if (!successDecoded) revert NativeCurrencyTransferOperationDidNotSucceed();
        }
    }
}