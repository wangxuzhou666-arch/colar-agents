#!/usr/bin/env python3
"""bash_pitfall_guard 规则 7 的判定器：zsh 把未加花括号的 $NAME:<字母> 当修饰符吃掉。

stdin 喂整条 Bash 命令；命中时 stdout 打印一行 "NAME 字母"（第一处），未命中不输出、退出码 0。

机制：zsh 对未加花括号的参数展开，会把紧随其后的 ":" + 修饰符字母解析成历史式修饰符，
双引号里照吃。实证 2026-10-06：`git push origin "refs/heads/$b:refs/heads/$b"` 里的 `:r`
（去扩展名）被吞，展开成 refs/heads/feat/xefs/heads/feat/x，15 次 push 全败。
修法永远是 ${NAME}:… ；若本意就是用修饰符，写 ${NAME:t}。

字母表：a c e h l q r s t u A P Q 在 /bin/zsh 实测会吃（2026-10-06）；g / x 取自 zsh 手册
（需后续参数才有可见效果，未单独实测）。刻意不含 `&`：`$a:&&` 这类形状有歧义。
NAME 必须以字母或下划线开头，所以 $1:x / $HOST:8080 / $PATH:/usr/bin / $HOST:$PORT 天然不命中。

引号处理：单引号内整段跳过（awk / perl / sed 脚本里的 $x:y 不是 shell 展开）；
双引号内不跳过（事故现场就在双引号里）；反斜杠转义的 \\$ 跳过。
已知边界（宁漏勿误）：
  - 单引号不平衡 → 放行，不猜
  - "$(awk '{print $x:y}')" 这类双引号内嵌命令替换里的单引号，会被当成普通字符 → 可能误报
  - heredoc 正文也在被扫的串里（与 guard 其余规则同一已知限制）
  - 刻意使用的 $f:t（取文件名）惯用法也会被拦；提示里已给 ${f:t} 的写法

自证测试：bash scripts/hooks/tests/test_bash_pitfall_guard.sh
"""
import re
import sys

MODIFIER_REF = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*):([htrelquQaAcsgxP])")


def first_hit(cmd):
    """第一处 (NAME, 字母)，没有返回 None。"""
    in_double = False
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if c == "\\":
            i += 2
        elif c == "'" and not in_double:
            close = cmd.find("'", i + 1)
            if close < 0:
                return None
            i = close + 1
        else:
            if c == '"':
                in_double = not in_double
            elif c == "$":
                m = MODIFIER_REF.match(cmd, i)
                if m:
                    return m.group(1), m.group(2)
            i += 1
    return None


def main():
    hit = first_hit(sys.stdin.read())
    if hit:
        print(*hit)


if __name__ == "__main__":
    main()
