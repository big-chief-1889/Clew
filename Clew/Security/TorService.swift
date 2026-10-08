import AppKit
import Darwin
import Foundation
import Observation

/// Runs Arti (the Tor Project's Tor client) as a helper process inside Clew's sandbox,
/// listening only on this Mac. Wallet traffic is sent through it as a SOCKS proxy.
@MainActor @Observable
final class TorService {
    enum State: Equatable {
        case off, starting, ready, failed(String)
    }

    private(set) var state: State = .off { didSet { if state != oldValue { onChange?() } } }
    private(set) var port: Int? { didSet { if port != oldValue { onChange?() } } }
    /// Called whenever the state or port changes, so the wallet route can follow.
    @ObservationIgnored var onChange: (() -> Void)?

    private var process: Process?
    private var startedAt = Date()
    private var recentLog = ""

    /// A port nothing listens on: wallet traffic sent here fails instead of going out directly.
    static let deadProxy = "socks5h://127.0.0.1:1"

    /// The proxy for wallet traffic: Tor's port once it's ready, the dead port otherwise.
    /// `isolation` (e.g. a wallet id) is sent as the SOCKS username; Tor gives each different one
    /// its own circuits, so different wallets don't share an exit address.
    func proxyURL(isolation: String?) -> String {
        guard state == .ready, let port else { return Self.deadProxy }
        let user = isolation.map { "\($0):clew@" } ?? ""
        return "socks5h://\(user)127.0.0.1:\(port)"
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Starts Tor and returns once it can carry traffic (or failed).
    func start() async {
        if process == nil { launch() }
        while state == .starting { try? await Task.sleep(for: .milliseconds(200)) }
    }

    func stop() {
        let old = process
        process = nil   // its exit is now expected; see `exited`
        old?.terminate()
        port = nil
        state = .off
        if let directory = try? Self.directory() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("arti.pid"))
        }
    }

    private func launch() {
        do {
            let directory = try Self.directory()
            Self.stopLeftoverTor(in: directory)
            let portFile = directory.appendingPathComponent("port_info.json")
            try? FileManager.default.removeItem(at: portFile)
            let config = directory.appendingPathComponent("arti.toml")
            try """
            [proxy]
            socks_listen = "127.0.0.1:auto"
            dns_listen = 0
            [storage]
            cache_dir = \(Self.tomlString(directory.appendingPathComponent("cache").path))
            state_dir = \(Self.tomlString(directory.appendingPathComponent("state").path))
            port_info_file = \(Self.tomlString(portFile.path))
            [logging]
            console = "info"
            """.write(to: config, atomically: true, encoding: .utf8)

            guard let executable = Bundle.main.url(forAuxiliaryExecutable: "arti") else {
                state = .failed("The Tor component is missing from Clew.app.")
                return
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["proxy", "-c", config.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil  // Tor exited
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { self?.read(log: text, portFile: portFile) }
            }
            process.terminationHandler = { [weak self] ended in
                DispatchQueue.main.async { self?.exited(ended) }
            }

            startedAt = Date()
            recentLog = ""
            state = .starting
            try process.run()
            self.process = process
            // Remember it, so a Tor left running by a crash is stopped next time.
            try? String(process.processIdentifier).write(to: directory.appendingPathComponent("arti.pid"),
                                                         atomically: true, encoding: .utf8)
            watchdog()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func read(log text: String, portFile: URL) {
        guard state == .starting else { return }
        recentLog = String((recentLog + text).suffix(4096))  // the marker may span two reads
        if recentLog.contains("Sufficiently bootstrapped") {
            recentLog = ""
            if let found = Self.socksPort(in: portFile) {
                port = found
                state = .ready
            } else {
                stop()
                state = .failed("Tor started but didn't report its port.")
            }
        }
    }

    /// Only the current Tor process's exit matters; one that was stopped on purpose (or replaced
    /// by a newer one) is ignored.
    private func exited(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        port = nil
        state = .failed("Tor stopped unexpectedly.")
    }

    /// Gives up if Tor hasn't connected after two minutes (e.g. no internet, or Tor is blocked).
    private func watchdog() {
        let started = startedAt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, self.state == .starting, self.startedAt == started else { return }
            self.stop()
            self.state = .failed("Couldn't connect to the Tor network.")
        }
    }

    /// Stops a Tor helper left running by an earlier Clew that crashed or was force-quit, but only
    /// if that process really is Clew's own bundled Tor.
    private static func stopLeftoverTor(in directory: URL) {
        let pidFile = directory.appendingPathComponent("arti.pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              let ours = Bundle.main.url(forAuxiliaryExecutable: "arti")?.resolvingSymlinksInPath().path
        else { return }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path == ours
        else { return }
        kill(pid, SIGTERM)
    }

    /// A TOML basic string, with quotes and backslashes escaped.
    private static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Reads Arti's port file: {"ports":[{"protocol":"socks","address":"inet:127.0.0.1:57255"}]}
    private static func socksPort(in file: URL) -> Int? {
        struct PortInfo: Decodable { struct Port: Decodable { let protocol_: String; let address: String
            enum CodingKeys: String, CodingKey { case protocol_ = "protocol", address } }
            let ports: [Port] }
        guard let data = try? Data(contentsOf: file),
              let info = try? JSONDecoder().decode(PortInfo.self, from: data),
              let address = info.ports.first(where: { $0.protocol_ == "socks" })?.address,
              address.hasPrefix("inet:127.0.0.1:") else { return nil }
        return Int(address.split(separator: ":").last ?? "")
    }

    /// Application Support/Clew/tor, private to this user.
    private static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Clew/tor", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }
}
