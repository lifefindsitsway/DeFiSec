# UniswapV4Router04 ABI Parser Differential 漏洞分析

2026 年 3 月 3 日，攻击者利用 [z0r0z.eth](https://etherscan.io/address/0x1c0aa8ccd568d90d61659f060d1bfb1e6f855a20) 开发的 [UniswapV4Router04](https://etherscan.io/address/0x00000000000044a361Ae3cAc094c9D1b14Eece97) 合约中一个 ABI 解析差异漏洞（Parser Differential），从受害者钱包中盗走 42,606.96 USDC（约 $42,607），通过 Uniswap V4 ETH/USDC 池兑换为 21.198 ETH 后经 Railgun 洗钱。

漏洞根因：`swap(bytes,uint256)` 函数中，一行用于 Gas 优化的内联汇编 `calldataload(164)` 硬编码了 calldata 偏移，攻击者通过非标准 ABI 编码绕过权限校验，以受害者身份执行 swap。该合约经过 3 次独立安全审计（33audits、Kaden、Kupia），均未发现此漏洞，在链上存活 320 天后被利用。

本仓库包含对该攻击事件的完整逆向分析、链上取证，以及从 1,924 字节未开源攻击合约 bytecode 重建的等价 Solidity 源码。

## 目录结构

```
UniswapV4Router04-ABI-Parser-Differential/
│
├── README.md								  # 本文件
├── UniswapV4Router04攻击逆向分析-完整版.md	    # 完整分析报告
├── Copycat 失败分析.md						   # Copycat 交易失败原因分析
│
├── reverse-analysis/                         # 逆向分析 Foundry 项目
│   ├── src/
│   │   └── Attack.sol                        # 逆向重建的攻击合约源码
│   └── test/
│       └── ReplayTest.t.sol                  # Mainnet Fork Replay 验证测试
│
└── UniswapV4Router04/                        # UniswapV4Router04 合约源码（从 codeslaw.app 下载的已验证源码）
```

## 关键发现

- **漏洞类型**：ABI Parser Differential — `calldataload(164)` 硬编码偏移 vs `abi.decode` 跟随偏移指针，两套解析逻辑的语义分歧
- **损失**：$42,607 USDC，4 分钟内完成部署、盗窃、兑换、洗钱全流程
- **USDT 幸免**：$25,575 USDT 因 USDT 合约的 non-standard `transferFrom`（无返回值）触发 Router ABI 解码器 revert，无法被盗
- **3 次审计均未发现**：33audits（2025-03-07）、Kaden（2025-03-11）、Kupia（2025-03-19），无一识别此漏洞
- **逆向验证**：从未开源 bytecode 重建 Solidity 源码，Fork Replay ETH 收益 wei 级精确匹配（21,197,984,596,759,249,607 wei）
- **漏洞现状**：链上永久存在，不可修复。835 个历史用户全量扫描确认当前无实际风险

## 涉事地址

| 角色 | 地址 |
|---|---|
| 攻击者 EOA | [`0xd6B7e831D64e573278f091AA7E68Fbf2A8FA9916`](https://etherscan.io/address/0xd6B7e831D64e573278f091AA7E68Fbf2A8FA9916) |
| 攻击合约 | [`0xdEd262d0A933b7BB4Ed8C4B6cb2dcE5b157B74A0`](https://etherscan.io/address/0xdEd262d0A933b7BB4Ed8C4B6cb2dcE5b157B74A0) |
| 受害者 | [`0x65A8F07Bd9A8598E1b5B6C0a88F4779DBC077675`](https://etherscan.io/address/0x65A8F07Bd9A8598E1b5B6C0a88F4779DBC077675) |
| UniswapV4Router04 | [`0x00000000000044a361Ae3cAc094c9D1b14Eece97`](https://etherscan.io/address/0x00000000000044a361Ae3cAc094c9D1b14Eece97) |
| Uniswap V4 PoolManager | [`0x000000000004444c5dc75cB358380D2e3dE08A90`](https://etherscan.io/address/0x000000000004444c5dc75cB358380D2e3dE08A90) |

| 交易 | 哈希 |
|---|---|
| 攻击执行 | [`0xfe34c4be...b466a`](https://etherscan.io/tx/0xfe34c4beee447de536bbd3d613aa0e3aa7eeb63832e9453e4ef3999924ab466a) |
| 攻击合约部署 | [`0xe27dda04...47e1`](https://etherscan.io/tx/0xe27dda04a4bf8e83841f3136866a0f1115807d20b3702de141d920fc57aa47e1) |

## Fork Replay 复现

```bash
# 需要 Foundry 和以太坊主网 RPC
cd reverse-analysis
forge test --fork-url <YOUR_MAINNET_RPC> --fork-block-number 24575084 -vvv
```

## 声明

本仓库为事后分析（post-incident analysis），非漏洞首次发现或负责任披露。该漏洞已于 2026-03-03 被公开利用，项目方已在攻击当天通过 GitHub commit 响应。所有分析基于公开的链上数据和开源代码，不涉及任何非公开信息。

