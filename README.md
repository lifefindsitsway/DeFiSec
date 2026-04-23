# DeFiSec

DeFi 安全事件分析与链上取证。

本仓库收录我对 DeFi 领域真实安全事件的逆向分析、漏洞机理拆解和链上取证报告。每个案例包含完整的分析报告、相关合约源码及复现代码。

## 案例索引

| 日期 | 事件 | 漏洞类型 | 损失 | 报告 |
|---|---|---|---|---|
| 2026-03-03 | z0r0z 的 Uniswap V4 Swap Router | ABI 编码 / 权限校验绕过 | $42,607 USDC | [完整分析](./20260303-UniswapV4Router04-ABI-Parser-Differential/UniswapV4Router04攻击逆向分析报告.md) |

## 分析框架

每个案例目录通常包含：

```
<事件名称>/
├── README.md              # 案例概述与关键发现
├── *.md                   # 分析报告
├── reverse-analysis/      # Foundry 项目（逆向重建源码 + Fork Replay 测试）
└── *-source/              # 涉事合约原始源码
```

## 关于作者

**Lifefindsitsway** — 区块链安全研究员

## 声明

本仓库所有内容均为事后分析（post-incident analysis），基于公开的链上数据和开源代码，不涉及任何非公开信息。仓库中的攻击合约源码仅供安全研究和教育用途。
