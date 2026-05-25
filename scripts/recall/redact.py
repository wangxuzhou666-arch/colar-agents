"""Secret + PII redaction for recall infra.

入库前 (index.py) + 输出前 (recall.py) 两层兜底。
"""
import re

# 按 specificity 倒序 — 更精确的 pattern 先匹配
SECRET_PATTERNS = [
    # API keys 形态明显的先匹配 (避免被通用 password pattern 截胡)
    (re.compile(r'sk-ant-[a-zA-Z0-9_\-]{20,}'), '[REDACTED_ANTHROPIC]'),
    (re.compile(r'sk-proj-[a-zA-Z0-9_\-]{20,}'), '[REDACTED_OPENAI_PROJ]'),
    (re.compile(r'sk-[a-zA-Z0-9]{20,}'), '[REDACTED_OPENAI]'),
    (re.compile(r'ghp_[a-zA-Z0-9]{36}'), '[REDACTED_GH_PAT]'),
    (re.compile(r'gho_[a-zA-Z0-9]{36}'), '[REDACTED_GH_OAUTH]'),
    (re.compile(r'github_pat_[a-zA-Z0-9_]{82,}'), '[REDACTED_GH_PAT_NEW]'),
    (re.compile(r'AIza[0-9A-Za-z_\-]{35}'), '[REDACTED_GOOGLE]'),
    (re.compile(r'AKIA[0-9A-Z]{16}'), '[REDACTED_AWS]'),
    (re.compile(r'sbp_[a-zA-Z0-9]{40}'), '[REDACTED_SUPABASE]'),  # Supabase access token
    (re.compile(r'xox[baprs]-[a-zA-Z0-9\-]{10,}'), '[REDACTED_SLACK]'),
    (re.compile(r'glpat-[a-zA-Z0-9_\-]{20,}'), '[REDACTED_GITLAB]'),
    (re.compile(r'shpat_[a-fA-F0-9]{32}'), '[REDACTED_SHOPIFY]'),
    (re.compile(r'rk_[live|test]_[a-zA-Z0-9]{24,}'), '[REDACTED_STRIPE]'),
    (re.compile(r'(?<![a-zA-Z0-9])(?:re_|resend_)[a-zA-Z0-9_]{30,}'), '[REDACTED_RESEND]'),
    # JWT (eyJ...3-segment base64)
    (re.compile(r'eyJ[a-zA-Z0-9_\-]{20,}\.eyJ[a-zA-Z0-9_\-]{20,}\.[a-zA-Z0-9_\-]+'), '[REDACTED_JWT]'),
    # 通用 KEY=VALUE 形式 (放最后, 怕误伤)
    (re.compile(r'(?i)\b(api[_-]?key|access[_-]?token|secret[_-]?key|auth[_-]?token|bearer)\b\s*[:=]\s*["\']?([a-zA-Z0-9_\-\.]{16,})["\']?'),
     r'\1=[REDACTED]'),
]

PII_PATTERNS = [
    (re.compile(r'\b[\w.+\-]+@[\w\-]+\.[\w.\-]+\b'), '[EMAIL]'),
    # SSN 形式 (XXX-XX-XXXX)
    (re.compile(r'\b\d{3}-\d{2}-\d{4}\b'), '[SSN_LIKE]'),
    # 信用卡形式 (13-19 位连续/分隔数字)
    (re.compile(r'\b(?:\d[ \-]?){13,19}\b'), '[CARD_LIKE]'),
]

# 命中即整条 tool_result 跳过 (Bash command 探测)
DANGEROUS_BASH_PATTERNS = [
    re.compile(r'\b(cat|head|tail|less|more|bat|view)\s+[^|;&]*\.env'),
    re.compile(r'\bprintenv\b'),
    re.compile(r'\benv\s*$'),
    re.compile(r'\bsecurity\s+find-generic-password'),
    re.compile(r'\bdefaults\s+read\s+[^|;&]*(secret|key|password|token)', re.I),
    re.compile(r'\b1password\b', re.I),
    re.compile(r'gpg\s+--decrypt'),
]


def redact_secrets(text: str) -> str:
    """入库 / 输出前过一遍 secret pattern."""
    if not isinstance(text, str): return text
    for pat, repl in SECRET_PATTERNS:
        text = pat.sub(repl, text)
    return text


def redact_pii(text: str) -> str:
    """recall.py 输出时额外过 PII (邮箱 / SSN / 卡)."""
    if not isinstance(text, str): return text
    for pat, repl in PII_PATTERNS:
        text = pat.sub(repl, text)
    return text


def is_dangerous_bash(command: str) -> bool:
    """检测 Bash command 是否可能 dump .env / keychain."""
    if not isinstance(command, str): return False
    return any(p.search(command) for p in DANGEROUS_BASH_PATTERNS)


def redact_full(text: str, include_pii: bool = False) -> str:
    """入库默认只 redact secret; 输出可加 PII."""
    text = redact_secrets(text)
    if include_pii: text = redact_pii(text)
    return text
