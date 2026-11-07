#!/usr/bin/env python3
"""bash_pitfall_guard 规则 5 的判定器：管道末段是展示型过滤器，紧接着就判 $?。

stdin 喂整条 Bash 命令；命中时 stdout 打印一行管道末段的命令词（如 "tail"），
未命中、引号不平衡、任何异常都不输出、退出码 0（调用方放行，沿用规则 6-9 的约定）。

为什么拦：管道的 $? 是末段的退出码，`pytest -q | tail -3; echo $?` 判的是 tail，pytest 失败被静默吞掉。
2026-11 审计：旧判据（整条命令里有任意 | 且有任意 $?）30 天拦 1419 次，精度约 11%；
真正「$? 紧跟管道」只占 14.5%，真阳性集中在末段是展示型过滤器的那一类。

命中（全部满足才拦，其余一律放行，宁漏勿误）：
  (a) 有 live 的 $? 词：不在单引号内、不在 heredoc 正文、不在 bash|sh -c '…' 字符串内、没被反斜杠转义；
      双引号里的 "rc=$?" 是 live（外层 shell 照常展开）
  (b) 含该 $? 的简单命令，紧邻的前一条是真管道的末段（与再前一条之间的结束符是未加引号的单个 | 或 |&，
      不是 || ; &&）；前一条与 $? 命令之间的结束符是 ; 换行 && || 之一
      —— 所以 $? 在管道之前（echo exit $? | tee log）、$? 跟在非管道命令后（cmd; echo $?）都不拦
  (c) 该管道末段的命令词属 tail head cut tee sed tr wc sort cat（只做展示的过滤器）；
      末段是 grep xargs diff python 等的放行：要首段还是末段的状态是意图问题，机械判不了；
      sudo / env / xargs 等包装不展开，包装后的末段也放行
  (d) 整条命令没有小写 pipestatus（含 ${pipestatus[1]:-$?}），也没有 set -o pipefail / setopt pipefail；
      大写 PIPESTATUS 不豁免：zsh 里它是空的，${PIPESTATUS[0]:-$?} 会静默退回末段码

切词见 shell_segments.split_segments_detail（括号 / 命令替换 / 后台符是硬边界，邻接判定不跨过去）。
自证测试：bash scripts/hooks/tests/test_bash_pitfall_guard.sh
"""
import re
import sys

from shell_segments import ASSIGN, KEYWORDS, split_segments_detail

PIPE_SEPARATORS = {"|", "|&"}
FOLLOW_SEPARATORS = {";", "\n", "&&", "||"}
DISPLAY_FILTERS = {"tail", "head", "cut", "tee", "sed", "tr", "wc", "sort", "cat"}
PIPEFAIL = re.compile(r"\b(?:set\s+-[A-Za-z]*o|setopt)\s+pipefail\b")


def command_word(words):
    """跳过赋值前缀和保留字，取命令词 basename；没有则返回空串。"""
    for word in words:
        if not (ASSIGN.match(word) or word in KEYWORDS):
            return word.rsplit("/", 1)[-1]
    return ""


def pipe_status_hit(cmd):
    """命中返回管道末段的命令词，否则 None。"""
    if "pipestatus" in cmd or PIPEFAIL.search(cmd):
        return None
    segments = split_segments_detail(cmd)
    for prev, segment in zip(segments or [], (segments or [])[1:]):
        if segment.sep_before not in FOLLOW_SEPARATORS or prev.sep_before not in PIPE_SEPARATORS:
            continue
        if not any("$?" in text for text in segment.live):
            continue
        tail_command = command_word(prev.words)
        if tail_command in DISPLAY_FILTERS:
            return tail_command
    return None


def main():
    hit = pipe_status_hit(sys.stdin.read())
    if hit:
        print(hit)


if __name__ == "__main__":
    main()
