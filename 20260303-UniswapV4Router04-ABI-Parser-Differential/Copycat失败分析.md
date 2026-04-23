# 6 笔 `0x30f5d90e` 交易：1 成功 5 失败的完整原因分析

## 时间线

| 时间 (UTC) | 事件 | 区块 |
|---|---|---|
| 06:15:11 | 原始攻击合约 `0xdEd2` 部署 | #24575075 |
| **06:17:11** | **攻击成功** — 窃取 42,606.96 USDC | **#24575085** |
| 06:42:23 | Copycat 合约 `0x475d` 部署（EOA `0xf957`）| #24575211 |
| 06:43:47 | Copycat 尝试 #1 — **USDT** — 失败 | #24575218 |
| 06:44:23 | Copycat 尝试 #2 — **USDT** — 失败 | #24575221 |
| 06:55:47 | Copycat 尝试 #3 — **USDC** — 失败 | #24575278 |
| 08:24:35 | Copycat 尝试 #4 — **USDC** — 失败 | #24575718 |
| **08:50:13** | **GitHub commit "simplify abi" 推送** | — |
| 08:55:23 | Copycat 尝试 #5 — **USDC** — 失败 | #24575872 |

## 关键地址

| 角色 | 地址 |
|---|---|
| 原始攻击者 EOA | `0xd6B7e831D64e573278f091AA7E68Fbf2A8FA9916` |
| 原始攻击合约 | `0xdEd262d0A933b7BB4Ed8C4B6cb2dcE5b157B74A0` |
| Copycat EOA | `0xf9572fa0a2ac1a174824c12b3e2eddddaf26bc94` |
| Copycat 合约 | `0x475d94166117ac741571f46ddef770e68ca22c01` |
| 竞争者 EOA | `0xf33cdbef0e61b0cd5f74a2ad2bfa297b4224a14a` |
| 竞争者合约 | `0x339c0db4a0030c88b4a48aafe56cdba23c8d4338` |
| 受害者 | `0x65A8F07Bd9A8598E1b5B6C0a88F4779DBC077675` |
| UniswapV4Router04 | `0x00000000000044a361Ae3cAc094c9D1b14Eece97` |
| Uniswap V4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` |

## 6 笔交易详情

| # | 交易哈希 | 区块 | Token | 状态 | Gas Used | 合约 |
|---|---|---|---|---|---|---|
| 0 | `0xfe34c4be...` | 24575085 | USDC | SUCCESS | — | `0xdEd2`（原始）|
| 1 | `0xa10117f7...` | 24575218 | USDT | REVERTED | 146,224 | `0x475d`（copycat）|
| 2 | `0xb2eafd17...` | 24575221 | USDT | REVERTED | 146,224 | `0x475d`（copycat）|
| 3 | `0x472a7710...` | 24575278 | USDC | REVERTED | 62,404 | `0x475d`（copycat）|
| 4 | `0xd863c08e...` | 24575718 | USDC | REVERTED | 62,404 | `0x475d`（copycat）|
| 5 | `0xff0251fc...` | 24575872 | USDC | REVERTED | 62,404 | `0x475d`（copycat）|

**6 笔交易的受害者完全相同**：原始攻击与 5 笔 copycat 的 calldata 中 `victim` 参数均为 `0x65A8F07Bd9A8598E1b5B6C0a88F4779DBC077675`，`router` 参数均为 Router04。Copycat 仅在 tx #3 时将 `tokens[0]` 从 USDT 切换为 USDC，其余参数（`router`、`victim`、数组长度）从未改变，说明 copycat 直接复制了原始攻击交易的参数。

## 失败原因一：USDT 非标准 ERC20 返回值（tx #1, #2）

### 受害者 USDT 状态（攻击时）

```
USDT balance:    25,575,292,076  (~$25,575)
USDT allowance:  type(uint256).max (无限授权给 Router)
```

受害者当时持有 ~$25,575 USDT，且对 Router 的 allowance 为 `type(uint256).max`。从链上证据看，这两笔攻击**理论上有 $25,575 可窃取**，但失败了。

### 执行 Trace

```
copycat.exploit()
  → USDT.balanceOf(victim) = 25,575,292,076       ✓
  → USDT.allowance(victim, router) = max           ✓
  → Router.swap(data, deadline)
    → PoolManager.unlock()
      → Router.unlockCallback()
        → PoolManager.swap(key, params)            ✓ (Swap 事件已发出)
        → PoolManager.sync(USDT)                   ✓
        → USDT.transferFrom(victim, PM, 25.5B)     ✓ (Transfer 事件已发出!)
        → ← [Revert] EvmError: Revert             ✗ ← ABI 解码失败
```

### 根本原因

USDC 与 USDT 的 `transferFrom` 返回值对比：

```
USDC.transferFrom → 0x0000...0001  (32 bytes, bool = true)  ← 标准 ERC20
USDT.transferFrom → 0x             (0 bytes, 无返回值)       ← 非标准 ERC20
```

USDT 是知名的"非标准 ERC20"——其 `transferFrom` 函数签名为 `function transferFrom(address, address, uint256) public`，**没有 `returns (bool)`**。

Router04 的代码使用标准 Solidity IERC20 接口调用 `transferFrom`。Solidity 0.8.x 在 ABI 解码时**要求返回数据至少 32 bytes**。当 USDT 返回 0 bytes 时，ABI 解码器直接 revert。

讽刺的是：从 EVM 层面看，**USDT 实际已经成功转账**（Transfer 事件已发出，25,575 USDT 从受害者转到了 PoolManager）。但由于 Router 无法解码返回值而 revert，整个交易回滚，所有状态变更被撤销。

**Gas 消耗：146,224** — 执行到了 swap + sync + transferFrom 之后才失败，说明代码执行到了极深处。

## 失败原因二：受害者 USDC 余额为零 / MEV 排序竞争（tx #3, #4, #5）

原始攻击在 06:17:11 已将受害者的**全部 42,606.96 USDC** 清空。

### tx #3（区块 24575278, 06:55:47）— 余额为零，无竞争者

```
受害者 USDC 余额 (block 24575277): 0
```

原始攻击在 38 分钟前（06:17:11）已将受害者的全部 USDC 清空，此时受害者尚未从任何 DeFi 活动中收到新的 USDC，余额仍为 0。`_getAmount()` 返回 0，Router 调用 `PoolManager.swap()` 时 `amountSpecified = 0`，PoolManager 直接以自定义错误 **`SwapAmountCannotBeZero()`**（selector `0xbe8b8507`）revert。

**与 tx #4、#5 的关键区别**：tx #3 是纯粹的"没钱可偷"——该区块内没有任何竞争者介入；而 tx #4、#5 是"有钱但被别人先偷走了"——受害者已收到新的小额 USDC，但 MEV bot `0xf33c` 在同一区块内抢先完成了转移。

### tx #4（区块 24575718, 08:24:35）— MEV 排序竞争

```
受害者 USDC 余额 (block 24575717 末): 90,129,624  (~$90.13)
Copycat 在区块内排位: transactionIndex = 1（第二笔）
```

受害者从正常 DeFi 活动中获得了 $90.13 USDC。但 copycat 在区块内排位 `transactionIndex = 1`。

**index 0 的交易**（`0xab0facd3...`）来自另一个 MEV bot（EOA `0xf33c` → 合约 `0x339c`），该交易**使用同一个 Router 漏洞成功窃取了这 $90 USDC**：
- 交易状态：SUCCESS
- Gas Used：129,496
- 日志中包含 PoolManager Swap 事件
- 日志中包含 USDC Transfer FROM victim（90,129,624）

等 copycat 的 tx 执行时，余额已为 0 → `SwapAmountCannotBeZero()`。

### tx #5（区块 24575872, 08:55:23）— 同样的 MEV 排序失败

```
受害者 USDC 余额 (block 24575871 末): 82,685,610  (~$82.69)
Copycat 在区块内排位: transactionIndex = 2（第三笔）
```

同样的模式——受害者有 $82.69 USDC，但前面的交易（同一 `0xf33c` EOA）已将 USDC 转走。

**Gas 消耗：62,404**（三笔 USDC copycat 完全相同）— 在 `PoolManager.swap()` 调用处即失败，远早于 USDT 的失败点。

### USDC Copycat 模拟验证

在受害者有 $90 USDC 的状态下（block 24575717）模拟执行 copycat 合约，**攻击完全成功**：

```
copycat.exploit()
  → USDC.balanceOf(victim) = 90,129,624           ✓
  → Router.swap()
    → PoolManager.swap()                           ✓
    → PoolManager.sync(USDC)                       ✓
    → USDC.transferFrom(victim, PM, 90,129,624)    ✓ (returns true)
    → PoolManager.settle()                         ✓
    → PoolManager.take(ETH, copycat_EOA, 0.045 ETH) ✓
  → 交易成功, gas: 123,993
```

这证明：漏洞仍然存在，USDC 完全兼容，copycat 的合约代码本身没有问题——**唯一的问题是区块内的交易排序**。

## GitHub commit "simplify abi" 与失败无关

通过链上验证，Router 合约的 **bytecode 在所有相关区块完全相同**：

```
区块 24575084（攻击前）     : 20,951 hex chars
区块 24575217（copycat 前）  : 20,951 hex chars
区块 24575871（copycat #5前）: 20,951 hex chars
区块 24576000（远后于攻击）   : 20,951 hex chars
区块 24580000（数千区块后）   : 20,951 hex chars
```

z0r0z 在 08:50:13 UTC 推送的 [commit 0cd5187](https://github.com/z0r0z/v4-router/commit/0cd5187c7929a48d73b982662e124b793cbe2218) 只是 Git 仓库的**源码变更**（commit message: "simplify abi"），并未在链上重新部署 Router。漏洞函数 `swap(bytes,uint256)` 在所有 5 笔 copycat 交易执行时**仍然存在且可用**。

受害者的 USDC allowance 也始终保持 `~type(uint256).max`，从未被撤销：

```
Block 24575084（攻击前）   : 1.157e77
Block 24575277（copycat前）: 1.157e77
Block 24575717（copycat前）: 1.157e77
Block 24575871（copycat前）: 1.157e77
```

## 三方 MEV 竞争总结

| 攻击者 | 合约 | USDC 结果 | USDT 结果 | 总收益 |
|---|---|---|---|---|
| `0xd6B7`（原始）| `0xdEd2` | $42,606 ✓ | 未尝试 | ~$42,606 |
| `0xf33c`（竞争者）| `0x339c` | $90 + $82 ✓ | 未知 | ~$172 |
| `0xf957`（copycat）| `0x475d` | 0/0/0 ✗ | $25,575 ✗ | $0 |

### 各方分析

**原始攻击者 `0xd6B7`** — 最为精明：
- 只攻击 USDC（标准 ERC20），避开 USDT
- 一击即中，不给 copycat 机会

**竞争者 `0xf33c`** — 技术成熟的 MEV bot：
- 持续监控受害者新增的小额 USDC
- 在区块排序中始终抢先于 copycat
- 成功吃到残渣（$90 + $82）

**Copycat `0xf957`** — 三方中最不成熟：
1. 先尝试 USDT — 不了解 USDT 的非标准 ERC20 特性（Router 无法处理）
2. 转向 USDC — 每次都被竞争者 `0xf33c` 在区块排序中抢先
3. 坚持了约 2 小时后放弃
4. 直接复制原始攻击合约字节码，但缺乏对 ERC20 兼容性和 MEV 排序的深入理解

## 附录：两种失败模式的 Gas 对比

```
USDT 失败路径 (146,224 gas):
  exploit → balanceOf → allowance → Router.swap → PM.unlock → unlockCallback
  → PM.swap ✓ → PM.sync ✓ → USDT.transferFrom ✓ → ABI decode revert ✗

USDC 失败路径 (62,404 gas):
  exploit → balanceOf → allowance → Router.swap → PM.unlock → unlockCallback
  → PM.swap(amount=0) → SwapAmountCannotBeZero() ✗
```

Gas 差异（146,224 vs 62,404）精确反映了两种失败点在执行深度上的差异：USDT 在完成整个 swap 流程后才在返回值解码处失败，而 USDC 在进入 swap 时就因零金额被拒绝。

---

## 深入分析一：攻击者如何才能成功窃取受害者的 ~$25,575 USDT？

### 结论：通过 Router04 的 `swap(bytes,uint256)` 函数——不可能

Router04 的 bytecode 在处理 `transferFrom` 返回值时有一段硬编码的 ABI 解码逻辑：

```
偏移 0x2658:  RETURNDATASIZE
              PUSH1 0x20        // 32
              LT                // if returnDataSize < 32
              PUSH2 0x1293      // jump to revert handler
              JUMPI
```

偏移 `0x1293` 处是 `PUSH0, DUP1, REVERT`——无条件 revert。

USDT 的 `transferFrom` 返回 **0 bytes**（`RETURNDATASIZE = 0`），永远满足 `0 < 32` 条件，因此 **Router04 对 USDT 的任何 transferFrom 调用都会 revert**。这不是合约逻辑 bug，而是 Solidity 0.8.x 的 ABI 解码器对标准 ERC20 返回值的强制要求。

### 理论上可行的替代方案

**方案 A：绕过 Router，直接利用 Permit2**

Router04 内部使用 Uniswap 的 Permit2 合约（`0x000000000022D473030F116dDEE9F6B43aC78BA3`）来执行 `transferFrom`。Permit2 支持两种模式：

| 模式 | 接口 | 要求 |
|---|---|---|
| SignatureTransfer | `permitTransferFrom(permit, transferDetails, owner, signature)` | 需要受害者的 **EIP-712 签名** |
| AllowanceTransfer | `transferFrom(from, to, amount, token)` | 需要受害者预先对 Router 设置 **Permit2 Allowance** |

Router04 使用的是 **SignatureTransfer 模式**——需要受害者亲自签署的链下签名，攻击者无法伪造。

而 AllowanceTransfer 模式需要受害者通过 `Permit2.approve(token, spender, amount, expiration)` 授权 Router。链上查询结果：

```
Permit2.allowance(victim, USDT, Router) = (amount: 0, expiration: 0, nonce: 0)
```

受害者从未对 Router 设置过 Permit2 USDT 的 AllowanceTransfer 授权。

**结论：Permit2 两种模式都走不通。**

**方案 B：编写自定义合约直接调用 PoolManager**

绕过 Router04，直接与 PoolManager 交互。但这需要：
1. 自行实现 `IUnlockCallback` 接口
2. 在 callback 中使用 `SafeERC20`（OpenZeppelin 的 `safeTransferFrom`）处理 USDT 的无返回值问题
3. 正确构造 swap 参数和 settle/take 流程

理论上可行，但需要：
- 受害者对攻击者合约（而非 Router）有 USDT 授权——**受害者的 USDT 授权对象是 Router，不是任意合约**
- 或者找到另一个受害者已授权的、存在相同漏洞的合约

**方案 C：利用受害者对 Router 的 USDT 无限授权**

受害者对 Router 的 USDT allowance 确实是 `type(uint256).max`。但问题在于：Router 是中介——攻击者需要通过 Router 来执行 `transferFrom(victim, ..., amount)`，而 Router 的所有 token 转账路径都经过 Solidity ABI 解码器，对 USDT 必然 revert。

**最终结论：在当时的链上状态下，$25,575 USDT 无法通过任何已知路径被窃取。** 原始攻击者 `0xd6B7` 只攻击 USDC 而完全忽略 USDT，说明他充分了解这一限制——这是一个技术成熟的攻击者。

---

## 深入分析二：MEV Bot `0x339c` 为什么总能在区块排序中击败 Copycat `0x475d`？

### 两次竞争的链上数据

#### 区块 #24575718（$90 USDC 竞争）

| 维度 | 竞争者 `0xf33c` | Copycat `0xf957` |
|---|---|---|
| 交易索引 | **0**（第一笔） | 1（第二笔） |
| gasPrice | 4,034,796,658 (≈ baseFee) | 145,000,000,000 (145 Gwei) |
| maxPriorityFeePerGas | **~0 Gwei**（仅付 baseFee） | ~141 Gwei |
| Gas Used | 129,496 | 62,404 |
| 给矿工的 gas tip | ≈ **0 ETH** | 0.009,044 ETH |
| 直接贿赂 | **0.042329 ETH** → builder | 无 |
| 对 builder 的总贡献 | **0.042329 ETH** | 0.009044 ETH |
| 倍率 | **4.68x** | 1x |

#### 区块 #24575872（$82 USDC 竞争）

| 维度 | 竞争者 `0xf33c` | Copycat `0xf957` |
|---|---|---|
| 交易索引 | **0** | 2 |
| gasPrice | baseFee | 145 Gwei |
| 直接贿赂 | **0.039423 ETH** → builder | 无 |
| 对 builder 的总贡献 | **0.039423 ETH** | ~0.009 ETH |
| 倍率 | **4.36x** | 1x |

两个区块的 builder 都是 **Titan Builder**（`0x4838B106FCe9647Bdf1E7877BF73cE8B0BAD5f97`）。

### 竞争者的技术手段：Flashbots-style Private Bundle

竞争者合约 `0x339c` 的关键特征：

```
合约大小:     5,963 bytes（攻击合约的 3 倍）
部署时间:     2025-12-26（攻击前 2+ 个月）
COINBASE 操作码: 8 处引用
```

**COINBASE 操作码**（EVM opcode `0x41`）在运行时动态获取当前区块的 builder/miner 地址。竞争者合约的执行流程：

```
1. 执行 swap 攻击，获得 ~0.045 ETH
2. COINBASE → 获取当前 builder 地址（Titan Builder）
3. 计算贿赂金额 ≈ 收益的 93%
4. 直接向 builder 地址转账 ETH 贿赂
5. 净利润 ≈ 0.003 ETH（仅 ~7%）
```

这就是 **MEV 拍卖机制**的核心：
- 竞争者通过 **Flashbots/MEV-Share 等私有通道** 提交 bundle（交易不进入公共 mempool）
- Bundle 中包含直接给 builder 的贿赂，金额远高于普通 gas tip
- Builder 的利润最大化算法将出价最高的 bundle 排在区块最前面

### Copycat 的致命弱点

```
提交方式:     公共 mempool（所有人可见）
出价机制:     仅 gas tip（145 Gwei × ~62,000 gas ≈ 0.009 ETH）
合约能力:     无 COINBASE 操作码，无 builder 贿赂逻辑
```

Copycat 把交易直接广播到公共 mempool，相当于：
1. **暴露意图** — 竞争者的监控系统可以看到 copycat 的交易并抢先
2. **出价太低** — 0.009 ETH 的 gas tip vs 竞争者 0.042 ETH 的直接贿赂，builder 当然选择后者
3. **没有原子性保证** — 公共 mempool 交易可以被任意重排，而 bundle 可以指定严格的执行顺序

### 经济学分析

竞争者的利润分配：

```
区块 #24575718:
  USDC 获取:   $90.13
  swap 所得:   ~0.045 ETH
  builder 贿赂: 0.042 ETH (93.2%)
  净利润:      ~0.003 ETH (~$7)

区块 #24575872:
  USDC 获取:   $82.69
  swap 所得:   ~0.042 ETH
  builder 贿赂: 0.039 ETH (93.5%)
  净利润:      ~0.003 ETH (~$6)
```

竞争者愿意把 **93%+ 的利润** 直接给 builder，只保留极少的净利润。这是成熟 MEV bot 的典型策略——在激烈竞争中，纳什均衡趋近于将几乎全部 MEV 价值让渡给 builder，searcher 只保留微利。

### 三方能力对比总结

| 能力维度 | 原始攻击者 `0xd6B7` | 竞争者 `0xf33c` | Copycat `0xf957` |
|---|---|---|---|
| ERC20 兼容性理解 | 深入（只攻击 USDC） | 未知（未尝试 USDT） | 不了解（先试 USDT 失败） |
| MEV 基础设施 | 私有 bundle + builder 贿赂 | 私有 bundle + COINBASE 贿赂 | **公共 mempool** |
| 合约复杂度 | 1,924 bytes | 5,963 bytes（专业 MEV bot） | 1,925 bytes（原样复制） |
| 部署时间 | 攻击前 2 分钟 | 攻击前 2 个月 | 攻击后 25 分钟 |
| 策略 | 一击制胜，42,606 USDC | 持续监控残渣 | 反复尝试后放弃 |
| 总收益 | **~$42,606** | **~$172** | **$0** |

Copycat 的根本问题不是合约代码——模拟证明合约在有 USDC 的状态下完全可用——而是缺乏 MEV 竞争的核心基础设施：私有 bundle 提交、builder 贿赂机制、和动态出价策略。在 2025 年的以太坊 MEV 生态中，公共 mempool + 固定 gas price 的方式已经完全无法与专业 MEV bot 竞争。

---

## 深入分析三：漏洞是否仍然存在？攻击者能否继续发起类似攻击？

> 分析时间：2026-04-22，基于区块 #24935826 的链上状态。

### 结论：漏洞 100% 仍然存在于链上

#### 链上铁证

| 验证项 | 结果 |
|---|---|
| Router04 bytecode | **未变**（20,951 hex chars，与攻击时完全一致） |
| `swap(bytes,uint256)` selector `0xaf2b4aba` | **仍存在于 bytecode 中** |
| 函数是否可调用 | **是**（调用时 revert 是参数错误，非 function not found） |
| 合约是否可升级（Proxy） | **否**（EIP-1967 proxy slot 为零，非代理合约） |
| 合约是否可自毁 | **否**（Solidity 0.8.x 编译，且 Cancun 后 `SELFDESTRUCT` 不再删除代码） |

**关键事实：以太坊上已部署的合约代码不可修改。** z0r0z 在 GitHub 删除了 `swap(bytes,uint256)` 的源码，但链上的 bytecode 永远不会因为 GitHub commit 而改变。Router04 不是代理合约，没有 admin 可以升级或禁用任何函数。

### 攻击仍可复现的条件

漏洞利用需要两个条件同时满足：

```
条件 1: 受害者对 Router04 有 ERC20 token 的 approve（allowance > 0）
条件 2: 受害者持有该 token 的余额（balance > 0）
```

### 原始受害者的当前状态——已安全

```
USDC allowance → Router04:  0  （已撤销）
USDT allowance → Router04:  0  （已撤销）
USDC balance:               $8,623
USDT balance:               $2,007
```

原始受害者在攻击后撤销了对 Router04 的所有授权，尽管仍持有资金，但已不再暴露于此漏洞。

### 全量用户风险评估（835/835 完整扫描）

Router04 共有 **835 个历史用户**（8,166 笔交易）。通过 JSON-RPC 批量查询，对**全部 835 个用户**进行了 5 种主流 token（USDC、USDT、WETH、DAI、WBTC）的授权检查（共 4,175 次 `allowance` 查询），并补充检查了已知 meme token（GOYSLOP、maxxing、SATOSHI）的授权情况。

#### 主流 token 全量扫描结果

| Token | 有授权的用户数 | 详情 |
|---|---|---|
| USDC | **2** | `0x654e...`、`0xe2a5...`：均为无限授权，**但 USDC 余额均为 0** |
| USDT | **0** | — |
| WETH | **0** | — |
| DAI  | **0** | — |
| WBTC | **0** | — |

#### Meme token 补充检查结果

| Token | 有授权的用户数 | 详情 |
|---|---|---|
| GOYSLOP | **2** | `0xb00bb1...`、`0xb00b486a...`：均为无限授权，**但余额均为 0** |
| maxxing | **0** | — |
| SATOSHI | **0** | — |

#### 结论

**835 个用户中，仅 4 个持有活跃授权，但全部 4 个的对应 token 余额为零。当前无任何用户处于实际风险中。**

| 指标 | 数值 |
|---|---|
| 总用户数 | 835 |
| 总查询次数 | 4,175+（主流 token）+ meme token 补充 |
| 有授权的用户 | 4（2 USDC + 2 GOYSLOP） |
| 有授权且余额 > 0（AT RISK） | **0** |

但需注意：这只是当前时刻的快照。如果未来这 4 个有授权的地址收到对应 token，或者新用户对 Router04 进行 approve，风险将重新出现。

### 新版函数的用户同样面临风险

Router04 当前活跃使用的函数是 `swapExactTokensForTokens`（`0xb1a0d571`）和 `swapTokensForExactTokens`（`0xaacdd80f`）。链上验证显示，**这些新函数也要求用户直接 approve token 给 Router04**：

```
用户 0xb00bb1 → 对 Router04 的 GOYSLOP allowance = type(uint256).max
（该授权用于 swapExactTokensForTokens 函数）

用户 0xb00b486a → 对 Router04 的 GOYSLOP allowance = type(uint256).max
（同上）
```

这意味着：任何通过新版函数使用 Router04 的用户，其 token 授权同样可被旧版 `swap(bytes,uint256)` 漏洞利用——**因为 ERC20 授权是针对地址的，不区分函数。**

### 攻击如何实现

假设发现某用户 X 对 Router04 持有 token T 的无限授权，且有 N 个 token T 余额：

```
1. 部署攻击合约（与原始攻击完全相同的模式）
2. 查询受害者余额和授权:
     amount = min(T.balanceOf(X), T.allowance(X, Router04))
3. 构造恶意 calldata，利用 calldataload(164) 绕过 caller 校验:
     - 在 calldata 偏移 164 处放置 address(this)（攻击合约地址）
     - 在 BaseData.payer 中放置受害者地址 X
     - Router 会调用 T.transferFrom(X, PoolManager, amount)
4. 调用 Router04.swap(malicious_calldata, block.timestamp)
5. PoolManager 将 swap 所得的 ETH 发送给攻击者 EOA
```

**前提条件**：token T 必须在 Uniswap V4 上有对应的流动性池（ETH/T pair），否则 swap 无法完成。

### 为什么 GitHub 修复无效

```
GitHub 仓库（源码）  ──[删除 swap 函数]──→  已修复 ✓
           ↓ 编译部署（2024年）
链上合约（bytecode）  ──[不可变]──→           仍存在漏洞 ✗
```

**唯一的真正修复方式**：所有曾对 Router04 approve 过 token 的用户，必须主动撤销授权（调用 `token.approve(Router04, 0)`）。这需要项目方通知所有受影响用户。

### 总结

| 问题 | 回答 |
|---|---|
| 漏洞是否已修复？ | **链上未修复**，仅 GitHub 源码删除 |
| 攻击者能否继续攻击？ | **理论上可以**，只要找到有授权 + 余额的用户 |
| 当前实际风险？ | **低**——全量扫描 835 个用户，仅 4 个有授权且余额均为 0，当前无人处于风险中 |
| 潜在风险？ | 4 个有授权地址若收到 token、或新用户 approve Router04，风险将重新出现 |
| 根本解决方案？ | 用户撤销对 Router04 的 token 授权；项目方应发布安全公告 |
