// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./RCCStake.sol"; // 导入旧版本的合约

contract RCCStakeV2 is RCCStake {
    // 新增一个变量以测试升级后的存储布局
    uint256 public newVariable;

    // 新增一个函数以验证升级后的功能
    function setNewVariable(uint256 _value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        newVariable = _value;
    }

    // 覆盖或新增其他功能（可选）
    // 例如，修改现有函数的行为，添加新的事件等
}
