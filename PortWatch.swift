import AppKit
import Darwin
import SwiftUI

// MARK: - Model

struct Listener {
    let port: Int
    let pid: Int32
    let command: String
    let uid: uid_t
    var cwd: String?

    var rowID: String { "\(pid):\(port)" }
    var isMine: Bool { uid == getuid() }
    var folderName: String? { cwd.map { ($0 as NSString).lastPathComponent } }

    /// Search: every word of the query must appear in the port, the process name, the PID or the folder path
    /// (case-insensitive), so "node 30" finds node listening on 3000.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        if words.isEmpty { return true }
        let haystack = "\(port) \(pid) \(command) \(cwd ?? "")".lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Scanner (shells out to lsof; no privileges needed for own processes)

enum Scanner {
    private static let lsofPath = "/usr/sbin/lsof"
    private static let timeoutSeconds = 5.0

    static func listeners() -> [Listener] {
        let out = run(["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcun"])
        var found = parse(out)
        let cwds = workingDirectories(for: found.map(\.pid))
        for i in found.indices { found[i].cwd = cwds[found[i].pid] }
        return found.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// lsof -F output: `p` starts a process, `c`/`u` describe it, `n` is one socket name.
    static func parse(_ text: String) -> [Listener] {
        var result: [Listener] = []
        var seen = Set<String>()
        var pid: Int32 = 0, command = "", uid: uid_t = 0
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0; command = ""; uid = 0
            case "c": command = value
            case "u": uid = uid_t(value) ?? 0
            case "n":
                guard pid > 0, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                // IPv4 and IPv6 sockets of one process show up twice; keep one row.
                if seen.insert("\(pid):\(port)").inserted {
                    result.append(Listener(port: port, pid: pid, command: command, uid: uid, cwd: nil))
                }
            default: break
            }
        }
        return result
    }

    private static func workingDirectories(for pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = Set(pids).map(String.init).joined(separator: ",")
        let out = run(["-a", "-d", "cwd", "-p", list, "-Fpn"])
        var map: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in out.split(separator: "\n") {
            let value = String(line.dropFirst())
            if line.first == "p" { pid = Int32(value) ?? 0 }
            else if line.first == "n", pid > 0 { map[pid] = value }
        }
        return map
    }

    private static func run(_ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: lsofPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        // lsof can hang on stale network mounts; never block the menu on it.
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Store

@MainActor
final class PortStore: ObservableObject {
    @Published private(set) var listeners: [Listener] = []
    @Published var message: String?
    var onCountChange: ((Int) -> Void)?

    func refresh() {
        Task.detached(priority: .utility) {
            let list = Scanner.listeners()
            await MainActor.run { [weak self] in
                self?.listeners = list
                self?.onCountChange?(list.count)
            }
        }
    }

    func stop(_ l: Listener, force: Bool) {
        Task.detached(priority: .userInitiated) {
            // Re-check ownership right before signalling: the PID may have been reused since the scan.
            let stillThere = Scanner.listeners().contains { $0.pid == l.pid && $0.isMine }
            var error: String?
            if !stillThere {
                error = "Process \(l.pid) is no longer listening."
            } else if l.pid <= 1 || kill(l.pid, force ? SIGKILL : SIGTERM) != 0 {
                error = "Could not stop \(l.command) (\(l.pid)): \(String(cString: strerror(errno)))"
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            let result = error
            await MainActor.run { [weak self] in
                self?.message = result
                self?.refresh()
            }
        }
    }
}

// MARK: - Views

struct PortRow: View {
    let l: Listener
    let store: PortStore

    var body: some View {
        HStack(spacing: 8) {
            Text(String(l.port))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(l.command).font(.callout).lineLimit(1)
                Text("PID \(l.pid)" + (l.folderName.map { " · \($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(l.cwd ?? "")          // full path on hover
            Spacer(minLength: 4)
            Button { if let u = URL(string: "http://localhost:\(l.port)") { NSWorkspace.shared.open(u) } }
                label: { Image(systemName: "safari") }
                .help("Open http://localhost:\(l.port)")
            if l.isMine {
                Button("Stop") { store.stop(l, force: false) }.help("Send SIGTERM (graceful)")
                Button("Kill") { store.stop(l, force: true) }.help("Send SIGKILL (immediate)").tint(.red)
            } else {
                Text("other user").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.vertical, 1)
    }
}

struct PortsView: View {
    @ObservedObject var store: PortStore
    @State private var query = ""
    @FocusState private var searching: Bool

    private var shown: [Listener] { store.listeners.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(query.isEmpty ? "Listening ports (\(store.listeners.count))"
                                   : "Listening ports (\(shown.count) of \(store.listeners.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            .padding(8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search port, name, PID or folder", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onExitCommand { query = "" }          // Esc clears
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            // Cmd+F puts the cursor in the search field
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0)
            Divider()
            if store.listeners.isEmpty {
                Text("No listening ports").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text("No port matches “\(query)”").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // one row per (process, port): a process listening on two ports has two rows
                List(shown, id: \.rowID) { l in PortRow(l: l, store: store) }
                    .listStyle(.plain)
            }
            if let msg = store.message {
                Divider()
                Text(msg).font(.caption).foregroundStyle(.red).padding(8)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit PortWatch") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link).controlSize(.small).padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = PortStore()
    private var window: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Listening ports")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(showWindow)
        }
        store.onCountChange = { [weak self] n in
            self?.statusItem.button?.title = n == 0 ? "" : " \(n)"
        }
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    // A normal, resizable desktop window; clicking the icon again just brings it to the front.
    @objc private func showWindow() {
        let win = window ?? makeWindow()
        window = win
        store.message = nil
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "PortWatch"
        win.contentViewController = NSHostingController(rootView: PortsView(store: store))
        win.setContentSize(NSSize(width: 430, height: 280))
        win.minSize = NSSize(width: 380, height: 160)
        win.isReleasedWhenClosed = false   // closing hides it; the menu bar item stays
        win.center()
        return win
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
