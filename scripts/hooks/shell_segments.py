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

另一个入口 split_segments_detail(cmd)：同一套切词，但每段多带「每词是否含引号字符、每词的会展开文本、
与前一段之间的结束符」，给要区分 '$?' 与 $?、要认管道邻接关系的判定器用（pipe_status_check.py）。
split_segments 是它的薄包装，返回形状不变（规则 8 / 9 在用）。
"""
import re
from typing import NamedTuple

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
# 结束符落在空段上时也要覆盖前一个结束符的「硬边界」：括号 / 命令替换 / 反引号 / 后台符会换掉执行上下文，
# 邻接判定不能跨过去；其余结束符（尤其续行的换行）落在空段上则沿用前一个，如 `a |<换行>b` 里 b 仍接在 | 后面。
# 例外是收括号 ")"：它后面再跟 ; 换行 && || 时，以后者为准（见 split_segments_detail.end_segment）
HARD_TERMINATORS = {"(", ")", "`", "$(", "&"}
NOT_LIVE = "\x00"  # 会展开文本里，被单引号 / 反斜杠保护的字符的占位


class Segment(NamedTuple):
    words: list        # 与 split_segments 同口径：引号已剥
    quoted: list       # 每词是否含引号 / 反斜杠转义（'$?' 与 $? 剥引号后是同一个词，靠它区分）
    live: list         # 每词「会展开」的文本：单引号内与反斜杠转义的字符换成 NOT_LIVE，其余同 words
    sep_before: str    # 与前一段之间的结束符：| |& || && ; 换行 & ( ) ` $(；首段为 ""


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
    segments = split_segments_detail(cmd)
    return None if segments is None else [segment.words for segment in segments]


def split_segments_detail(cmd):
    """切词的真身：返回 Segment 列表，引号不平衡返回 None（调用方放行）。"""
    segments, words, quoted, live = [], [], [], []
    word, live_word = [], []
    has_word = word_quoted = False
    pending_sep = ""   # 上一段的结束符，也就是下一个非空段的 sep_before
    heredocs = []
    i, n = 0, len(cmd)

    def add(text, live_text=None, protected=False):
        nonlocal has_word, word_quoted
        word.append(text)
        live_word.append(text if live_text is None else live_text)
        has_word = True
        word_quoted = word_quoted or protected

    def end_word():
        nonlocal word, live_word, has_word, word_quoted
        if has_word:
            words.append("".join(word))
            quoted.append(word_quoted)
            live.append("".join(live_word))
        word, live_word, has_word, word_quoted = [], [], False, False

    def end_segment(terminator):
        nonlocal words, quoted, live, pending_sep
        end_word()
        if words:
            segments.append(Segment(words, quoted, live, pending_sep))
            pending_sep = terminator
        elif terminator in HARD_TERMINATORS or pending_sep == ")":
            # 空段上只有硬边界覆盖前一个结束符，其余（续行 / 空行的换行等）沿用；
            # 收括号后面紧跟的 ; 换行 && || 才是下一条命令前真正的分隔（(a | b); echo $? 里 $? 仍是 b 的状态）
            pending_sep = terminator
        words, quoted, live = [], [], []

    while i < n:
        c = cmd[i]
        if c == "\\":
            if i + 1 < n and cmd[i + 1] != "\n":  # 反斜杠换行 = 续行，直接吞掉
                add(cmd[i + 1], NOT_LIVE, protected=True)
            i += 2
        elif c == "'":
            close = cmd.find("'", i + 1)
            if close < 0:
                return None
            add(cmd[i + 1:close], NOT_LIVE * (close - i - 1), protected=True)
            i = close + 1
        elif c == '"':
            j, buf, live_buf = i + 1, [], []
            while j < n and cmd[j] != '"':
                if cmd[j] == "\\" and j + 1 < n:
                    buf.append(cmd[j + 1])
                    live_buf.append(NOT_LIVE)
                    j += 2
                else:
                    buf.append(cmd[j])
                    live_buf.append(cmd[j])
                    j += 1
            if j >= n:
                return None
            add("".join(buf), "".join(live_buf), protected=True)
            i = j + 1
        elif c == "#" and not has_word:
            nl = cmd.find("\n", i)
            i = n if nl < 0 else nl
        elif c == "\n":
            end_segment("\n")
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
            end_segment("$(")
            i += 2
        elif c in ";()`":
            end_segment(c)
            i += 1
        elif c == "|":
            terminator = cmd[i:i + 2] if cmd.startswith("||", i) or cmd.startswith("|&", i) else "|"
            end_segment(terminator)
            i += len(terminator)
        elif c == "&":
            if cmd.startswith("&&", i):
                end_segment("&&")
                i += 2
            elif (i > 0 and cmd[i - 1] in "<>") or cmd.startswith("&>", i):
                add(c)  # 2>&1 / &> file 是重定向，不是后台符
                i += 1
            else:
                end_segment("&")
                i += 1
        else:
            add(c)
            i += 1
    end_segment("")
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
