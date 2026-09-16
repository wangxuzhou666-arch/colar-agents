# Coding Style — 跨项目铁律层

> 读者：写代码的 agent（Senior Developer / Applied AI Engineer）、审代码的 agent（Code Reviewer）、以及 Colar 本人。
> 定位：**审核标准的单一真相源**。reviewer 不得自定阈值——标准在这里，不在模型脑子里（AI 自审自定标准，是本文件要治的洞）。
> 分层：本文件只放跨项目铁律；项目特化（技术栈坑、存量债、具体接线）放各 repo `docs/CODING-STYLE.md`，与本文件是**追加**关系，不是覆盖。
> 靶子：AI 生成代码的四类臃肿（2026-09-15 拍板）——宽 catch 吞错 / 兜底伪装 / 过度抽象 / 空洞注释。其余（命名、import）从简。

## 0. 强制力分档（先看这个）

| 档 | 谁执行 | 何时 | 管什么 |
|---|---|---|---|
| **机械** | ruff 精准档 + 嵌套深度脚本，pre-commit | 每次 commit，**只看 staged 改动行** | 能用规则码 / AST 判定的：BLE / TRY / SIM / RUF100 / 裸 noqa / 深度 ≥5 |
| **判断** | Code Reviewer（L1） | 每次 diff | 需要读上下文才能定的：宽 catch 属不属四类合法 / 抽象有没有第二个实现 / 注释是不是 why |
| **存量** | L2 体检 | 批次 / 里程碑 | 历史债清单（`--all` 报表），集中清，**不进 pre-commit**（天天红 → 被 --no-verify 绕过） |

判据：**每 session 都成立、与任务无关、零歧义 → 机械；否则 → 判断。** 往任一档加条目前先过这道判据。

## P0 · 异常：保护区最小化，宽 catch 必须有身份

**机制**：`try` 一宽，异常就丢失身份——网络超时（可重试）、KeyError（契约破了，是 bug）、写库失败（要告警）折叠成同一句 log。再接一个 `return None`，故障就伪装成"正常返回"，三天后才在数据里被发现。

规则：
1. `try` 块只包**你预期会失败的那一行**；其余逻辑放 `else:` 或 try 之外（ruff TRY300 会提示 return 在 try 里）。
2. `except` 的类型必须**对应一个具体处理动作**。catch 完对什么异常都做同一件事 = 你在抑制，不是处理。
3. `except Exception` 只在四类场景合法，且**行尾必须注明属于哪类 + 理由**：
   - **旁路降级**：脱敏 / 统计 / 埋点等旁路失败不能拖垮主流程
   - **非关键增强**：缺了不影响结论的字段（usage 计数记 0）
   - **批处理单元隔离**：循环内一条坏不能带垮整批（必须 log 该条身份）
   - **顶层 handler**：HTTP 中间件 / worker 最外层，兜住一切以免进程死（必须 `logger.exception` 留 traceback）
4. **裸 `# noqa: BLE001` 不接受**（机械拦）。`# noqa: BLE001 — 批处理单元隔离，单条规则出错不影响其余` 这种才过。
5. `except` 里记日志用 `logger.exception`，不用 `logger.error`（后者丢 traceback；ruff TRY400）。
6. `except: pass` 改 `contextlib.suppress(具体类型)`（ruff SIM105）——它逼你写出类型。

## P0 · 兜底：故障不许伪装成成功

**机制**：`return None` / `or default` / 永远走不到的 `else` 把"出事了"改写成"看起来正常"。这是宽 catch 的另一半——一个负责丢信息，一个负责伪装。

规则：
1. 默认 **fail fast**：程序员错误用 `assert`，坏输入在**边界**（HTTP handler / 配置解析 / 外部数据入口）用 `raise ValueError/TypeError`。内部 helper 假设输入合法，**不重复校验**。
2. 合法降级（上面四类）必须**显式**：有 log、有明确的降级值语义（`token_count = 0  # usage 缺失，探针结论不依赖它`），不是静默 `None`。
3. **不 over-protect**：一个操作 99% 正确，就不要为那 1% 加防御分支。LLM 的本能是加，抵抗它。
4. 判空只在值**真的可能为空**时写。类型标注说了 `str` 就不要 `if s is not None`。

## P1 · 复杂度：嵌套深度是真信号，行数是假信号

**机制**：读代码时工作记忆要维持"我在哪些条件成立的分支里"。深度 N = 最内层那行要同时满足 N 个条件。人类工作记忆 4±1 个 chunk（Cowan 2001）；深度 ≥5 就没人真读懂过，包括写它的人。
而 650 行、36 个**平坦** if 的建表函数，读第 20 个 if 时不需要记得前 19 个——它长，但不复杂。

规则：
1. **主判据：任一行嵌套深度 ≥ 5 → 违规**（机械拦，AST 算 if / for / while / try / with 的层数）。修法按顺序试：guard clause 早返回 → 提取内层为函数 → dispatch dict。
2. **辅判据（只提示）**：函数 >50 行 且 圈复杂度 >15（ruff C901）。数据密集型（DDL / 常量表 / 长字符串占一半以上）豁免。
3. 分支若赋值或返回，必须有 `else`（不完整分支是隐式 None 的来源）；guard clause 例外。

**元规则**：代理指标不能跨领域搬运。"函数 >50 行必拆"在 CUDA kernel 库里够用（长与深高度相关），在 web + 数据管道里会误伤建表函数、漏掉 45 行深度 13 的解析器。别人的 style 拿来前先用自己的仓验一遍。

## P2 · 抽象：一个实现的抽象是套壳

**机制**：抽象的价值 = 它统一了几个**已经存在**的实现。只有一个实现时，它统一的是想象——多出的间接层是纯成本。

规则：
1. 基类 / Protocol / Factory 出现时必须有 **≥2 个真实实现**；否则写具体类，等第二个来了再抽。
2. "以后可能扩展"不是理由；**第三次重复**才是抽的时机。
3. 一次性需求不造 config 层 / 插件机制 / 注册表。
4. 泛名黑名单：`data / result / info / tmp / manager / handler / util` 不带限定词不许用（要 `token_ids` / `decode_result` / `order_handler`）。
5. 对称对不混用：`start/stop` `begin/end` `open/close` `send/recv`（不出现 `start/finish`）。bool 前缀 `is_ / has_ / should_ / can_`（机械拦：`: bool` 注解 / bool 字面量默认值或赋值的名字；惯用旗标 `dry_run / verbose / debug / force / strict / quiet` 豁免；**`use_` 只给 React hooks，Python 里不出现**）。

## P3 · 注释：写 why，不写 what

**机制**：what 已经在代码里；再写一遍是噪音，且淹掉真正需要的 why（为什么不是另一种写法、哪个坑、哪个实测数）。

规则：
1. 禁：`# 初始化变量` / `"""Returns the result."""` / 复述函数名的 docstring。
2. 该写的：非显然的决策（"用 X 不用 Y，因为实测 Z"）、坑（"2026-08-27 实证：…"）、约束（"顺序不能反，外键依赖"）。
3. **注释语言按项目**——中文 OK（本条显式覆盖 sglang guide 的 "Remove Chinese comments"）。
4. 调试残留（`print` / `# TODO 临时` / 注掉的代码）不进 commit。

## R · Reviewer 行为准则

1. **标准来自本文件，不来自你**。不得当场发明阈值；文件没写的，标"无既定标准，建议 X"而不是当违规报。
2. **Never rubber-stamp**：找不到问题时必须说明"为什么这段代码是好的"（哪条规则它做对了），禁止只回 LGTM。
3. **Teaching**：每条 finding 带 why（机制）+ 正确写法，不只报 what。
4. **分级对齐**：P0 → blocker，P1/P2 → should-fix，P3 → nice；与 fabric-loop Phase 4 三级一一对应。
5. **AI 代码探测清单**（命中即按对应 P 条报）：整块逻辑一个 try / 对不会 None 的东西判空 / 一个实现的基类 / 复述代码的 docstring / "以防万一"的 default / 不合本仓惯例的通用样板。
6. **Context matters**：孤立看错的改动，放进系统不变量里可能是对的。先读周边再下判。

## 来源与差异

借自 [zhaochenyang20/sglang-diffusion-routing#32](https://github.com/zhaochenyang20/sglang-diffusion-routing/issues/32)：P0–P4 分级结构、反 over-catch / over-protect、AI 代码探测、never rubber-stamp、命名对称与泛名黑名单、complete branching。
**丢掉的**：整个 P1 性能章（CUDA / torch 专用，web 栈 0% 适用）、"Remove Chinese comments"（与 SOUL 冲突）、"函数 >50 行必拆"作为主判据（见 P1 元规则，被织锦数据推翻）。
