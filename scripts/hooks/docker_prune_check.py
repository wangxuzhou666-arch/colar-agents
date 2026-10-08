#!/usr/bin/env python3
"""bash_pitfall_guard 规则 8 的判定器：会删镜像 / build cache 的 docker 全局清理。

stdin 喂整条 Bash 命令；命中时 stdout 打印一行命中标签（如 "docker image prune -a"），
未命中不输出、退出码 0。

为什么拦：本机有钉死 digest、按政策不推 registry、无法按字节复原的本地镜像。
实证 2026-10-07：磁盘清理 session 把 `docker image prune -a -f; docker builder prune -a -f`
当无风险操作执行，删掉织锦 PPTAgent 线 B3 验收钉死的 colar/pptagent-lab:v1d-f60543fb…
及 C 系列冻结 / 复核 / 变异镜像，零恢复来源，B3 硬阻塞。

命中：
  - docker {image|system|builder|buildx} prune 带 -a / --all（含 -af / -fa / -a -f / --all --force）
  - docker rmi …、docker image rm / remove …
  - 出现在 ; && || | & 换行 $( ) ` 之后；前面带 VAR=… 赋值；被 sudo / env / xargs / nice /
    timeout / if / do 等包装；docker 全局选项 --context / -c / -H / --host 在子命令之前；
    bash|sh|zsh -c '<脚本>' 与 eval 包裹的脚本递归检查
不命中：
  - 不带 -a 的 prune（只删 dangling）、只读子命令（ps -a / image ls / images -a / inspect）
  - 只是「提到」：作为别的命令的参数（grep / echo / git commit -m）、注释、heredoc 正文
  - 带 --help / -h
放行：紧贴该条 docker 命令写前缀 ALLOW_DOCKER_PRUNE=1（也认 sudo / env / xargs 之前的赋值），
  只对紧跟的那一条生效；`export ALLOW_DOCKER_PRUNE=1` 不算，也不读 hook 进程的环境变量 ——
  刻意不做全局开关。

已知边界（宁漏勿误，与 guard 其余规则一致）：
  - 双引号整段视为字面量，"$(docker rmi x)" 这类双引号内的命令替换会漏
  - 引号不平衡 → 放行，不猜
  - ssh host 'docker …' 是远端命令，不检查
  - 用变量间接调用（d=docker; $d rmi x）不检查

自证测试：bash scripts/hooks/tests/test_bash_pitfall_guard.sh
"""
import re
import sys

ALLOW = "ALLOW_DOCKER_PRUNE=1"
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SHORT_ALL = re.compile(r"-[A-Za-z]*a[A-Za-z]*")  # -a / -af / -fa，不含 --all（两个短横线不匹配）
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
DOCKER_VALUE_OPTS = {"-c", "--context", "-H", "--host", "--config", "-l", "--log-level",
                     "--tlscacert", "--tlscert", "--tlskey"}
BUILDX_VALUE_OPTS = {"--builder"}
PRUNE_GROUPS = {"image", "system", "builder", "buildx"}
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


def has_all_flag(args):
    return any(a in ("--all", "--all=true") or SHORT_ALL.fullmatch(a) for a in args)


def docker_hit(args):
    """args = docker 之后的词。命中返回标签，否则 None。"""
    i = skip_options(args, DOCKER_VALUE_OPTS)
    if i >= len(args):
        return None
    sub, rest = args[i], args[i + 1:]
    if "--help" in rest or "-h" in rest:
        return None
    if sub == "rmi":
        return "docker rmi"
    if sub not in PRUNE_GROUPS:
        return None
    j = skip_options(rest, BUILDX_VALUE_OPTS if sub == "buildx" else set())
    if j >= len(rest):
        return None
    action, tail = rest[j], rest[j + 1:]
    if sub == "image" and action in ("rm", "remove"):
        return "docker image " + action
    if action == "prune" and has_all_flag(tail):
        return "docker %s prune -a" % sub
    return None


def check_segment(words, depth):
    i, n = 0, len(words)
    allowed = False
    while i < n:
        w = words[i]
        base = w.rsplit("/", 1)[-1]
        if ASSIGN.match(w):
            allowed = allowed or w == ALLOW
            i += 1
        elif w in KEYWORDS:
            i += 1
        elif base in WRAPPERS:
            value_opts = WRAPPERS[base]
            i += 1
            while i < n and (words[i].startswith("-") or (base in ("env", "sudo") and ASSIGN.match(words[i]))):
                if ASSIGN.match(words[i]):
                    allowed = allowed or words[i] == ALLOW
                elif words[i] in value_opts:
                    i += 1
                i += 1
            if base == "timeout":
                i += 1  # 时长
        else:
            break
    if i >= n:
        return None
    base, rest = words[i].rsplit("/", 1)[-1], words[i + 1:]
    if base in SHELLS:
        for k, a in enumerate(rest[:-1]):
            if SHELL_C.fullmatch(a):
                return first_hit(rest[k + 1], depth + 1)
        return None
    if base == "eval":
        return first_hit(" ".join(rest), depth + 1)
    if base != "docker" or allowed:
        return None
    return docker_hit(rest)


def first_hit(cmd, depth=0):
    if depth > MAX_DEPTH:
        return None
    for words in split_segments(cmd) or []:
        hit = check_segment(words, depth)
        if hit:
            return hit
    return None


def main():
    hit = first_hit(sys.stdin.read())
    if hit:
        print(hit)


if __name__ == "__main__":
    main()
