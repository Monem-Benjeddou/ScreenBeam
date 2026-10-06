import AppKit
import Darwin
import Foundation

/// Crash and hang recovery.
///
/// - The app records fatal signals, uncaught exceptions and main-thread hangs (8 s) to `crash.txt`.
/// - A small watchdog process (this same binary, `--watchdog`) waits for the app to exit. If a crash
///   was recorded, it reopens the app, which then tells the user. A normal quit or a force quit
///   records nothing, so nothing is reopened.
/// - Crash-loop protection: a crash within 20 s of launch is "quick". After 2 quick crashes in a row
///   the app starts in safe mode (system sound capture off, the riskiest feature); after 3 the
///   watchdog stops reopening it.
enum Resilience {
    static let quickCrashWindow: TimeInterval = 20
    static let hangTimeout: TimeInterval = 8

    struct State: Codable {
        var quickCrashes = 0
        var safeMode = false
        /// Set by the watchdog when it reopened the app; cleared once the user has seen the notice.
        var reopenedAfter: String?
        var gaveUpAfter: String?
    }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ScreenBeam", isDirectory: true)
    }()
    private static var stateURL: URL { directory.appendingPathComponent("state.json") }
    private static var crashURL: URL { directory.appendingPathComponent("crash.txt") }

    // MARK: State file (atomic writes; an unreadable file is set aside, never overwritten)

    static func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL) else { return State() }
        if let state = try? JSONDecoder().decode(State.self, from: data) { return state }
        let aside = directory.appendingPathComponent("state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: stateURL, to: aside)
        Log.write("resilience: state file was unreadable; moved it to \(aside.lastPathComponent)")
        return State()
    }

    static func saveState(_ state: State) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Log.write("resilience: couldn't save state: \(error)")
        }
    }

    static func update(_ change: (inout State) -> Void) {
        var s = loadState()
        change(&s)
        saveState(s)
    }

    // MARK: In the app

    private static var crashFD: Int32 = -1
    private static var launchedAt = Date()

    /// Call first thing at launch (before any risky work).
    static func installInApp() {
        launchedAt = Date()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: crashURL)
        // Opened now so the signal handler only needs write(2), which is async-signal-safe.
        crashFD = open(crashURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig, Resilience_handleSignal)
        }
        NSSetUncaughtExceptionHandler { exception in
            Resilience.recordCrash("uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")")
        }
        startHangDetector()
        startWatchdogProcess()
        // Up for a while without crashing: the crash streak is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + quickCrashWindow) {
            if loadState().quickCrashes > 0 { update { $0.quickCrashes = 0 } }
        }
    }

    /// Normal quit: nothing to recover from.
    static func markCleanExit() {
        if crashFD >= 0 { close(crashFD); crashFD = -1 }
        try? FileManager.default.removeItem(at: crashURL)
    }

    static func recordCrash(_ what: String) {
        let uptime = Int(Date().timeIntervalSince(launchedAt))
        let line = "\(what) after \(uptime) s\n"
        if crashFD >= 0 {
            _ = line.withCString { write(crashFD, $0, strlen($0)) }
            fsync(crashFD)
        }
        Log.write("CRASH: \(line.trimmingCharacters(in: .newlines))")
        Log.flush()
    }

    fileprivate static func recordSignal(_ sig: Int32) {
        // Signal context: only async-signal-safe calls. Message is a static C string per signal.
        guard crashFD >= 0 else { return }
        let text: StaticString
        switch sig {
        case SIGSEGV: text = "signal SIGSEGV (bad memory access)\n"
        case SIGBUS: text = "signal SIGBUS (bad memory access)\n"
        case SIGILL: text = "signal SIGILL (illegal instruction)\n"
        case SIGTRAP: text = "signal SIGTRAP (Swift runtime error)\n"
        case SIGABRT: text = "signal SIGABRT (abort)\n"
        case SIGFPE: text = "signal SIGFPE (arithmetic error)\n"
        default: text = "fatal signal\n"
        }
        _ = write(crashFD, text.utf8Start, text.utf8CodeUnitCount)
        fsync(crashFD)
    }

    /// A frozen main thread can't recover by itself: record it and exit so the watchdog reopens us.
    private static func startHangDetector() {
        let thread = Thread {
            var lastPong = Date()
            var pending = false
            while true {
                Thread.sleep(forTimeInterval: 1)
                if !pending {
                    pending = true
                    DispatchQueue.main.async { lastPong = Date(); pending = false }
                }
                let silent = Date().timeIntervalSince(lastPong)
                if silent > hangTimeout {
                    recordCrash("main thread frozen for \(Int(silent)) s")
                    signal(SIGABRT, SIG_DFL)
                    abort()
                }
            }
        }
        thread.name = "ScreenBeam hang detector"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func startWatchdogProcess() {
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--watchdog", String(getpid()), Bundle.main.bundlePath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.write("resilience: couldn't start the watchdog: \(error)") }
    }

    // MARK: Watchdog process

    /// Runs in the `--watchdog` process: waits (no CPU) for the app to exit, then decides.
    static func runWatchdog(appPID: pid_t, bundlePath: String) -> Never {
        let started = Date()  // the app launches us at startup, so this is its launch time
        let kq = kqueue()
        var event = kevent(ident: UInt(appPID), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                           fflags: NOTE_EXIT, data: 0, udata: nil)
        if kq >= 0, kevent(kq, &event, 1, nil, 0, nil) == 0 {
            var out = kevent()
            _ = kevent(kq, nil, 0, &out, 1, nil)
        } else {
            while kill(appPID, 0) == 0 { sleep(2) }  // fallback if kqueue isn't available
        }

        UsbBridge.stopOrphanedTracker()  // the app's adb helper outlives a crash or force quit
        let crash = (try? String(contentsOf: crashURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !crash.isEmpty else { exit(0) }  // clean quit or force quit: leave it closed
        try? FileManager.default.removeItem(at: crashURL)

        let quick = Date().timeIntervalSince(started) < quickCrashWindow
        var state = loadState()
        state.quickCrashes = quick ? state.quickCrashes + 1 : 0
        if state.quickCrashes >= 3 {
            state.gaveUpAfter = crash
            state.reopenedAfter = nil
            saveState(state)
            Log.write("watchdog: 3 quick crashes in a row (\(crash)); not reopening")
            exit(0)
        }
        if state.quickCrashes >= 2 { state.safeMode = true }
        state.reopenedAfter = crash
        saveState(state)
        Log.write("watchdog: ScreenBeam stopped (\(crash)); reopening\(state.safeMode ? " in safe mode" : "")")
        Log.flush()
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", bundlePath]
        try? open.run()
        open.waitUntilExit()
        exit(0)
    }

    // MARK: Debug triggers (to prove recovery works on the real app)

    /// `defaults write com.screenbeam.mac debug.crashOnLaunch -int N`: crash ~2 s after the next N launches.
    /// `defaults write com.screenbeam.mac debug.hangOnLaunch -bool YES`: freeze the main thread once.
    static func runDebugTriggers() {
        let d = UserDefaults.standard
        let crashes = d.integer(forKey: "debug.crashOnLaunch")
        if crashes > 0 {
            d.set(crashes - 1, forKey: "debug.crashOnLaunch")
            d.synchronize()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Log.write("debug: crashing on purpose (\(crashes - 1) more to go)")
                let values: [Int] = []
                _ = values[crashes]  // out-of-range: a real Swift runtime trap
            }
        }
        if d.bool(forKey: "debug.hangOnLaunch") {
            d.removeObject(forKey: "debug.hangOnLaunch")
            d.synchronize()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Log.write("debug: freezing the main thread on purpose")
                while true { usleep(100_000) }
            }
        }
    }
}

/// C-compatible signal handler: record, then let the default action happen (crash report, exit).
private func Resilience_handleSignal(_ sig: Int32) {
    Resilience.recordSignal(sig)
    signal(sig, SIG_DFL)
    raise(sig)
}
