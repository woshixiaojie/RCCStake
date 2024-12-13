// test/RCCStake.test.js

const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("RCCStake Contract", function () {
    let RCCToken;
    let rccToken;
    let RCCStake;
    let rccStake;
    let owner, admin, user1, user2;
    const startBlockOffset = 10; // Start staking 10 blocks after deployment
    const endBlockOffset = 1000; // End staking at block number + 1000
    const RCCPerBlock = ethers.parseEther("10"); // 10 RCC per block

    // beforeEach 确实会在每个测试用例（it 块）运行之前执行一次
    beforeEach(async function () {
        // 获取多个以太坊账户，用于模拟不同的用户和管理员角色
        [owner, admin, user1, user2, ...addrs] = await ethers.getSigners();

        // 获取每个签名者的地址
        user1Address = await user1.getAddress()
        user2Address = await user2.getAddress()

        // 部署 Mock RCC ERC20 Token
        RCCToken = await ethers.getContractFactory("ERC20Mock");
        rccToken = await RCCToken.deploy("RCC Token", "RCC");
        await rccToken.waitForDeployment();
        console.log("Mock RCC Token 部署到:", rccToken.target);

        // 获取当前区块号
        currentBlock = await ethers.provider.getBlockNumber();

        // 部署 RCCStake 合约
        RCCStake = await ethers.getContractFactory("RCCStake");
        rccStake = await upgrades.deployProxy(
            RCCStake,
            [
                rccToken.target, // 在 v6 中，合约地址通过 `target` 属性获取
                currentBlock + startBlockOffset,
                currentBlock + endBlockOffset,
                RCCPerBlock,
            ],
            { initializer: 'initialize' }
        );
        await rccStake.waitForDeployment();

        // 授予 admin 权限
        const adminRole = ethers.keccak256(ethers.toUtf8Bytes("admin_role"));
        await rccStake.grantRole(adminRole, admin.address);
        console.log("Admin role granted to:", admin.address);

        // 添加第一个原生货币池
        const addNativePoolTx = await rccStake.connect(admin).addPool(
            ethers.ZeroAddress, // 使用 .ZeroAddress 确保传递 address(0)
            100, // poolWeight
            ethers.parseEther("0"), // minDepositAmount（根据合约逻辑）
            100, // unstakeLockedBlocks
            false // 不需要更新其他池
        );

        // 分发 RCC 代币给 RCCStake 合约用于奖励
        await rccToken.transfer(rccStake.target, ethers.parseEther("100000"));
        console.log("RCC tokens transferred to RCCStake");

    });

    // 验证初始化功能
    describe("Initialization", function () {
        it("Should set the correct RCC token address", async function () {
            expect(await rccStake.RCC()).to.equal(rccToken.target);
        });

        it("Should set the correct start and end blocks", async function () {
            // 使用 beforeEach 中存储的 currentBlock
            // 在 Ethers.js v6 中，合约中的 uint256 类型被映射为 BigInt
            // 将期望值Number 转换为 BigInt
            expect(await rccStake.startBlock()).to.equal(BigInt(currentBlock + startBlockOffset));
            expect(await rccStake.endBlock()).to.equal(BigInt(currentBlock + endBlockOffset));
        });

        it("Should set the correct RCCPerBlock", async function () {
            expect(await rccStake.RCCPerBlock()).to.equal(RCCPerBlock);
        });
    });

    // 验证管理员功能
    describe("Admin Functions", function () {

        // 管理员可以设置 RCC 代币地址
        it("Admin can set RCC token address", async function () {
            const newRCC = await RCCToken.deploy("New RCC", "NRCC");
            await newRCC.waitForDeployment();

            const setRCCTx = await rccStake.connect(admin).setRCC(newRCC.target);
            await expect(setRCCTx)
                .to.emit(rccStake, 'SetRCC')
                .withArgs(newRCC.target);

            expect(await rccStake.RCC()).to.equal(newRCC.target);
        });

        // 非管理员无法设置 RCC 代币地址
        it("Non-admin cannot set RCC token address", async function () {
            const adminRole = ethers.keccak256(ethers.toUtf8Bytes("admin_role"));
            await expect(
                // 调用合约的 setRCC 函数，尝试将 RCC 代币地址设置为 user1 的地址
                rccStake.connect(user1).setRCC(user1Address)
                // OpenZeppelin 的 AccessControl：在较新版本的 OpenZeppelin 合约库中，AccessControl 使用自定义错误而不是回退原因字符串
                // 表示 user1 账户缺少 admin_role 角色，无法执行 setRCC 操作
            ).to.be.reverted;
        });

        // 管理员可以暂停和恢复取款功能
        it("Admin can pause and unpause withdraw", async function () {
            // 管理员可以调用 pauseWithdraw 和 unpauseWithdraw 来暂停和恢复取款功能
            // 分别触发 PauseWithdraw 和 UnpauseWithdraw 事件
            // 并正确更新状态变量 withdrawPaused
            const pauseTx = await rccStake.connect(admin).pauseWithdraw();
            await expect(pauseTx)
                .to.emit(rccStake, 'PauseWithdraw');

            expect(await rccStake.withdrawPaused()).to.equal(true);

            const unpauseTx = await rccStake.connect(admin).unpauseWithdraw();
            await expect(unpauseTx)
                .to.emit(rccStake, 'UnpauseWithdraw');

            expect(await rccStake.withdrawPaused()).to.equal(false);
        });


        it("Admin can pause and unpause claim", async function () {
            const pauseTx = await rccStake.connect(admin).pauseClaim();
            await expect(pauseTx)
                .to.emit(rccStake, 'PauseClaim');

            expect(await rccStake.claimPaused()).to.equal(true);

            const unpauseTx = await rccStake.connect(admin).unpauseClaim();
            await expect(unpauseTx)
                .to.emit(rccStake, 'UnpauseClaim');

            expect(await rccStake.claimPaused()).to.equal(false);
        });

        // 管理员可以添加新的质押池
        it("Admin can add a new pool", async function () {
            const stToken = await RCCToken.deploy("Staking Token", "STK");
            await stToken.waitForDeployment();

            const currentBlock = await ethers.provider.getBlockNumber();

            const addPoolTx = await rccStake.connect(admin).addPool(
                stToken.target,
                100, // poolWeight
                ethers.parseEther("10"), // minDepositAmount
                100, // unstakeLockedBlocks
                true // withUpdate
            );
            await expect(addPoolTx).to.emit(rccStake, 'AddPool');

            const poolLength = await rccStake.poolLength();
            expect(poolLength).to.equal(2); // Native currency pool is pool 0
        });
    });

    // 测试用户功能
    describe("User Functions", function () {
        let stToken;

        beforeEach(async function () {
            // 部署一个额外的 ERC20 代币用于质押
            stToken = await RCCToken.deploy("Staking Token", "STK");
            await stToken.waitForDeployment();

            // Admin 添加一个新的质押池
            const addPoolTx = await rccStake.connect(admin).addPool(
                stToken.target,
                100, // poolWeight
                ethers.parseEther("10"), // minDepositAmount
                100, // unstakeLockedBlocks
                true // withUpdate
            );
            await addPoolTx.wait();

            // 为 user1 和 user2 铸造 stTokens
            await stToken.mint(user1Address, ethers.parseEther("1000"));
            await stToken.mint(user2Address, ethers.parseEther("1000"));
            console.log("为 user1 和 user2 铸造了 1000 个 stTokens");

            // 用户批准，RCCStake合约，可以转移其代币
            await stToken.connect(user1).approve(rccStake.target, ethers.parseEther("1000"));
            await stToken.connect(user2).approve(rccStake.target, ethers.parseEther("1000"));
        });

        it("User can deposit staking tokens", async function () {
            const depositTx = await rccStake.connect(user1).deposit(1, ethers.parseEther("100"));
            await expect(depositTx)
                .to.emit(rccStake, 'Deposit')
                .withArgs(user1Address, 1, ethers.parseEther("100"));

            const userInfo = await rccStake.user(1, user1Address);
            expect(userInfo.stAmount).to.equal(ethers.parseEther("100"));
        });

        it("User cannot deposit below minDepositAmount", async function () {
            await expect(
                rccStake.connect(user1).deposit(1, ethers.parseEther("5"))
                // 断言事务是否因特定的自定义错误而回退
            ).to.be.revertedWithCustomError(RCCStake, "InvalidParameters");
        });

        // 用户可以请求取款并在锁定期后提取
        it("User can request unstake and withdraw after lock period", async function () {
            // 用户存款
            // 调用 deposit 函数，向池子编号为 1 的质押池存入 100 个代币
            const depositTx = await rccStake.connect(user1).deposit(1, ethers.parseEther("100"));
            // 等待交易被矿工打包并确认
            await depositTx.wait();

            // 增加若干区块。模拟时间流逝
            for (let i = 0; i < 150; i++) {
                // 调用以太坊虚拟机（EVM）来挖出一个新的区块
                await ethers.provider.send("evm_mine", []);
            }

            // 用户请求取款。
            // 用户 user1 调用 unstake 函数，从池子编号 1 的质押池中请求解除 50 个代币的质押
            const unstakeTx = await rccStake.connect(user1).unstake(1, ethers.parseEther("50"));
            // 使用 Chai 的断言库验证交易是否正确触发了预期的事件
            await expect(unstakeTx)
                .to.emit(rccStake, 'RequestUnstake')
                // 期望事件的参数为 user1 的地址、池子编号 1 和解除质押的数量 50
                .withArgs(user1Address, 1, ethers.parseEther("50"));

            // 增加更多区块以超过锁定期
            for (let i = 0; i < 100; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            // 用户提取取款
            const withdrawTx = await rccStake.connect(user1).withdraw(1);
            const currentBlock = await ethers.provider.getBlockNumber();
            await expect(withdrawTx)
                .to.emit(rccStake, 'Withdraw')
                .withArgs(user1Address, 1, ethers.parseEther("50"), currentBlock);

            // 验证用户的质押信息是否正确更新
            // 调用合约的 user 函数，获取用户 user1 在池子编号 1 中的质押信息
            // mapping(uint256 => mapping(address => UserInfo)) public user;
            // function user(uint256 poolId, address userAddress) external view returns (UserInfo memory);
            const userInfo = await rccStake.user(1, user1Address);
            expect(userInfo.stAmount).to.equal(ethers.parseEther("50"));
        });


        it("User can claim RCC rewards", async function () {
            // 用户存款
            const depositTx = await rccStake.connect(user2).deposit(1, ethers.parseEther("100"));
            await depositTx.wait();

            // 增加若干区块以生成奖励
            for (let i = 0; i < 50; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            // 用户领取奖励
            const claimTx = await rccStake.connect(user2).claim(1);
            await expect(claimTx)
                .to.emit(rccStake, 'Claim');

            // 获取用户的 RCC 代币余额
            const userRCCBalance = await rccToken.balanceOf(user2Address);
            // 断言用户的 RCC 代币余额大于 0
            expect(userRCCBalance).to.be.gt(ethers.parseEther("0"));
        });

        it("User cannot claim rewards when claim is paused", async function () {
            // 用户存款
            const depositTx = await rccStake.connect(user1).deposit(1, ethers.parseEther("100"));
            await depositTx.wait();

            // 管理员暂停领取
            const pauseClaimTx = await rccStake.connect(admin).pauseClaim();
            await pauseClaimTx.wait();

            // 领取奖励
            await expect(
                rccStake.connect(user1).claim(1)
                // 期望合约调用会以回退的方式失败，并且错误信息包含 "ClaimPaused"
            ).to.be.revertedWithCustomError(rccStake, "ClaimPaused");
        });

        it("User cannot withdraw when withdraw is paused", async function () {
            // 用户存款
            const depositTx = await rccStake.connect(user1).deposit(1, ethers.parseEther("100"));
            await depositTx.wait();

            // 用户请求取款
            const unstakeTx = await rccStake.connect(user1).unstake(1, ethers.parseEther("50"));
            await unstakeTx.wait();

            // 管理员暂停取款
            const pauseWithdrawTx = await rccStake.connect(admin).pauseWithdraw();
            await pauseWithdrawTx.wait();

            // 增加足够的区块以超过锁定期
            for (let i = 0; i < 150; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            await expect(
                rccStake.connect(user1).withdraw(1)
            ).to.be.revertedWithCustomError(rccStake, "WithdrawPaused");
        });

        // 多个用户可以独立交互
        it("Multiple users can interact independently", async function () {
            // 用户1存款
            const depositUser1Tx = await rccStake.connect(user1).deposit(1, ethers.parseEther("100"));
            await depositUser1Tx.wait();

            // 用户2存款
            const depositUser2Tx = await rccStake.connect(user2).deposit(1, ethers.parseEther("200"));
            await depositUser2Tx.wait();

            // 增加若干区块
            for (let i = 0; i < 100; i++) {
                await ethers.provider.send("evm_mine", []);
            }

            // 用户1领取奖励
            const claimUser1Tx = await rccStake.connect(user1).claim(1);
            await expect(claimUser1Tx)
                .to.emit(rccStake, 'Claim');
            const user1RCC = await rccToken.balanceOf(user1Address);
            expect(user1RCC).to.be.gt(ethers.parseEther("0"));

            // 用户2领取奖励
            const claimUser2Tx = await rccStake.connect(user2).claim(1);
            await expect(claimUser2Tx)
                .to.emit(rccStake, 'Claim');
            const user2RCC = await rccToken.balanceOf(user2Address);
            expect(user2RCC).to.be.gt(user1RCC);
        });
    });

    // 测试边界case和安全性
    describe("Edge Cases and Security", function () {

        it("Cannot add a pool with invalid staking token address", async function () {
            await expect(
                rccStake.connect(admin).addPool(
                    ethers.ZeroAddress, // ethers.constants.AddressZero 在 v6 中改为 ethers.ZeroAddress
                    100,
                    ethers.parseEther("10"),
                    100,
                    true
                )
            ).to.be.revertedWithCustomError(rccStake, "InvalidStakingTokenAddress");
        });

        it("Cannot set startBlock greater than endBlock", async function () {
            const currentBlock = await ethers.provider.getBlockNumber();
            await expect(
                rccStake.connect(admin).setStartBlock(currentBlock + 2000)
            ).to.be.revertedWithCustomError(rccStake, "StartBlockMustBeSmallerThanEndBlock");
        });

        it("Cannot set endBlock less than startBlock", async function () {
            const currentBlock = await ethers.provider.getBlockNumber();
            await expect(
                rccStake.connect(admin).setEndBlock(currentBlock - 10)
            ).to.be.revertedWithCustomError(rccStake, "StartBlockMustBeSmallerThanEndBlock");
        });

        // 验证没有 UPGRADE_ROLE 权限的用户是否被正确限制，无法对 RCCStake 合约进行升级    
        it("Cannot upgrade without UPGRADE_ROLE", async function () {
            // "RCCStakeV2": 这是新版本的合约名称，假设您正在尝试将 RCCStake 升级到 RCCStakeV2 版本。
            const RCCStakeV2 = await ethers.getContractFactory("RCCStakeV2");

            await expect(
                // 没有 UPGRADE_ROLE 权限的用户（user1），升级已经部署的代理合约
                upgrades.upgradeProxy(rccStake.target, RCCStakeV2.connect(user1))
                // 预期的合约调用会因某种原因失败并回退
            ).to.be.reverted;

        });

        // 其他边界条件和安全测试可以在这里添加
    });
});
