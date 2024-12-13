// RCCStake部署时的ERC20合约
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    // 合约的构造函数
    // 两个参数 name 和 symbol，分别代表代币的名称和符号
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {

        // _mint：这是 ERC20 合约中的内部函数，用于铸造新的代币
        
        // 1000000 * 10 ** decimals()：计算出铸造的代币总量。
        // 例如，如果 decimals 是 18，那么总量为 1,000,000 * 10^18 个最小单位的代币
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
