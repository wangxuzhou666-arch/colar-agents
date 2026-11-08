#!/usr/bin/env python3
"""全机重任务槽：同一时刻只让一套「全量测试级」任务跑，按优先级排队，按内存 / 磁盘放行。纯标准库，Python 3.9 可跑。

为什么（2026-11-07 两起事故，Colar 2026-11-08 拍板）：
  19:58 磁盘写满：pytest 临时目录 + 29 棵工作树 + Docker 把盘吃到只剩约 4G，两个会话同时建验证树、跑测试，压垮最后几 G；
  21:52 卡死被强制重启：两套全量测试并行（各 6–8 个 worker、带覆盖率）+ 刚重启的 Docker 虚拟机，把 16G 内存和 swap 一起压满。
  当时的防护都是「仓内、单信号、靠自觉」：织锦 clean_check_all 的全局槽锁在 $GITDIR 里，只管本仓本脚本；覆盖率快照（-n auto）、
  twotrack、各会话手跑的 pytest -n 都看不见它；负载门控只看 CPU load、不看内存。

机制：
  槽 = $HEAVY_SLOT_DIR/slot.lock 上的独占 flock。flock 挂在「打开文件描述」上，由内核持有，最后一个引用它的进程退出就释放——
    崩溃 / kill -9 不留残锁，也没有 pid 复用误判。持锁的 fd 可继承：被包的命令和它的子进程都持有它，协调进程被杀而测试还在跑时，
    槽仍算占着（同 clean_check_all 记 child_pgid 的用意）。
  排队 = $HEAVY_SLOT_DIR/queue/ 下每个等待者一张票（文件名 = 优先级-入队纳秒-pid，字典序即出队顺序），等待者对自己的票持独占锁；
    探活 = 对别人的票加共享锁，加得上说明主人已死，删票。票先以临时名建好、加锁、写完再改名，探活的人看不到「建了还没锁」的票。
    只有排在最前的那张票有资格去抢槽。
  优先级（小的先出队；不抢占正在跑的——杀掉一个跑了 15 分钟的门是纯浪费）：
    deploy(0) 部署门 · gate(1) PR 门 / 手动全量门 · snapshot(2) 覆盖率 / 测试自证 / 夜间档 · adhoc(3) 其余
  放行判据（轮到自己、且槽空时才看）：
    · 磁盘：家目录所在卷剩余 < HEAVY_MIN_DISK_GB → 直接拒绝。等不出空间来，硬跑就是写不了临时文件的假红。
    · 内存：kern.memorystatus_vm_pressure_level 不是 1（正常），或 kern.memorystatus_level（空闲百分比）< HEAVY_MIN_FREE_PCT
      → 等，最多 HEAVY_MEM_WAIT_MAX 秒，等满照常放行并在 stderr 喊出来（槽本身已保证只有一套重任务，剩下的压力来自
      Docker / 浏览器这类槽外的东西，无限期等会让部署门永远起不来）。
      不拿 swap 已用量当闸门：macOS 换出去的页很久不回收，压力过去后它还挂着，拿它当闸门会白等；只记录。
      不拿 load 当闸门：内存颠簸时等换页的进程也算进 load，load 高是结果不是原因。

用法：
  heavy_slot.py run [--priority P] [--label L] [--wait-max S] [--fail-exit N] -- <命令…>
      排队拿槽，然后 exec 成该命令（pid 不变），环境里带 HEAVY_SLOT_HELD=<label>。
  heavy_slot.py acquire --fd N --holder-pid PID [--priority P] [--label L] [--wait-max S] [--fail-exit N]
      给 bash 用：调用方先 `exec 7>>"$(heavy_slot.py lockfile)"`，本命令对继承来的 fd 7 加锁后退出。锁挂在打开文件描述上，
      调用方 shell 仍持有它，直到 shell 和继承了 fd 7 的子进程全部退出。调用方拿到后自己 export HEAVY_SLOT_HELD。
  heavy_slot.py lockfile   打印槽锁文件路径（顺手建目录）
  heavy_slot.py status     谁在占槽、队列、此刻的内存 / swap / 磁盘读数
  重入：环境里已有 HEAVY_SLOT_HELD（已经在某个槽里）→ run 直接 exec、acquire 直接成功，不再排队。

退出码：run 成功时就是被包命令的退出码；没拿到槽（排队超时 / 磁盘不足 / 旋钮不合法）→ --fail-exit（默认 75 = EX_TEMPFAIL）。

旋钮（环境变量）：HEAVY_SLOT_DIR（默认 ~/.cache/heavy-slot）· HEAVY_QUEUE_TIMEOUT（--wait-max 的默认值，3600）·
  HEAVY_POLL（10）· HEAVY_REPORT（300，排队播报间隔）· HEAVY_MIN_FREE_PCT（20）· HEAVY_MEM_WAIT_MAX（1800）·
  HEAVY_MIN_DISK_GB（20）· HEAVY_SLOT_FAKE_FILE（测试注入：一行「压力等级 空闲百分比 swap已用GB 磁盘剩余GB」，每次读数重读，
  读不了的项当「读不到」，不回退真实读数）。

已知限制：
  · 持锁 fd 会被子进程继承：被包的任务拉起、又没收掉的常驻进程（dev server 等）会让槽一直占着。status 会列出还开着锁文件的进程。
  · 不做老化：一直有高优先级任务时，低优先级的会一直排着（夜间档本来就避开白天）。
  · 只管走它的任务。手跑的 pytest -n / --cov 由 bash_pitfall_guard 规则 10 拦到这里；不过 Claude hook 的会话（Codex 等）
    靠各仓脚本自己接槽（织锦 clean_check_all / check_all / coverage_snapshot）。
"""
from __future__ import annotations

import argparse
import contextlib
import datetime
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import NamedTuple, Optional

PRIORITIES = {"deploy": 0, "gate": 1, "snapshot": 2, "adhoc": 3}
HELD_ENV = "HEAVY_SLOT_HELD"
FAKE_ENV = "HEAVY_SLOT_FAKE_FILE"
PRESSURE_NORMAL = 1
DEFAULT_FAIL_EXIT = 75
PROBE_TIMEOUT_SEC = 5


class SlotError(Exception):
    """没拿到槽、也不该拿：消息给人看，退出码走 --fail-exit。"""


def knob(name: str, default: float) -> float:
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)?", raw):
        raise SlotError(f"{name}={raw!r} 不是非负数字")
    return float(raw)


def slot_dir() -> Path:
    path = Path(os.environ.get("HEAVY_SLOT_DIR") or Path.home() / ".cache" / "heavy-slot")
    (path / "queue").mkdir(parents=True, exist_ok=True)
    return path


def lockfile_path() -> Path:
    return slot_dir() / "slot.lock"


# ───────────────────────── 读数 ─────────────────────────

class Readings(NamedTuple):
    pressure: Optional[int]         # 1 正常 / 2 警告 / 4 危急
    free_pct: Optional[float]
    swap_used_gb: Optional[float]
    disk_free_gb: Optional[float]

    def describe(self) -> str:
        def show(value, fmt):
            return "读不到" if value is None else fmt.format(value)
        return (f"内存压力 {show(self.pressure, '{}')} · 空闲 {show(self.free_pct, '{:.0f}%')} · "
                f"swap 已用 {show(self.swap_used_gb, '{:.1f}G')} · 磁盘剩 {show(self.disk_free_gb, '{:.0f}G')}")


def _sysctl(name: str) -> Optional[str]:
    try:
        done = subprocess.run(["sysctl", "-n", name], capture_output=True, text=True,
                              timeout=PROBE_TIMEOUT_SEC, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def _number(text: Optional[str], cast):
    try:
        return cast(text) if text is not None else None
    except ValueError:
        return None


def parse_swapusage(text: str) -> Optional[float]:
    """`total = 4096.00M  used = 3167.25M  free = 928.75M  (encrypted)` → 已用 GB。"""
    match = re.search(r"used = ([\d.]+)([KMG])", text)
    if not match:
        return None
    return float(match.group(1)) * {"K": 1 / 1024 ** 2, "M": 1 / 1024, "G": 1.0}[match.group(2)]


def read_readings() -> Readings:
    fake = os.environ.get(FAKE_ENV)
    if fake is not None:
        try:
            fields = Path(fake).read_text(encoding="utf-8").split()
        except OSError:
            fields = []
        padded = fields + [None] * 4
        return Readings(_number(padded[0], int), _number(padded[1], float), _number(padded[2], float),
                        _number(padded[3], float))
    try:
        disk = shutil.disk_usage(Path.home()).free / 1024 ** 3
    except OSError:
        disk = None
    return Readings(_number(_sysctl("kern.memorystatus_vm_pressure_level"), int),
                    _number(_sysctl("kern.memorystatus_level"), float),
                    parse_swapusage(_sysctl("vm.swapusage") or ""), disk)


def memory_refusal(readings: Readings, min_free_pct: float) -> Optional[str]:
    """None = 内存允许放行；否则是不放行的原因。读不到的项不拦（fail-open，同 gate_load.py）。"""
    if readings.pressure is not None and readings.pressure != PRESSURE_NORMAL:
        return f"内存压力等级 {readings.pressure}（1 正常 / 2 警告 / 4 危急）"
    if readings.free_pct is not None and readings.free_pct < min_free_pct:
        return f"空闲内存 {readings.free_pct:.0f}% 低于 {min_free_pct:.0f}%"
    return None


# ───────────────────────── 排队 ─────────────────────────

class Ticket:
    """自己的排队票：持独占锁直到 close()。"""

    def __init__(self, queue: Path, priority: str, label: str, holder_pid: int, command: list[str]):
        stem = f"{PRIORITIES[priority]}-{time.time_ns():020d}-{os.getpid()}"
        temp = queue / f".{stem}.tmp"
        self.path = queue / f"{stem}.json"
        self.fd = os.open(temp, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o644)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        os.write(self.fd, json.dumps({"pid": holder_pid, "label": label, "priority": priority,
                                      "enqueued": now_iso(), "command": command},
                                     ensure_ascii=False).encode())
        os.rename(temp, self.path)

    def close(self) -> None:
        with contextlib.suppress(FileNotFoundError):
            self.path.unlink()
        os.close(self.fd)


def live_tickets(queue: Path, mine: Optional[Path]) -> list[Path]:
    """按出队顺序返回活着的票；顺手删掉主人已死的票。"""
    alive = []
    for path in sorted(queue.glob("*.json")):
        if path == mine:
            alive.append(path)
            continue
        try:
            fd = os.open(path, os.O_RDONLY)
        except FileNotFoundError:
            continue
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            alive.append(path)
        else:
            with contextlib.suppress(FileNotFoundError):   # 另一个探活者抢先删了
                path.unlink()
        finally:
            os.close(fd)
    return alive


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def now_iso() -> str:
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def try_lock(fd: int) -> bool:
    """试着拿独占锁，拿到就留着（True）。探测和加锁必须是同一步：分两步时 status 的探测能插进中间。"""
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    return True


def slot_is_held(fd: int) -> bool:
    if not try_lock(fd):
        return True
    fcntl.flock(fd, fcntl.LOCK_UN)
    return False


def holder_summary(directory: Path) -> str:
    holder = read_json(directory / "holder.json")
    if not holder:
        return "（占槽者没留记录）"
    return f"{holder.get('label', '?')}（pid {holder.get('pid', '?')}，{holder.get('started', '?')} 起）"


def wait_for_slot(slot_fd: int, *, priority: str, label: str, holder_pid: int, wait_max: float,
                  command: list[str]) -> dict:
    """排队直到拿到槽（返回时 slot_fd 上持有独占锁）；拿不到抛 SlotError。"""
    directory = slot_dir()
    poll = knob("HEAVY_POLL", 10) or 0.1
    report_every = knob("HEAVY_REPORT", 300)
    min_free = knob("HEAVY_MIN_FREE_PCT", 20)
    mem_wait_max = knob("HEAVY_MEM_WAIT_MAX", 1800)
    min_disk = knob("HEAVY_MIN_DISK_GB", 20)

    readings = read_readings()
    if readings.disk_free_gb is not None and readings.disk_free_gb < min_disk:
        raise SlotError(f"磁盘只剩 {readings.disk_free_gb:.0f}G，低于 {min_disk:.0f}G，不放行（硬跑会写不了临时文件、报假红）。"
                        "先腾空间：du -sh ~/artifacts/*/tmp ~/.wt/* | sort -h | tail；不用的工作树 wt rm / wt park")

    ticket = Ticket(directory / "queue", priority, label, holder_pid, command)
    start = time.monotonic()
    last_report = None
    mem_refused_since = None
    try:
        while True:
            now = time.monotonic()
            live = live_tickets(directory / "queue", ticket.path)
            ahead = live.index(ticket.path)
            reason = None
            if ahead == 0 and try_lock(slot_fd):
                readings = read_readings()
                reason = memory_refusal(readings, min_free)
                if reason is None:
                    break
                mem_refused_since = mem_refused_since if mem_refused_since is not None else now
                if now - mem_refused_since >= mem_wait_max:
                    print(f"heavy-slot: ⚠ {reason}，已等满 {mem_wait_max:.0f}s，照常放行（{readings.describe()}）",
                          file=sys.stderr)
                    break
                fcntl.flock(slot_fd, fcntl.LOCK_UN)
            waited = now - start
            wait_on = reason or f"占槽：{holder_summary(directory)}，前面 {ahead} 个"
            if waited >= wait_max:
                raise SlotError(f"排队 {waited:.0f}s 没拿到槽（上限 {wait_max:.0f}s）；{wait_on}。"
                                f"看全貌：python3 {Path(__file__).resolve()} status")
            if last_report is None or now - last_report >= report_every:
                print(f"heavy-slot: [{label}] 排队 {waited:.0f}s，{wait_on}", file=sys.stderr)
                last_report = now
            time.sleep(poll)
    finally:
        ticket.close()

    waited = round(time.monotonic() - start, 1)
    record = {"pid": holder_pid, "label": label, "priority": priority, "started": now_iso(), "waited_sec": waited,
              "started_under_memory_pressure": reason is not None, "readings": readings._asdict(), "command": command}
    (directory / "holder.json").write_text(json.dumps(record, ensure_ascii=False, indent=1), encoding="utf-8")
    with open(directory / "history.log", "a", encoding="utf-8") as log:
        log.write(json.dumps(record, ensure_ascii=False) + "\n")
    if waited >= 1:
        print(f"heavy-slot: [{label}] 拿到槽，排队 {waited:.0f}s（{readings.describe()}）", file=sys.stderr)
    return record


# ───────────────────────── 子命令 ─────────────────────────

def cmd_run(args) -> int:
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise SlotError("run 后面要跟 -- <命令…>")
    if not os.environ.get(HELD_ENV):
        fd = os.open(lockfile_path(), os.O_RDWR | os.O_CREAT, 0o644)
        wait_for_slot(fd, priority=args.priority, label=args.label or Path(command[0]).name,
                      holder_pid=os.getpid(), wait_max=args.wait_max, command=command)
        os.set_inheritable(fd, True)
        os.environ[HELD_ENV] = args.label or Path(command[0]).name
    try:
        os.execvp(command[0], command)
    except OSError as err:
        print(f"heavy-slot: 起不来 {command[0]}：{err}", file=sys.stderr)
        return 127


def cmd_acquire(args) -> int:
    if os.environ.get(HELD_ENV):
        return 0
    try:
        os.fstat(args.fd)
    except OSError:
        raise SlotError(f"fd {args.fd} 没打开：调用方要先 exec {args.fd}>>\"$(heavy_slot.py lockfile)\"")
    wait_for_slot(args.fd, priority=args.priority, label=args.label or "acquire", holder_pid=args.holder_pid,
                  wait_max=args.wait_max, command=["(shell)", str(args.holder_pid)])
    return 0


def pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
    except (ValueError, TypeError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    return True


def cmd_status(_args) -> int:
    directory = slot_dir()
    fd = os.open(lockfile_path(), os.O_RDWR | os.O_CREAT, 0o644)
    held = slot_is_held(fd)
    os.close(fd)
    holder = read_json(directory / "holder.json")
    tickets = [read_json(path) for path in live_tickets(directory / "queue", None)]
    if held:
        print(f"占槽：{holder_summary(directory)}")
        if holder and not pid_alive(holder.get("pid")):
            waiters = {str(t.get("pid")) for t in tickets}
            try:
                out = subprocess.run(["lsof", "-t", str(lockfile_path())], capture_output=True, text=True,
                                     timeout=30, check=False).stdout.split()
            except (OSError, subprocess.TimeoutExpired):
                out = []
            keepers = [pid for pid in out if pid not in waiters]
            print(f"  ⚠ 记录里的占槽进程已退出，锁还被继承了 fd 的子进程拿着：{' '.join(keepers) or '（lsof 没列出）'}"
                  "（ps -o pid,command -p <pid> 看是谁；多半是任务拉起后没收的常驻进程）")
    else:
        last = f"；上一个：{holder.get('label')}（{holder.get('started')} 起）" if holder else ""
        print(f"槽空闲{last}")
    for index, ticket in enumerate(tickets, 1):
        print(f"  排队 {index}：{ticket.get('label', '?')} [{ticket.get('priority', '?')}] pid {ticket.get('pid', '?')}，"
              f"{ticket.get('enqueued', '?')} 入队")
    print(read_readings().describe())
    return 0


def cmd_lockfile(_args) -> int:
    print(lockfile_path())
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="全机重任务槽（说明见文件头）")
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("run", "acquire"):
        p = sub.add_parser(name)
        p.add_argument("--priority", choices=sorted(PRIORITIES, key=PRIORITIES.get), default="adhoc")
        p.add_argument("--label", default="")
        p.add_argument("--wait-max", type=float, default=None)
        p.add_argument("--fail-exit", type=int, default=DEFAULT_FAIL_EXIT)
        if name == "run":
            p.add_argument("command", nargs=argparse.REMAINDER)
        else:
            p.add_argument("--fd", type=int, required=True)
            p.add_argument("--holder-pid", type=int, required=True)
    sub.add_parser("status")
    sub.add_parser("lockfile")
    args = parser.parse_args(argv)
    fail_exit = getattr(args, "fail_exit", DEFAULT_FAIL_EXIT)
    try:
        if getattr(args, "wait_max", 0) is None:
            args.wait_max = knob("HEAVY_QUEUE_TIMEOUT", 3600)
        return {"run": cmd_run, "acquire": cmd_acquire, "status": cmd_status, "lockfile": cmd_lockfile}[args.cmd](args)
    except SlotError as err:
        print(f"heavy-slot: {err}", file=sys.stderr)
        return fail_exit


if __name__ == "__main__":
    sys.exit(main())
