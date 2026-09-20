#!/usr/bin/env bash
# agent_frontmatter_guard.sh 的判别力自证：真阳性必须 exit 2 且提示落在对的字段上，
# 真阴性必须放行（exit 0 且零输出）。
#
# 跑法：bash scripts/hooks/tests/test_agent_frontmatter_guard.sh
# 变异验证：GUARD=<改坏一条判定的副本> bash 本脚本 → 对应用例必须转红，否则用例没有判别力。
#
# 真阴性优先覆盖「最容易被后来人顺手收紧改坏」的那几处放行例外：
#   引号内的色值 #7C3AED · 正文的 # 标题与代码块 · 没有 frontmatter 的 doc 正文里的 --- 分隔线 ·
#   不在 agent 配置目录下的 .md。这些才是误拦的真实入口。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD=${GUARD:-$HERE/../agent_frontmatter_guard.sh}
pass=0
fail=0

WORK=$(mktemp -d)
# Edit 类用例需要盘上有真文件，且路径必须落在 agent 配置目录内才进判定 —— 所以 fixture
# 只能放在本 tests 目录下（它本身就在 colar-agents 里），用点号前缀 + trap 清理，不留残渣。
FIXTURE="$HERE/.tmp_fixture_$$.md"
trap 'rm -rf "$WORK"; rm -f "$FIXTURE"' EXIT

AGENT_PATH=/Users/colar/Desktop/colar-agents/engineering/__hook_fixture__.md
DEPLOYED_PATH=/Users/colar/.claude/agents/__hook_fixture__.md
OUTSIDE_PATH=/Users/colar/Desktop/colar-memory/feedback_hook_fixture.md

# ---- payload 构造（走 python json.dumps，避免手搓引号被中文/# 打乱）----
payload_write() { # $1 路径 · $2 文件内容
  FP="$1" CONTENT="$2" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_name":"Write","tool_input":{
    "file_path": os.environ["FP"], "content": os.environ["CONTENT"]}}))' > "$WORK/p.json"
}

payload_edit() { # $1 路径 · $2 old_string · $3 new_string
  FP="$1" OLD="$2" NEW="$3" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"tool_name":"Edit","tool_input":{
    "file_path": os.environ["FP"], "old_string": os.environ["OLD"],
    "new_string": os.environ["NEW"]}}))' > "$WORK/p.json"
}

# ---- 断言（guard 读文件而非管道，$? 直取 guard 自己的退出码，不经管道）----
assert_deny() { # $1 标签 · $2 reason 必含片段（把拦截钉到具体字段/行，防"被别的判定顺手拦下"冒充通过）
  local out rc
  out=$(bash "$GUARD" < "$WORK/p.json" 2>&1)
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF -- "$2"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[deny] $1"
    echo "   exit: $rc (want 2) / 期待片段: $2"
    echo "   got: ${out:-<空输出=放行>}"
  fi
}

assert_allow() { # $1 标签
  local out rc
  out=$(bash "$GUARD" < "$WORK/p.json" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[allow] $1"
    echo "   exit: $rc (want 0)"
    echo "   got: ${out:-<空>}"
  fi
}

# ============ 真阳性：必须拦 ============

# P1 = 2026-09-20 实测原始形状（engineering-explore.md 当时就是这么写的）
payload_write "$AGENT_PATH" $'---\nname: Explore\nmodel: sonnet  # 2026-09-20 覆盖内置 Explore（内置自带 opus）。\n---\n\n正文\n'
assert_deny "P1 原始实例 model: sonnet  # 注释" "model"

# P2 值带引号、注释在引号外 —— 「先剥引号再找 #」的写法会漏掉它，所以必须钉住
payload_write "$AGENT_PATH" $'---\nmodel: "sonnet" # 顺手解释一句\n---\n正文\n'
assert_deny "P2 引号值 + 引号外注释" "model"

# P3 色值 + 真注释同行：引号内的 # 要跳过，引号外的 # 照拦
payload_write "$AGENT_PATH" $'---\ncolor: "#7C3AED"  # 品牌紫\nmodel: opus\n---\n正文\n'
assert_deny "P3 色值后面还有真注释" "color"

# P4 description 字段（路由合同，中招会把注释混进路由文本）
payload_write "$AGENT_PATH" $'---\nname: X\ndescription: 处理前端任务 # 待补充排他条款\n---\n正文\n'
assert_deny "P4 description 行内注释" "description"

# P5 部署位（~/.claude/agents）也在判定范围内
payload_write "$DEPLOYED_PATH" $'---\nmodel: haiku # 省钱\n---\n正文\n'
assert_deny "P5 ~/.claude/agents 路径同样拦" "model"

# P6 Edit 路径：只看 new_string 判不出落不落在 frontmatter 区，必须套用替换后重建全文再扫
cat > "$FIXTURE" <<'EOF'
---
name: Fixture
model: opus
---

# 正文标题
内容
EOF
payload_edit "$FIXTURE" "model: opus" "model: sonnet  # 降档省钱"
assert_deny "P6 Edit 把干净行改成带注释行" "model"

# ============ 真阴性：必须放行 ============

# N1 用户实际采用的修法：注释另起一行
payload_write "$AGENT_PATH" $'---\nname: Explore\nmodel: sonnet\n# 2026-09-20 覆盖内置 Explore（内置自带 opus）。\n---\n\n正文\n'
assert_allow "N1 注释另起一行"

# N2 硬需求：specialized/idea-vc-critic.md:4 的真实写法，色值不是注释
payload_write "$AGENT_PATH" $'---\nname: VC 模型 Critic\ncolor: "#7C3AED"\nemoji: 🧪\nmodel: opus\n# 2026-09-18 显式钉死\n---\n\n正文\n'
assert_allow "N2 color: \"#7C3AED\" 色值放行"

# N3 正文的 # 标题、列表、代码块一律与 frontmatter 无关
payload_write "$AGENT_PATH" $'---\nname: X\nmodel: opus\n---\n\n# 一级标题\n## 二级标题\n\n```bash\ngrep -n "#" file  # shell 注释\n```\n'
assert_allow "N3 正文 # 标题与代码块"

# N4 强判别力：正文代码块里出现一模一样的中招串，但它在 frontmatter 之外 —— 扫描边界必须收住
payload_write "$AGENT_PATH" $'---\nname: X\nmodel: opus\n---\n\n反面教材，别这么写：\n\n```yaml\nmodel: sonnet  # 这样写会炸\n```\n'
assert_allow "N4 正文代码块里的中招串不误拦"

# N5 不在 agent 配置目录下的 .md（memory 语料库），即便 frontmatter 一模一样也不归本 guard 管
payload_write "$OUTSIDE_PATH" $'---\nmodel: sonnet  # 注释\n---\n正文\n'
assert_allow "N5 非 agent 配置路径放行"

# N6 没有 frontmatter 的 doc，正文写着 color: "#hexcode"（CONTRIBUTING.md 的真实形状）
payload_write "/Users/colar/Desktop/colar-agents/CONTRIBUTING.md" $'# Contributing\n\nfrontmatter 字段说明：\n\ncolor: colorname or "#hexcode"\nmodel: sonnet  # 举例说明\n'
assert_allow "N6 无 frontmatter 的 doc 正文"

# N7 钉住「必须第 1 行开界」：正文有 --- 分隔线的 doc，不能被当成 frontmatter 开界符
#     （库里 78 个 .md 有 43 个没有 frontmatter，这是最大的一片误拦面）
payload_write "/Users/colar/Desktop/colar-agents/docs/notes.md" $'# 标题\n\n第一段\n\n---\n\nmodel: sonnet  # 这是正文里的示例，不是配置\n\n---\n\n收尾\n'
assert_allow "N7 正文 --- 分隔线不当 frontmatter"

# N8 Edit 只动正文、不碰 frontmatter
payload_edit "$FIXTURE" "内容" "内容改了 # 顺手加注释"
assert_allow "N8 Edit 只改正文"

# N9 白名单外的字段（契约字段表 = model|name|tools|color|emoji|description）
payload_write "$AGENT_PATH" $'---\nname: X\nmodel: opus\nvibe: 我排第 #1 位\n---\n正文\n'
assert_allow "N9 白名单外字段不管"

# N10 引号内含 # 的长值（route-to-me-when 这类路由声明的常见形状）
payload_write "$AGENT_PATH" $'---\nname: X\ndescription: "触发词含 #frontend 与 #ui，NOT 后端"\nmodel: opus\n---\n正文\n'
assert_allow "N10 引号内含 # 的值"

# N11 非 .md 文件不扫（agent 配置只可能是 .md）
payload_write "/Users/colar/Desktop/colar-agents/scripts/x.sh" $'---\nmodel: sonnet  # 注释\n---\n'
assert_allow "N11 非 .md 放行"

# N12 fail-open：old_string 对不上盘上原文 → Edit 工具自己会报错，不归本 guard 管
payload_edit "$FIXTURE" "这段原文根本不存在" "model: sonnet  # 注释"
assert_allow "N12 old_string 对不上时 fail-open"

# N13 整行只有注释、字段无值 → 不是本坑的形状（对应概念正则里的 \S 要求）
payload_write "$AGENT_PATH" $'---\nname: X\nmodel: # 还没定\n---\n正文\n'
assert_allow "N13 字段无值、整行只有注释"

# N14 钉住「# 前必须是空白」这一条：紧贴在非空白字符后的 # 不是注释（C#、PR#123、颜色名）。
#     没有这条用例时，把 rest[i-1].isspace() 删掉也能全绿 —— 该规则就成了没人守的死规则。
payload_write "$AGENT_PATH" $'---\nname: X\ndescription: 支持 C#-style 命名与 PR#123 引用\nmodel: opus\n---\n正文\n'
assert_allow "N14 紧贴非空白的 # 不算注释"

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
