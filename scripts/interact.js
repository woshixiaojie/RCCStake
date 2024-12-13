// scripts/interact.js

import('dotenv').config();
const { ethers } = require("hardhat");

async function main() {
  // 从环境变量获取合约地址
  const ERC20MockAddress = process.env.ERC20MockAddress;
  const RCCStakeProxyAddress = process.env.RCCStakeProxyAddress;

  // 获取 ERC20Mock 合约实例
  const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
  const rcc = ERC20Mock.attach(ERC20MockAddress);

  // 获取 RCCStake 合约实例
  const RCCStake = await ethers.getContractFactory("RCCStake");
  const rccStake = RCCStake.attach(RCCStakeProxyAddress);

  // 查看 RCC 代币名称
  const name = await rcc.name();
  console.log("RCC Token Name:", name);

  // 查看 RCC 代币符号
  const symbol = await rcc.symbol();
  console.log("RCC Token Symbol:", symbol);

  // 查看 RCC 代币总供应量
  const totalSupply = await rcc.totalSupply();
  console.log("Total Supply:", ethers.formatUnits(totalSupply, 18));

  // 查看 RCCStake 合约的开始和结束区块
  const startBlock = await rccStake.startBlock();
  console.log("Staking Start Block:", startBlock.toString());

  const endBlock = await rccStake.endBlock();
  console.log("Staking End Block:", endBlock.toString());

  // RCCStake 每个区块的RCC奖励
  const rccPerBlock = await rccStake.RCCPerBlock();
  console.log("RCC Per Block:", ethers.formatUnits(rccPerBlock, 18));

}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
