#!/usr/bin/env python3
"""bash_pitfall_guard 判定器共用的 shell 切词：把整条 Bash 命令切成一个个简单命令，找出真正的命令词。

使用方：docker_prune_check.py（规则 8）、git_safety_check.py（规则 9）。
入口 first_hit(cmd, leaf)：对每个简单命令调用 leaf(命令词 basename, 其后的词, 赋值前缀集合)，
返回第一个非空结果；bash|sh|zsh -c '<脚本>' 与 eval 的脚本递归检查。

切词口径（宁漏勿误，与 guard 其余规则一致）：
  - 引号内是字面量；双引号整段视为字面量，所以 "$(cmd)" 这类双引号内的命令替换不检查
  - 在 ; && || | & 换行 $( ) ` 处断开；注释与 heredoc 正文跳过；反斜杠换行是续行
  - 引号不平衡 → 不切（调用方放行），不猜
  - 命令词前的 VAR=… 赋值、if / do / ! 等保留字、sudo / env / xargs / nice / timeout 包装都跳过；
    赋值词收进集合交给 leaf（放行前缀 ALLOW_*=1 就靠它，也认 sudo / env 之后的赋值）
  - ssh host '…' 是远端命令、用变量间接调用（d=docker; $d rmi x）都不检查
"""
import re

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SHELL_C = re.compile(r"-[A-Za-z]*c[A-Za-z]*")    # bash -c / -lc / -ec

# 只是前缀、真正的命令词在后面的保留字
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{",
            "time", "exec", "command", "builtin", "nohup", "noglob"}
# 包装命令 → 它们那些「后面跟一个值」的选项（值不能被误当成命令词）
WRAPPERS = {
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U"},
    "env": {"-u", "-C", "-S"},
    "nice": {"-n"},
    "xargs": {"-n", "-I", "-L", "-P", "-s", "-d", "-E", "-a"},
    "timeout": {"-s", "-k"},
}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
MAX_DEPTH = 3


def skip_heredoc_bodies(cmd, i, heredocs):
    """从 i（某个换行之后）起跳过排队中的 heredoc 正文，返回正文结束后的位置。"""
    for delim, strip_tabs in heredocs:
        while i < len(cmd):
            nl = cmd.find("\n", i)
            line = cmd[i:] if nl < 0 else cmd[i:nl]
            i = len(cmd) if nl < 0 else nl + 1
            if (line.lstrip("\t") if strip_tabs else line) == delim:
                break
    return i


def split_segments(cmd):
    """把命令串切成简单命令的词列表；引号内是字面量，注释与 heredoc 正文跳过。
    引号不平衡返回 None（调用方放行）。"""
    segments, words, word = [], [], []
    has_word = False
    heredocs = []
    i, n = 0, len(cmd)

    def end_word():
        nonlocal word, has_word
        if has_word:
            words.append("".join(word))
        word, has_word = [], False

    def end_segment():
        nonlocal words
        end_word()
        if words:
            segments.append(words)
        words = []

    while i < n:
        c = cmd[i]
        if c == "\\":
            if i + 1 < n and cmd[i + 1] != "\n":  # 反斜杠换行 = 续行，直接吞掉
                word.append(cmd[i + 1])
                has_word = True
            i += 2
        elif c == "'":
            close = cmd.find("'", i + 1)
            if close < 0:
                return None
            word.append(cmd[i + 1:close])
            has_word = True
            i = close + 1
        elif c == '"':
            j, buf = i + 1, []
            while j < n and cmd[j] != '"':
                if cmd[j] == "\\" and j + 1 < n:
                    buf.append(cmd[j + 1])
                    j += 2
                else:
                    buf.append(cmd[j])
                    j += 1
            if j >= n:
                return None
            word.append("".join(buf))
            has_word = True
            i = j + 1
        elif c == "#" and not has_word:
            nl = cmd.find("\n", i)
            i = n if nl < 0 else nl
        elif c == "\n":
            end_segment()
            i = skip_heredoc_bodies(cmd, i + 1, heredocs)
            heredocs = []
        elif c in " \t":
            end_word()
            i += 1
        elif cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            end_word()
            j = i + 2
            strip_tabs = j < n and cmd[j] == "-"
            if strip_tabs:
                j += 1
            while j < n and cmd[j] in " \t":
                j += 1
            delim = []
            while j < n and cmd[j] not in " \t\n;&|<>()":
                ch = cmd[j]
                if ch in "'\"":
                    close = cmd.find(ch, j + 1)
                    if close < 0:
                        return None
                    delim.append(cmd[j + 1:close])
                    j = close + 1
                elif ch == "\\":
                    delim.append(cmd[j + 1:j + 2])
                    j += 2
                else:
                    delim.append(ch)
                    j += 1
            if delim:
                heredocs.append(("".join(delim), strip_tabs))
            i = j
        elif cmd.startswith("$(", i):
            end_segment()
            i += 2
        elif c in ";()`":
            end_segment()
            i += 1
        elif c == "|":
            end_segment()
            i += 2 if cmd.startswith("||", i) or cmd.startswith("|&", i) else 1
        elif c == "&":
            if cmd.startswith("&&", i):
                end_segment()
                i += 2
            elif (i > 0 and cmd[i - 1] in "<>") or cmd.startswith("&>", i):
                word.append(c)  # 2>&1 / &> file 是重定向，不是后台符
                has_word = True
                i += 1
            else:
                end_segment()
                i += 1
        else:
            word.append(c)
            has_word = True
            i += 1
    end_segment()
    return segments


def skip_options(args, value_opts):
    """跳过开头的 -x / --xx[=v] 选项（value_opts 里的再多跳一个值），返回第一个非选项的下标。"""
    i = 0
    while i < len(args) and args[i].startswith("-"):
        if "=" not in args[i] and args[i] in value_opts:
            i += 1
        i += 1
    return i


def command_index(words):
    """跳过赋值前缀 / 保留字 / 包装命令，返回（赋值词集合，真正命令词的下标）；下标 == len(words) 表示没有命令词。"""
    i, n = 0, len(words)
    assigns = set()
    while i < n:
        w = words[i]
        base = w.rsplit("/", 1)[-1]
        if ASSIGN.match(w):
            assigns.add(w)
            i += 1
        elif w in KEYWORDS:
            i += 1
        elif base in WRAPPERS:
            value_opts = WRAPPERS[base]
            i += 1
            while i < n and (words[i].startswith("-") or (base in ("env", "sudo") and ASSIGN.match(words[i]))):
                if ASSIGN.match(words[i]):
                    assigns.add(words[i])
                elif words[i] in value_opts:
                    i += 1
                i += 1
            if base == "timeout":
                i += 1  # 时长
        else:
            break
    return assigns, i


def first_hit(cmd, leaf, depth=0):
    if depth > MAX_DEPTH:
        return None
    for words in split_segments(cmd) or []:
        assigns, i = command_index(words)
        if i >= len(words):
            continue
        base, rest = words[i].rsplit("/", 1)[-1], words[i + 1:]
        if base in SHELLS:
            script = next((rest[k + 1] for k, a in enumerate(rest[:-1]) if SHELL_C.fullmatch(a)), None)
            hit = first_hit(script, leaf, depth + 1) if script is not None else None
        elif base == "eval":
            hit = first_hit(" ".join(rest), leaf, depth + 1)
        else:
            hit = leaf(base, rest, assigns)
        if hit:
            return hit
    return None
