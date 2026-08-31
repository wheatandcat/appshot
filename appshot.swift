#!/usr/bin/env swift
//
// appshot — 起動中のアプリ名を渡すと、そのアプリのウィンドウを撮影して PNG に保存する。
//
// 使い方:
//   appshot <アプリ名の一部> [オプション]
//   appshot --apps                     # いま画面にある全ウィンドウを一覧表示する
//
//   -o <path>      出力先（省略時は ./<アプリ名>.png）
//   --all          該当するウィンドウを全部撮る（-1, -2 … が付く）
//   --list         撮らずに、該当したウィンドウの一覧だけ出す
//   --apps         アプリ名を指定せず、起動中の全アプリのウィンドウを --list と同じ形式で出す
//   --no-shadow    ウィンドウの影を付けない
//   --activate     撮る前にそのアプリを前面に出す
//   --delay <秒>   撮る前に待つ（メニューを開いた状態を撮りたいときなど）
//
// 仕組み:
//   CGWindowListCopyWindowInfo で画面上のウィンドウを引き、アプリ名で絞って CGWindowID を得る。
//   撮影自体は screencapture に -l <CGWindowID> を渡すだけ。ID 指定なので、他のウィンドウが
//   上に重なっていても写り込まず、⌘⇧4 + Space と同じ「角丸・影付き」の絵になる。
//
// 必要な権限:
//   実行元のターミナルに「画面収録」の許可が要る（システム設定 > プライバシーとセキュリティ）。
//   許可が無いとウィンドウのタイトルが空になり、撮影も失敗する。

import AppKit
import CoreGraphics
import Foundation

// ---------------------------------------------------------------- 引数

struct Options {
    var query = ""
    var out: String?
    var all = false
    var list = false
    var apps = false
    var shadow = true
    var activate = false
    var delay: Double = 0
}

func parseArgs(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "-o", "--out":
            i += 1
            o.out = i < argv.count ? argv[i] : nil
        case "--all": o.all = true
        case "--list": o.list = true
        case "--apps", "--list-apps": o.apps = true
        case "--no-shadow": o.shadow = false
        case "--activate": o.activate = true
        case "--delay":
            i += 1
            o.delay = i < argv.count ? (Double(argv[i]) ?? 0) : 0
        case "-h", "--help":
            print("""
            usage: appshot <アプリ名の一部> [-o out.png] [--all] [--list] [--no-shadow] [--activate] [--delay 0.5]
                   appshot --apps    # いま画面にある全ウィンドウを一覧表示する
            """)
            exit(0)
        default:
            if o.query.isEmpty { o.query = arg }
        }
        i += 1
    }
    return o
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// ---------------------------------------------------------------- ウィンドウ探索

struct Window {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let x: Int, y: Int, width: Int, height: Int

    var area: Int { width * height }
}

/// 画面に出ている「通常の」ウィンドウを集める。
/// レイヤー 0 だけを見て、メニューバーのポップオーバーや影用の極小ウィンドウは弾く。
func onScreenWindows() -> [Window] {
    // NSWorkspace 側の localizedName も見る。kCGWindowOwnerName は実行ファイル名寄りなので、
    // 「メモ」「Google Chrome」のような表示名でも引っかかるようにするため
    var localizedNames: [pid_t: String] = [:]
    for app in NSWorkspace.shared.runningApplications {
        if let name = app.localizedName { localizedNames[app.processIdentifier] = name }
    }

    guard let infos = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        fail("ウィンドウ一覧を取得できませんでした")
    }

    return infos.compactMap { info in
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              info[kCGWindowLayer as String] as? Int == 0,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Int, let y = bounds["Y"] as? Int,
              let w = bounds["Width"] as? Int, let h = bounds["Height"] as? Int,
              w > 100, h > 100
        else { return nil }

        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let app = localizedNames[pid] ?? owner
        // 画面収録の権限が無いとタイトルは空で返る
        let title = info[kCGWindowName as String] as? String ?? ""
        return Window(id: id, pid: pid, app: app, title: title, x: x, y: y, width: w, height: h)
    }
}

/// 一覧表示の 1 行。--list と --apps で同じ形式を使う
func describe(_ w: Window) -> String {
    // 画面収録の権限が無いとタイトルだけが空で返る（ID やサイズは取れる）
    let title = w.title.isEmpty ? "(タイトル不明: 画面収録の権限が要ります)" : w.title
    return "\(w.app)  id=\(w.id) pid=\(w.pid)  \(w.width)x\(w.height) @ \(w.x),\(w.y)  \(title)"
}

/// アプリ名の部分一致（大文字小文字は区別しない）。完全一致を優先し、あとは面積の大きい順
func match(_ windows: [Window], query: String) -> [Window] {
    let q = query.lowercased()
    let hits = windows.filter { $0.app.lowercased().contains(q) }
    return hits.sorted { a, b in
        let aExact = a.app.lowercased() == q, bExact = b.app.lowercased() == q
        if aExact != bExact { return aExact }
        return a.area > b.area
    }
}

// ---------------------------------------------------------------- 撮影

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> (status: Int32, stderr: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    let pipe = Pipe()
    task.standardError = pipe
    try? task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// -l（ウィンドウ指定）から順に試す。macOS のバージョンや権限の状態によっては
/// -l が "could not create image from window" で弾かれるので、最後は座標で切り取る
func capture(_ window: Window, to path: String, shadow: Bool) -> Bool {
    var methods: [(label: String, args: [String])] = []
    methods.append(("ウィンドウ", ["-x", "-l", String(window.id)]))
    if !shadow { methods.insert(("ウィンドウ（影なし）", ["-x", "-o", "-l", String(window.id)]), at: 0) }
    methods.append(("矩形", ["-x", "-R", "\(window.x),\(window.y),\(window.width),\(window.height)"]))

    try? FileManager.default.removeItem(atPath: path)
    for method in methods {
        let result = run("/usr/sbin/screencapture", method.args + [path])
        if result.status == 0, FileManager.default.fileExists(atPath: path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            // 権限が無いと真っ黒な画像になる。真っ黒は極端に軽いので大きさで弾く
            if size < 5_000 {
                FileHandle.standardError.write("  \(method.label): 画像が小さすぎます（画面収録の権限が無い可能性）\n".data(using: .utf8)!)
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            if method.label != "ウィンドウ" {
                print("  撮影方法: \(method.label)")
            }
            return true
        }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        FileHandle.standardError.write("  \(method.label): \(message.isEmpty ? "失敗" : message)\n".data(using: .utf8)!)
    }
    return false
}

func sanitize(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: " ", with: "-")
        .lowercased()
}

func outputPath(_ base: String?, app: String, index: Int, total: Int) -> String {
    let stem = base ?? "\(sanitize(app)).png"
    guard total > 1 else { return stem }
    let url = URL(fileURLWithPath: stem)
    let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
    return url.deletingPathExtension().path + "-\(index + 1)." + ext
}

// ---------------------------------------------------------------- main

let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))
let all = onScreenWindows()

// アプリ名を指定しない一覧表示。--list をアプリ名なしで呼んだときも同じ扱いにする
if opts.apps || (opts.list && opts.query.isEmpty) {
    guard !all.isEmpty else { fail("画面に通常のウィンドウがありません") }
    let sorted = all.sorted { ($0.app.lowercased(), -$0.area) < ($1.app.lowercased(), -$1.area) }
    for w in sorted { print(describe(w)) }
    exit(0)
}

guard !opts.query.isEmpty else {
    fail("アプリ名を渡してください: appshot <アプリ名の一部>（一覧だけなら appshot --apps）")
}

let hits = match(all, query: opts.query)

guard !hits.isEmpty else {
    let names = Set(all.map(\.app)).sorted().joined(separator: ", ")
    fail("""
    「\(opts.query)」に一致するウィンドウが画面にありません。
    最小化中・別の Space にある場合も見つかりません。
    いま画面にあるアプリ: \(names)
    """)
}

if opts.list {
    for w in hits { print(describe(w)) }
    exit(0)
}

if opts.activate {
    if let app = NSRunningApplication(processIdentifier: hits[0].pid) {
        app.activate()
        Thread.sleep(forTimeInterval: 0.4)
    }
}
if opts.delay > 0 { Thread.sleep(forTimeInterval: opts.delay) }

let targets = opts.all ? hits : [hits[0]]
var failed = 0
for (i, window) in targets.enumerated() {
    let path = outputPath(opts.out, app: window.app, index: i, total: targets.count)
    if capture(window, to: path, shadow: opts.shadow) {
        print("\(path)  ← \(window.app) (\(window.width)x\(window.height))")
    } else {
        failed += 1
        FileHandle.standardError.write("撮影できませんでした: \(window.app) id=\(window.id)\n".data(using: .utf8)!)
    }
}

if failed > 0 {
    FileHandle.standardError.write("""
    「画面収録」の許可があるか確認してください（システム設定 > プライバシーとセキュリティ > 画面収録）。
    同じターミナルで `screencapture -x /tmp/test.png` が通るかを見ると切り分けられます。
    """.data(using: .utf8)!)
    exit(1)
}
