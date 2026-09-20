#!/usr/bin/env bash
# nul_byte_guard.sh 的判别力自证：含 NUL 的文本文件必须 exit 2 + 出 stderr，
# 干净文件 / 非白名单扩展名 / 文件缺失 / stdin 坏掉必须 exit 0 且零输出（fail-open 是本 guard 的哲学）。
#
# 跑法：bash scripts/hooks/tests/test_nul_byte_guard.sh
# 变异验证：GUARD=<改坏一条规则的副本> bash 本脚本 → 对应用例必须转红，否则该用例没有判别力。
#
# ⚠️ 最后一组 "W" 是【接线口径】自证，不是内容规则：本 guard 扫的是磁盘上的文件、不是 payload
#    里的 content，所以它只有接在 PostToolUse 才有效。接 PreToolUse 时磁盘还是写入前的状态 ——
#    新建场景文件不存在、覆盖场景读到旧内容，两种都放过。W 组把这条失效路径钉死，
#    防止后来人又把它挪回 PreToolUse（2026-09-20 实测发现的原始坑）。
#
# 两条写法上的注意：
#   1) stdin 一律走临时文件重定向而不是管道 —— 管道后取 $? 既脆也会被 bash_pitfall_guard 拦。
#   2) 夹具里的 NUL 用字面量 @NUL@ 占位、由 python 换成 chr(0)，源码里一个 NUL 转义序列都不出现 ——
#      免得被某个上游工具再求值一次，把本该干净的用例弄脏。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD=${GUARD:-$HERE/../nul_byte_guard.sh}
pass=0
fail=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STDIN_FILE="$TMP/.stdin.json"
OUT_FILE="$TMP/.stderr.txt"

# 造夹具文件：$1 落点 · $2 内容（其中 @NUL@ 会被换成真正的 0x00）
make_file() {
  python3 -c 'import sys; open(sys.argv[1],"wb").write(sys.argv[2].replace("@NUL@", chr(0)).encode("utf-8"))' "$1" "$2"
}

# 把 PostToolUse stdin JSON 写进 STDIN_FILE：$1 file_path · $2 tool_name
# 字段形状取自 2026-09-20 对真实 PostToolUse payload 的实测（Write / Edit 都带 tool_input.file_path）
build_payload() {
  python3 -c '
import json, sys
open(sys.argv[3], "w").write(json.dumps({
    "hook_event_name": "PostToolUse",
    "tool_name": sys.argv[2],
    "tool_input": {"file_path": sys.argv[1], "content": "irrelevant"},
    "tool_response": {"type": "create", "filePath": sys.argv[1]},
}))' "$1" "$2" "$STDIN_FILE"
}

RC=0
MSG=""
# 跑一次 guard，结果落进全局 RC / MSG（不进管道，$? 才干净）
run_guard() {
  build_payload "$1" "${2:-Write}"
  RC=0
  bash "$GUARD" < "$STDIN_FILE" > "$OUT_FILE" 2>&1 || RC=$?
  MSG=$(head -1 "$OUT_FILE")
}

expect_catch() {
  # $1 标签 · $2 file_path · $3 stderr 必含的片段（把命中钉到具体反馈语，防止靠空输出蒙混）· $4 tool_name
  run_guard "$2" "${4:-Write}"
  if [ "$RC" = "2" ] && grep -qF -- "$3" "$OUT_FILE"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[catch] $1"
    echo "   path: $2"
    echo "   got : exit=$RC stderr=${MSG:-<empty>}"
  fi
}

expect_pass() {
  # $1 标签 · $2 file_path · $3 tool_name —— 必须 exit 0 且一个字都不输出
  run_guard "$2" "${3:-Write}"
  if [ "$RC" = "0" ] && [ -z "$MSG" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[pass] $1"
    echo "   path: $2"
    echo "   got : exit=$RC stderr=${MSG:-<empty>}"
  fi
}

expect_pass_raw() {
  # $1 标签 · $2 原样 stdin（测 stdin 本身坏掉时的 fail-open）
  printf '%s' "$2" > "$STDIN_FILE"
  RC=0
  bash "$GUARD" < "$STDIN_FILE" > "$OUT_FILE" 2>&1 || RC=$?
  MSG=$(head -1 "$OUT_FILE")
  if [ "$RC" = "0" ] && [ -z "$MSG" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL[pass] $1"
    echo "   got : exit=$RC stderr=${MSG:-<empty>}"
  fi
}

FEEDBACK="NUL 控制字符"

# ---- 真阳性：白名单扩展名的文本文件里混进 NUL ----
make_file "$TMP/dirty.md"   '# doc@NUL@tail'
expect_catch "TP1 .md 含 NUL"              "$TMP/dirty.md"   "$FEEDBACK"
make_file "$TMP/dirty.json" '{"k": "v@NUL@"}'
expect_catch "TP2 .json 含 NUL"            "$TMP/dirty.json" "$FEEDBACK"
make_file "$TMP/dirty.ts"   'export const a = 1;@NUL@'
expect_catch "TP3 .ts 含 NUL"              "$TMP/dirty.ts"   "$FEEDBACK"
# Edit 与 Write 走同一条路径（PostToolUse 下两者 tool_input 形状一致，2026-09-20 实测）
expect_catch "TP4 Edit 触发同样命中"       "$TMP/dirty.md"   "$FEEDBACK" "Edit"

# ---- 真阴性：干净文件不许误报 ----
make_file "$TMP/clean.md" '# doc
tail'
expect_pass "TN1 .md 纯 ASCII 干净"        "$TMP/clean.md"
# 中文多字节：防"非 ASCII 一律当二进制"这类过度收紧的变异
make_file "$TMP/cn.md" '# 中文标题
正文含全角标点，。！'
expect_pass "TN2 .md UTF-8 中文干净"       "$TMP/cn.md"
make_file "$TMP/emoji.md" '状态 ✅ 完成 🚀'
expect_pass "TN3 .md emoji 干净"           "$TMP/emoji.md"
# 非白名单扩展名即便含 NUL 也跳过（PNG 本来就该有 NUL，扫了必误报）
make_file "$TMP/img.png" 'PNG@NUL@@NUL@@NUL@IHDR'
expect_pass "TN4 .png 含 NUL 但非白名单"   "$TMP/img.png"
make_file "$TMP/noext" 'binary@NUL@blob'
expect_pass "TN5 无扩展名含 NUL 跳过"      "$TMP/noext"

# ---- fail-open：任何不确定一律放行 ----
expect_pass     "FO1 文件不存在"           "$TMP/does_not_exist.md"
expect_pass     "FO2 file_path 为空"       ""
expect_pass_raw "FO3 空 stdin"             ""
expect_pass_raw "FO4 stdin 非 JSON"        "not json at all"
expect_pass_raw "FO5 JSON 但无 tool_input" '{"hook_event_name":"PostToolUse","tool_name":"Write"}'

# ---- W 组：接线口径自证（本 guard 扫磁盘不扫 payload → 只能接 PostToolUse）----
# W1 新建场景的 Pre 态：文件尚未落盘 → 必然放过。不是 bug，是"接错事件就全失效"的证据。
expect_pass  "W1 Pre态·新建(文件还不存在)"   "$TMP/will_be_written.md"
# W2 覆盖场景的 Pre 态：磁盘上还是干净旧内容（payload 里含 NUL 的新内容它看不见）→ 放过
make_file "$TMP/overwrite.md" 'old clean content'
expect_pass  "W2 Pre态·覆盖(磁盘仍是旧内容)" "$TMP/overwrite.md"
# W3 同一文件的 Post 态：写入已落盘 → 必须命中。W2/W3 这对照就是本次迁移的全部理由。
make_file "$TMP/overwrite.md" 'new content with@NUL@ nul'
expect_catch "W3 Post态·同一文件写入后命中" "$TMP/overwrite.md" "$FEEDBACK"

echo "PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ]
