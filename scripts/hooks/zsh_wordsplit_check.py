#!/usr/bin/env python3
"""bash_pitfall_guard 规则 6 的判定器：zsh 不对裸 $VAR 分词。

stdin 喂整条 Bash 命令；命中时 stdout 每行打印一个变量名，未命中不输出、退出码 0。

只拦零歧义的形状：VAR 由「列表型命令替换」赋值（find / fd / ls / git ls-files /
git diff|show|log|status 带 --name-only|--name-status|--porcelain / grep|rg 带 -l|--files），
且随后裸 $VAR 或 ${VAR} 出现在某条命令的参数位。zsh 会把整块多行输出当成 1 个参数。

实证：2026-09-15 织锦 `FILES=$(grep -rlE … | grep -v conftest)` 后 `pytest $FILES`，
30 个路径被当 1 个参数，pytest "no tests ran"；同一条经 bash -c 跑不暴露，
所以 bash 肌肉记忆在这里必错。

刻意放行（有歧义，或在 zsh 里本就是对的）：
  "$VAR" 加了引号（作者明确要单参数）· ${=VAR} / ${(f)VAR}（已显式分词）·
  内联 $(cmd)（zsh 对命令替换会分词）· 数组 VAR=($(cmd)) · echo/printf/[ 等不吃列表的命令 ·
  重定向 <<< $VAR · 单行生产者（git rev-parse / git log -1 等）·
  字面串 VAR="a b"（zsh 里不分词往往正是意图，如 git commit -m $MSG）· setopt shwordsplit 已开

自证测试：bash scripts/hooks/tests/test_bash_pitfall_guard.sh
"""
import re
import sys

# 输出天然一行一个路径的生产者
LIST_PRODUCER = re.compile(
    r"(?:^|[\s;|&(])(?:find|fd)\s"
    r"|(?:^|[\s;|&(])ls(?:\s|$)"
    r"|git\s+ls-files"
    r"|git\s+(?:diff|show|log|status)\b[^|;]*--(?:name-only|name-status|porcelain)"
    r"|(?:^|[\s;|&(])(?:grep|egrep|fgrep|rg)\s(?:[^|;]*\s)?"
    r"(?:-[a-zA-Z]*[lL][a-zA-Z]*|--files-with-matches|--files-without-match|--files)(?:\s|$)"
)
# VAR=$( 或 VAR=`；VAR=( 是数组，不在此列
ASSIGN = re.compile(r"(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=(\$\(|`)")
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")
SEGMENT_SPLIT = re.compile(r"\n|;|&&|\|\||\||\(|\)")
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
REDIRECT = re.compile(r"^\d*(?:<{1,3}|>{1,2})$")
BARE_VAR = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
SHWORDSPLIT_ON = re.compile(r"setopt\s+sh_?word_?split|set\s+-o\s+shwordsplit", re.I)

# 段首这些词不是命令本体，剥掉再看真正的命令字
WRAPPERS = {"noglob", "command", "exec", "time", "nohup", "sudo", "env",
            "then", "do", "else", "done", "fi", "esac", "{", "}"}
# 这些命令吃的是整块文本不是列表，裸 $VAR 反而是对的（echo $FILES | wc -l 数的是行）
NOT_LIST_CONSUMERS = {"echo", "printf", "[", "[[", "test", "case", ":", "true", "false",
                      "return", "exit", "local", "export", "declare", "readonly",
                      "let", "read", "unset"}


def substitution_body(cmd, start, opener):
    """从 start 起取替换体（不含收尾符）；括号不平衡返回 None，不猜。"""
    if opener == "`":
        end = cmd.find("`", start)
        return None if end < 0 else cmd[start:end]
    depth, i, n = 1, start, len(cmd)
    while i < n:
        c = cmd[i]
        if c in "'\"":
            close = cmd.find(c, i + 1)
            if close < 0:
                return None
            i = close + 1
            continue
        if c == "\\":
            i += 2
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return cmd[start:i]
        i += 1
    return None


def list_vars(cmd):
    """由列表型命令替换赋值的变量名集合。"""
    names = set()
    for m in ASSIGN.finditer(cmd):
        body = substitution_body(cmd, m.end(), m.group(2))
        if body is not None and LIST_PRODUCER.search(body):
            names.add(m.group(1))
    return names


def bare_uses(cmd, names):
    """names 里哪些以裸 $VAR / ${VAR} 出现在某条命令的参数位。"""
    hits = []
    bare = QUOTED.sub(" ", cmd)
    for seg in SEGMENT_SPLIT.split(bare):
        tokens = seg.split()
        while tokens and (ENV_ASSIGN.match(tokens[0]) or tokens[0] in WRAPPERS):
            tokens.pop(0)
        if not tokens or tokens[0] in NOT_LIST_CONSUMERS:
            continue
        for prev, tok in zip(tokens, tokens[1:]):
            if REDIRECT.match(prev):
                continue
            m = BARE_VAR.fullmatch(tok)
            if m and m.group(1) in names and m.group(1) not in hits:
                hits.append(m.group(1))
    return hits


def main():
    cmd = sys.stdin.read()
    if SHWORDSPLIT_ON.search(cmd):
        return
    names = list_vars(cmd)
    if not names:
        return
    for name in bare_uses(cmd, names):
        print(name)


if __name__ == "__main__":
    main()
