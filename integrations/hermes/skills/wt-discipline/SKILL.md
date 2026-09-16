---
name: wt-discipline
description: "用 git worktree 做隔离验证/部署/并行分支时的纪律 —— 一律走 `wt` 包装脚本（scripts/wt），落点固定 ~/.wt/<repo>-<用途>，绝不 cd 进 worktree、绝不把要留存的产物写在 worktree 里。治六类实证踩坑：cwd 悬空后满屏 ENOENT · /tmp↔/private/tmp 别名让 remove 失配 · 防御式 rm -rf+prune 仪式 · 产物随 worktree 蒸发（部署史丢过一条）· 落点四处开花 · .venv/node_modules 每次手搭 · 不进 git 的本地产物实测十三样、逐个撞门（素材/node_modules/.venv/种子库/.env/子服务 node_modules/部署史/四个快照记录；一棵新 worktree 跑不绿全量门是构造使然；缺 .env 时门不红但读数悄悄变；.venv 用 symlink 会让 rsync --delete 删掉服务器真实目录；活 sqlite 要用 .backup 不是 cp）· symlink 挂的 .venv 若有 editable install 会让「干净树验证」静默变成在量脏主树 · worktree 只上线 HEAD 造成「本地改了线上没变」。Use when: creating a throwaway worktree to verify a build/test at a specific ref, running a clean-tree deploy, working two branches in parallel, or debugging \"worktree remove 删不掉 / 目录已存在 / No such file or directory / 部署记录不见了 / 干净树上一堆无关测试红\"."
version: 1.3.2
source: session-derived (2026-08-18)。全量扫 5297 个 session、200 个含真实 git worktree 操作的会话、288 次调用统计得出；六类失败模式均有现场证据。v1.1.0 (2026-08-19)：织锦一次干净部署实战补第四、五节——三样不进 git 的必补产物（素材/node_modules/.venv）、.venv 用 symlink 会触发 rsync --delete 删服务器真实目录、worktree 只上线 HEAD 导致「本地改了线上没变」。v1.2.0 (2026-09-11)：织锦一次「在干净树上还 check_all 的债」实战——第四样产物（种子库 `data/*.db`，缺了会让十几条无关测试红）、活 sqlite 用 `sqlite3 .backup` 而非 `cp`（2.1GB 实测 3.3s，有并发写仍一致）、以及 symlink 挂 `.venv` 时必须先自证 import 解析到 worktree（否则整轮验证在量主树）。v1.3.0 (2026-09-11，同一轮继续撞)：第四节重写——**一棵新 worktree 跑不绿全量门是构造使然**，按「范围验证（前四样）/ 门级判决（十三样）」分档；补 `.env`（唯一缺了不报错、只让读数悄悄变的一样，symlink 不 cp）、子服务 node_modules、`.deploy-history.jsonl`、四个快照记录；方法论教训：开工前把门的每一道读一眼就能一次列全，逐轮撞要付每轮 6 分半的 pytest。v1.3.1：再补一类不在产物清单里的假红——拿 mtime 当新鲜度判据的门（checkout 会把 mtime 刷成当下），认出来跳过即可。同轮订正了一个错判：我曾因「库 2GB 且在被写」就断言干净树跑不了全量并写进 commit message，实为没想到 `.backup`。v1.3.2 (2026-09-15)：第二节补第四条铁律——要在 worktree 里改依赖，`frontend/node_modules` 必须真实拷贝而非 `wt new` 默认的 symlink（织锦 Next 16.2.10→16.3.5 实证：symlink 下 `npm install` 写的是主仓的库，会当场换掉并行线 dev server 正在用的 node_modules）。
---

# worktree 纪律

worktree 的价值是**在不扰动主工作树的前提下拿到某个 ref 的干净副本**——验构建、跑测试、做部署。
它的代价是**你多了一个会凭空消失的文件系统位置**，而所有翻车都来自忘记这一点。

机械层已由 `~/Desktop/colar-agents/scripts/wt` 承担，本文件只讲脚本替你挡不掉的判断。

## 一、命令

```bash
wt new <用途> [ref]     # 建到 ~/.wt/<repo>-<用途>，默认 detach，自动继承 .venv / node_modules
wt run <用途> <命令...> # 在 worktree 里跑；调用方 cwd 不动
wt ls                   # 一屏看全：净 / 脏 / 悬空 / 不在 ~/.wt
wt rm <用途>            # 拆；有未提交内容会拒绝并摊开给你看，要丢得显式 --force
wt gc                   # prune 失联记录 + 清 ~/.wt 下干净的孤儿目录
wt main                 # 打印主工作树根（在 worktree 里调用也返回主仓）
```

不在 PATH 里就用绝对路径 `bash ~/Desktop/colar-agents/scripts/wt ...`。

## 二、四条铁律

**1. 不 cd 进 worktree，只用 `wt run`。**
Claude Code 的 Bash cwd 跨调用持久。`cd` 进去干活、下一条命令把它删掉，shell 就卡在一个不存在的目录里，
之后每条命令都 `No such file or directory`——历史上 6 次，而且每次都要浪费两三轮才反应过来是 cwd 的问题。
`wt run` 用子 shell 执行，从根上不存在这个状态。

**2. 要留存的东西写主仓，不写 worktree。**
worktree 是**一次性**的。部署日志、生成的报告、临时写的验证脚本，只要下一轮还想要，就必须落在 `wt main` 指的地方。

> 实证（2026-08-18）：`update.sh` 里部署史写 `REPO_ROOT`，而干净部署流程让 REPO_ROOT 指向 `/tmp/deploy-xxx`，
> 于是当天三次部署的记录，一条随 worktree 被删而**永久丢失**，另两条散在两个临时目录，主仓的部署史停在八天前。
> 同形事故：`mutation_check.py` 随 scratchpad 消失——"纪律留在 memory 里、工具却没了，下一轮从零重建"。

脚本里要推主仓根，用 `git rev-parse --git-common-dir` 的父目录（主仓返回 `.git`，worktree 返回主仓的 `.git`，两种都对），
不要用 `$(dirname $0)/..` 那种相对推断。

**3. `wt rm` 被拒绝时，先看，别条件反射加 `--force`。**
拒绝的意思是那里面有你没提交的东西。搬回主仓再拆。

**4. 要在 worktree 里改依赖，`frontend/node_modules` 必须是真实拷贝，不能是 `wt new` 默认挂的 symlink。**
symlink 指回主仓，worktree 里的 `npm install` 写的就是主仓的 `node_modules`——主树上正跑着的 dev server
当场被换库。做法：`rm <wt>/frontend/node_modules`（删的是链接本身，别加 `-r`、别带尾斜杠）→
`cp -a <主仓>/frontend/node_modules <wt>/frontend/node_modules`（约 720MB，实测一分钟内；
`cp: chflags ... Too many levels of symbolic links` 是 `.bin/` 里的相对 symlink 在抱怨，无害，`.bin/next` 照样可解析）。
`.venv` 这边已有 `--copy-venv`；node_modules 目前没有对应开关，手动 cp。

> 实证（2026-09-15，织锦 Next 16.2.10→16.3.5）：主树 dev server 是并行线的（别杀），在用主仓 node_modules，
> 升级只能在 worktree 里做。拷贝后 `npm install` / `npm audit fix` / build / vitest / e2e 全在副本上跑，
> 主树 node_modules 一个字节没动。合入后主树 node_modules 与 lock 不一致是**预期状态**——下次重启 dev 前
> `npm install`；在此之前旧版 `next dev` 会把 `AGENTS.md` 改回旧措辞，树会脏，无害。

## 三、什么时候不该用 worktree

- **只是想看某个 ref 的某个文件** → `git show <ref>:<path>`，不用建目录。
- **只是想跑一次测试且主树是干净的** → 直接在主仓跑。worktree 的成本（环境继承、清理、记得产物落点）只有在
  "主树脏 / 要并行 / 要 detach 到历史 ref" 时才划算。
- **要长期存在的第二个开发环境** → 那不是 throwaway worktree，用正经 clone 或长期分支，别塞进 `~/.wt`
  （`~/.wt` 的语义是"随时可以 gc 掉"）。

## 四、不进 git 的本地产物：不是三样，实测十三样

worktree 给的是**「git 眼里干净」的副本**，部署脚本/测试门要的却是**「能跑」的完整环境**。
不进 git 的东西在 worktree 里天然缺席，缺哪样就在哪道门红——而且每红一次要白跑一次 build。

**先定性，再看清单**：一棵新 worktree 上**跑不绿全量门**，这不是代码问题，是构造使然。
所以按用途分两档，别把力气花错地方：

| 用途 | 要补什么 | 判决的效力 |
|---|---|---|
| **范围验证**（跑你碰过的那几个测试文件） | 前四样 | 够用，且这是绝大多数场合真正需要的 |
| **门级判决**（跑整套 check_all / 部署） | 全部十三样 | 贵；先问自己是不是真的需要 |

> 实证（2026-09-11，织锦）：为了在干净树上还一笔 check_all 的债，连撞四轮——
> 缺库（17 条无关红）→ 缺 `.env`（读数静默变了，见下）→ 缺 `.deploy-history.jsonl`（看板对账红）
> + 缺四个快照记录（新鲜度门红）→ 缺 `services/pattern/node_modules`（制版测试红）。
> 每一轮都要重跑 6 分半的 pytest。**一开始先把 check_all 的七道门各读一眼，
> 就能一次列全**——这比逐轮撞便宜得多。

| 产物 | 缺了在哪道门红 | 补法 |
|---|---|---|
| 素材本体 `frontend/public/{blocks,fabrics,artworks,hdri}` 约 130MB | 素材完整门 | 从主仓 `rsync -a` |
| `frontend/node_modules` 约 720MB | 本地 build 门（module-not-found） | 从主仓 `cp -a` |
| `.venv` 约 730MB | 契约门（`.venv/bin/python: No such file`） | 从主仓 `cp -a`，**必须是真实目录** |
| **种子库 `data/*.db`**（织锦 `demo.db` 约 2.1GB） | **任何跑 pytest 的干净树**：库不在，测试自建一个 4KB 空壳，十几条依赖种子数据的测试红 | `sqlite3 ".backup"`，**不是 `cp`**（见下） |
| **`.env`** —— 最危险的一样，见下 | **不红**，只是读数悄悄变了 | `ln -sfn`（别 `cp`，密钥不落第二份） |
| **子服务的 node_modules**（织锦 `services/pattern/node_modules`） | 该子服务的测试（`ERR_MODULE_NOT_FOUND`）——wt 只挂根和 frontend 两处 | `ln -sfn` |
| `.deploy-history.jsonl` | 看板对账门（`FileNotFoundError`） | `cp` |
| 四个快照记录 `.audit-deps.json` · `.coverage-snapshot.json` · `.mutation-check.json` · `.e2e-smoke.json` | 快照新鲜度门（报「从没跑过」） | `cp`（文件名逐字抄，别猜——猜过 `.e2e-snapshot.json`，真名是 `.e2e-smoke.json`） |
| `.gate-results.json` · `.routes-probe.json` | 视门而定 | `cp` |

**还有一类不在清单里、但一样会假红：拿 mtime 当新鲜度判据的门。** `git checkout` 把每个文件的
mtime 刷成**当下**，于是任何「快照时间 vs 文件 mtime」的比较在新 worktree 里必然报「文件比快照新」。
织锦实证：依赖审计门在 worktree 里报「lock 在快照之后变过」（列了三个 lock 文件），
而主树上同一道门是绿的——lock 一个字节没变，变的只是 mtime。判别法：`git diff <snapshot-sha> -- <那些文件>`
为空就是假红。**补不了、也不该补**，认出来跳过即可。

**`.env` 是这堆里唯一「缺了不报错」的一样，所以最危险。** 它是 gitignore 的，里面既有凭证也有
功能开关；缺了它开关全部回落默认值，于是**门不红、数字变了**。织锦实证：干净树没有 `.env`
⇒ `RECOMMEND_INCLUDE_EXTERNAL` 默认关 ⇒ 推荐候选池 8060 变 8006、eval 读数从 6 变 0，
而那条棘轮门断言的是「恰等于 6」，于是干净树上它是红的——**红的成因和代码毫无关系**。
当时我为这个差异归因了两次都错（先怪并行线的在途代码，再怪库内容），因为两边
看起来完全一样。**补法用 symlink 不用 cp**：密钥不在磁盘上多一份，随 worktree 一起消失。
⚠ 带上 `.env` 意味着凭证可用，跑全套可能发起真实外部调用——先确认项目有花费熔断/tripwire。

**活 sqlite 用 `.backup`，不要 `cp`。** 常驻 dev server 正在写那个库，`cp` 拿到的可能是撕裂的快照。
`sqlite3 <src> ".backup '<dst>'"` 走 SQLite 的备份 API，有并发写也给一致快照——2.1GB 实测 3.3 秒，
拷完 `PRAGMA integrity_check` + 关键表 `COUNT(*)` 对一下就有据可说。

> 别因为"2GB 太大"就放弃（2026-09-11 实证：我先这么判断，还写进了 commit message 说
> 「干净 worktree 跑不了全量」——结论错在没想到 `.backup`，3 秒的事）。
> 但也别因为库补上了就以为够了：那只是十三样里的第四样，全量门还缺后面九样。

**部署 worktree 不要带这一样。** 服务器有它自己的库，把本地种子库 rsync 上去是覆盖生产数据。
这一行只服务**本地验证**用的 worktree（跑 pytest / check_all）。

**`.venv` 绝不能用 symlink 顶替（部署路径）。** rsync 的 `--exclude '.venv/'` 尾斜杠只匹配目录、
不匹配 symlink，`--delete` 于是会把服务器上真实的 `/opt/fabric-agent/.venv` 一起删掉，后端当场死。
`update.sh` 有一道专门的门挡这个（2026-07-30 事故留下的）——撞上它不是脚本挑剔，是你正在复刻那次事故。

**但 `wt` 脚本给本地 worktree 挂的就是 symlink**（`.venv` / `node_modules` / `frontend/node_modules`），
本地跑测试没问题，只有一个陷阱必须先排：**若 venv 里有 editable install 或指回主仓的 `.pth`，
worktree 里 import 到的会是主树的代码，你那一轮"干净树验证"就静默变成了在量脏主树**。
开跑前先自证一行，别省：

```bash
wt run <用途> bash -c '.venv/bin/python -c "import <你的模块> as m; print(m.__file__)"'
# 打出来必须是 ~/.wt/... 的路径；打出主仓路径就立刻停，这轮验证无效
```

> 实证（2026-08-19）：一次干净部署连撞三样，每样一轮，两轮白 build。三样一次补齐才走通。

补齐顺序固定，写成一段就别再现推：

```bash
# ── 部署树（走 update.sh 那条路）──
REPO=<主仓>; WT=~/.wt/<repo>-deploy
git -C "$REPO" worktree add --detach "$WT" HEAD
for d in blocks fabrics artworks hdri; do rsync -a "$REPO/frontend/public/$d/" "$WT/frontend/public/$d/"; done
cp -a "$REPO/frontend/node_modules" "$WT/frontend/node_modules"
cp -a "$REPO/.venv" "$WT/.venv"          # cp，不是 ln -s（rsync --delete 会删服务器真目录）
# 部署树到此为止：**不带** data/*.db、不带 .env

# ── 门级判决树（要在干净树上跑整套 check_all）──
WT=~/.wt/<repo>-verify
bash ~/Desktop/colar-agents/scripts/wt new verify HEAD    # .venv / node_modules 由脚本 symlink
ln -sfn "$REPO/services/pattern/node_modules" "$WT/services/pattern/node_modules"   # 子服务的，wt 不管
ln -sfn "$REPO/.env" "$WT/.env"                            # symlink，密钥不落第二份
sqlite3 "$REPO/data/demo.db" ".backup '$WT/data/demo.db'"
for f in .deploy-history.jsonl .gate-results.json .routes-probe.json \
         .audit-deps.json .coverage-snapshot.json .mutation-check.json .e2e-smoke.json; do
  cp "$REPO/$f" "$WT/$f" 2>/dev/null
done
# 开跑前先自证 import 解析到 worktree（上一段那行），再 wt run verify bash scripts/check_all.sh
```

## 五、worktree 部署上线的是 HEAD，不是你手上的改动

干净 worktree 检出的是**最后一次 commit**。主仓里那些未提交的改动**不会上线**。
这是"本地改了线上没变"的一个隐蔽来源：部署全程绿灯，你以为改动生效了，其实它还躺在主仓的工作区里。

部署前用 `git log --oneline <上次 deploy tag>..HEAD` 确认这次到底带了哪些 commit 上去，
比事后从线上行为反推便宜得多。

## 六、历史落点，遇到了就迁

老的 worktree 散在四处：`/tmp/*`、`/private/tmp/*`、session scratchpad、仓内 `.claude/worktrees/`、
以及 `~/Desktop/创业/` 下和真项目混在一起的（`fabric-fabrics`、`deploy-9225960` 都是 worktree 不是项目）。
`wt ls` 会把不在 `~/.wt` 的标出来。清理前先 `wt ls` 看脏不脏——尤其 `~/Desktop` 下那些，长得像项目，误删代价高。
