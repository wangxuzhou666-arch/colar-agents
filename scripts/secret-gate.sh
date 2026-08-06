#!/usr/bin/env bash
# secret-gate.sh — 确定性 secret 扫描 gate（/ship Step 1 的实体，不靠模型肉眼读 diff）
#
# Usage:   bash secret-gate.sh [repo_path]     # 默认 cwd 所在 repo
# Scans:   staged 内容（git diff --cached 的文件全量 blob）+ untracked 新文件 + 高危文件名
# Exit:    0 = clean · 1 = 命中（打印 文件:行 + 规则名 + 前4字符打码，绝不输出完整值）· 2 = 环境错误
#
# 规则来源（已吸收，勿在 ship.md 里重复维护 prose 版）：
#   - ship.md Step 1 原 inline grep：AIza / sk- / ghp_ / xox / PRIVATE KEY / .env|.pem|.key|.p8|credential|id_rsa|service account
#   - colar-memory feedback_env_file_secret_handling.md（2026-05-11 .env.local 事故）：
#     .env* 全家 / secrets.json / credentials.json / auth.json / .netrc / .npmrc(_authToken) /
#     ssh private key / SUPABASE_ 前缀 env 赋值（事故实体：SERVICE_ROLE_KEY 被 tail 泄漏，值为 sb_secret 前缀）
#   - 新增：AKIA(AWS) / github_pat_ / sb_secret_ / password|passwd|secret|token 带引号赋值
#
# 设计注记：
#   - 文件名规则用精确命名惯例而非 "路径含 secret" 宽泛子串 —— 否则本脚本自身（secret-gate.sh）会自我命中。
#   - 内容 pattern 的写法刻意避免自我匹配（如 PRIVATE KEY 用 {0,20} 量词而非 .*），本脚本入库可安全被自己扫。
#   - .env.example / .env.sample / .env.template 按惯例放行（placeholder，无真值）。

set -u

REPO="${1:-$PWD}"
ROOT=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || { echo "secret-gate: not a git repo: $REPO" >&2; exit 2; }
cd "$ROOT" || exit 2

HITS=0
TMP=$(mktemp) || exit 2
trap 'rm -f "$TMP"' EXIT

# ---------- 内容规则（NAMES/PATTERNS 平行数组，兼容 macOS bash 3.2）----------
Q="[\"']"
NQ="[^\"']"
RULE_NAMES=(
  "aws-access-key-id"
  "sk-api-key(openai/anthropic/stripe)"
  "github-token"
  "slack-token"
  "google-api-key"
  "private-key-block"
  "supabase-secret-key"
  "supabase-env-assignment"
  "npmrc-auth-token"
  "password-or-secret-assignment"
)
RULE_PATTERNS=(
  'AKIA[0-9A-Z]{16}'
  'sk-[A-Za-z0-9_-]{20,}'
  'gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'AIza[0-9A-Za-z_-]{35}'
  '-----BEGIN[A-Z ]{0,20}PRIVATE KEY'
  'sb_secret_[A-Za-z0-9_-]{10,}'
  'SUPABASE_[A-Z_]+[[:space:]]*=[[:space:]]*[^[:space:]]+'
  '_authToken[[:space:]]*='
  "I:(password|passwd|secret|token)${Q}?[[:space:]]*[:=][[:space:]]*${Q}${NQ}{4,}${Q}"
)

# ---------- 文件名规则（name:regex）----------
FNAME_RULES=(
  'env-file:(^|/)\.env(\.[A-Za-z0-9_.-]+)?$'
  'key-material:\.(pem|key|p8|p12|pfx|jks|keystore)$'
  'ssh-private-key:(^|/)id_(rsa|dsa|ecdsa|ed25519)$'
  'credential-file:(^|/)(credentials?|secrets?|auth)\.(json|ya?ml|toml|xml|txt|env)$'
  'service-account-json:service[-_.]?account[^/]*\.json$'
  'netrc:(^|/)\.netrc$'
  'aws-credentials:(^|/)\.aws/credentials$'
)

report_content() { # $1=display $2=line $3=rule $4=match（只打前4字符）
  printf 'HIT  %s:%s  [%s]  %.4s****\n' "$1" "$2" "$3" "$4"
  HITS=$((HITS+1))
}
report_fname() { # $1=display $2=rule
  printf 'HIT  %s  [filename:%s]\n' "$1" "$2"
  HITS=$((HITS+1))
}

check_filename() { # $1=repo 相对路径
  local f="$1" entry rn rp
  for entry in "${FNAME_RULES[@]}"; do
    rn="${entry%%:*}"; rp="${entry#*:}"
    if printf '%s\n' "$f" | grep -qE -- "$rp"; then
      # placeholder 惯例放行
      if [ "$rn" = "env-file" ] && printf '%s\n' "$f" | grep -qE '\.env\.(example|sample|template)$'; then
        continue
      fi
      report_fname "$f" "$rn"
    fi
  done
}

scan_content() { # $1=display 名 $2=可读文件路径
  local display="$1" path="$2" i=0 pat flags ln m
  for pat in "${RULE_PATTERNS[@]}"; do
    flags="-nIoE"
    case "$pat" in I:*) pat="${pat#I:}"; flags="-nIoiE" ;; esac
    while IFS=: read -r ln m; do
      [ -n "$ln" ] || continue
      report_content "$display" "$ln" "${RULE_NAMES[$i]}" "$m"
    done < <(grep $flags -- "$pat" "$path" 2>/dev/null)
    i=$((i+1))
  done
}

# ---------- 1) staged 文件：文件名 + staged blob 全量内容 ----------
while IFS= read -r -d '' f; do
  check_filename "$f"
  if git show ":$f" > "$TMP" 2>/dev/null; then
    scan_content "staged:$f" "$TMP"
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR -z)

# ---------- 2) untracked 新文件：文件名 + 工作区内容 ----------
while IFS= read -r -d '' f; do
  check_filename "$f"
  [ -f "$f" ] || continue
  if [ "$(wc -c < "$f")" -gt 5242880 ]; then
    echo "SKIP (>5MB, 内容未扫): $f"
    continue
  fi
  scan_content "untracked:$f" "$f"
done < <(git ls-files --others --exclude-standard -z)

# ---------- 收尾 ----------
if [ "$HITS" -gt 0 ]; then
  echo "secret-gate: BLOCKED — ${HITS} hit(s)。禁止 commit；值已打码（前4字符），完整值绝不入 chat/log。"
  exit 1
fi
echo "secret-gate: clean（staged + untracked 已扫）"
exit 0
