// 把目录/文件标记为「不参与 iCloud 同步」，无需把它移出 ~/Desktop 或 ~/Documents。
//
// 为什么需要它：开着「桌面与文稿」同步时，~/Desktop 下的一切都会被 iCloud 逐份上传，
// 且本地保留完整副本——等于每个大文件占双份。对开发目录尤其致命：
//   · SQLite 库每次写入触发全量重传（2026-09-01 实测 1.9G 的 demo.db 按 0.42MB/s 上行
//     要传 77 分钟，而每次写库都把进度重置，iCloud 永远追不上）
//   · node_modules / .git 是海量小文件，同步极慢
//   · .next 会被造出「xxx 2.ts」式重名副本，直接打红 tsc（见 fabric-agent-demo/scripts/check_all.sh）
//
// 为什么不用 .nosync 后缀：那是社区约定，要改目录名，牵动代码里的路径。
// 本工具用的 NSURLUbiquitousItemIsExcludedFromSyncKey 是 Apple 官方可写资源属性（macOS 11+），
// 不改名、不移动、立即生效。2026-09-01 实测：被排除目录内新建的文件，fileproviderctl evaluate
// 完全不认识（已脱离同步域）；同一时刻对照组的普通 Desktop 文件则是 isUploading=1。
//
// 注意：排除后该路径不再有 iCloud 备份。只对「可重建」或「另有备份」的目录用。
//
// 用法：
//   swift icloud_exclude.swift <路径>...            # 排除
//   swift icloud_exclude.swift --status <路径>...   # 只看状态
//   swift icloud_exclude.swift --undo <路径>...     # 取消排除
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("用法: swift icloud_exclude.swift [--status|--undo] <路径>...")
    exit(2)
}
var mode = "set"
var paths = [String]()
for a in args {
    switch a {
    case "--status": mode = "status"
    case "--undo":   mode = "undo"
    default:         paths.append(a)
    }
}
guard !paths.isEmpty else { print("✗ 没有给出路径"); exit(2) }

var failed = false
for p in paths {
    var url = URL(fileURLWithPath: p)
    guard FileManager.default.fileExists(atPath: p) else {
        print("✗ 不存在: \(p)"); failed = true; continue
    }
    // set 模式下，原本就已排除的静默跳过——这样批量巡检的输出天然等于「本次新修复的」，
    // 调用方不必解析路径（~/Desktop 下大量中文与空格路径，按空格解析必碎）。
    if mode == "set",
       let cur = try? url.resourceValues(forKeys: [.ubiquitousItemIsExcludedFromSyncKey]).ubiquitousItemIsExcludedFromSync,
       cur {
        continue
    }
    if mode != "status" {
        do {
            var rv = URLResourceValues()
            rv.ubiquitousItemIsExcludedFromSync = (mode == "set")
            try url.setResourceValues(rv)
        } catch {
            print("✗ 设置失败 \(p): \(error.localizedDescription)"); failed = true; continue
        }
    }
    // 回读确认，不信任写入的返回值
    do {
        let v = try url.resourceValues(forKeys: [.ubiquitousItemIsExcludedFromSyncKey])
        let ex = v.ubiquitousItemIsExcludedFromSync ?? false
        print("\(ex ? "已排除" : "同步中")  \(p)")
    } catch {
        print("✗ 回读失败 \(p): \(error.localizedDescription)"); failed = true
    }
}
exit(failed ? 1 : 0)
