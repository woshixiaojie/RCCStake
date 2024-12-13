// scripts/deploy.js

const { ethers, upgrades} = require("hardhat");

async function main() {
  // 部署 ERC20Mock 合约作为 RCC 代币（仅用于本地测试）
  const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
  const rcc = await ERC20Mock.deploy("RCC Token", "RCC");
  await rcc.waitForDeployment(); // 等待部署完成
  console.log("Mock RCC Token 部署到:", rcc.target);
  
  const currentBlock = await ethers.provider.getBlockNumber();// // 获取当前区块号
  const startBlock = currentBlock + 10; // 质押开始于 10 个区块后
  const endBlock = startBlock + 100000; // 任意结束区块
  const RCCPerBlock = ethers.parseUnits("10", 18); // 每区块 10 RCC

  // 获取 RCCStake 合约工厂
  const RCCStake = await ethers.getContractFactory("RCCStake");

  // 部署可升级代理合约
  // 用于转发调用到逻辑合约
  const rccStake = await upgrades.deployProxy(RCCStake, [
    rcc.target,
    startBlock,
    endBlock,
    RCCPerBlock,
  ], { initializer: 'initialize' });

  await rccStake.waitForDeployment();
  console.log("RCCStake 部署到:", rccStake.target);

  // 可选
  // 逻辑合约，这是实际包含业务逻辑的合约，也就RCCStake实际部署的合约地址
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(rccStake.target);
  console.log("RCCStake 实现合约地址:", implementationAddress);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
