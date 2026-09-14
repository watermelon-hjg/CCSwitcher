import Foundation
import os

/// Fills in a dev box's settings from its SSH alias alone.
///
/// Everything the app needs is already discoverable over the SSH connection the
/// user has configured: the daemon prints its own bearer token, the box knows
/// its own address, and the certificate can be read from the daemon directly.
/// Making someone retype a 64-character token and a 64-hex fingerprint by hand
/// only invites typos that surface later as "unauthorized" or a pin mismatch.
enum RemoteHostDetector {
    private static let log = Logger(subsystem: "com.ccswitcher", category: "Detect")

    struct Detected {
        let alias: String
        let address: String
        let token: String
        /// Read from the daemon over SSH rather than from a TLS handshake. The
        /// SSH channel is already authenticated, so this is a stronger pin than
        /// trusting whatever happens to answer the port first.
        let fingerprint: String
        /// True when the Mac could not reach `address:8443` directly — some of
        /// these pods answer ICMP but have every TCP port blocked from outside
        /// the cluster.
        let needsTunnel: Bool
        /// Set when something answered that port with a *different* certificate
        /// than the box's own daemon — a port collision or a stale forward, not
        /// the machine we think we are talking to.
        let impostor: String?
    }

    enum Failure: LocalizedError {
        case ssh(String)
        case noClauth
        case noDaemon
        case incomplete

        var errorDescription: String? {
            switch self {
            case .ssh(let detail):
                return String(format: String(localized: "SSH to this alias failed: %@", bundle: L10n.bundle), detail)
            case .noClauth:
                return String(localized: "No clauth binary found on that box.", bundle: L10n.bundle)
            case .noDaemon:
                return String(localized: "clauth is installed but its daemon is not listening on 8443.", bundle: L10n.bundle)
            case .incomplete:
                return String(localized: "The box answered but did not return a usable token and certificate.", bundle: L10n.bundle)
            }
        }
    }

    /// Runs on the box. Keys are printed as `KEY=value` lines.
    ///
    /// The daemon is brought up first, because its own command line is then the
    /// most reliable way to locate the `clauth` binary — it is not on the
    /// non-interactive PATH (not even under a login shell), and it is installed
    /// wherever that box happens to keep it.
    private static let probeScript = """
    if ! curl -sk -o /dev/null --max-time 8 https://127.0.0.1:8443/api/v1/health; then
      # The supervisor knows this box's certificate and install paths. Its
      # directory is named after the host, and may sit on a volume shared with
      # other boxes — so match on hostname, never a bare glob.
      for s in "$HOME/.clauth/supervise.sh" /*/volumes/*/*/work/.clauth-$(hostname)/supervise.sh; do
        [ -f "$s" ] && bash "$s" --ensure && sleep 6 && break
      done
    fi
    curl -sk -o /dev/null --max-time 8 https://127.0.0.1:8443/api/v1/health || { echo "ERR=no-daemon"; exit 0; }
    CL="$(tr '\0' '\n' < /proc/$(pgrep -f 'clauth daemon --listen' | head -1)/cmdline 2>/dev/null | head -1)"
    [ -x "$CL" ] || CL="$(command -v clauth 2>/dev/null)"
    [ -x "$CL" ] || { echo "ERR=no-clauth"; exit 0; }
    echo "IP=$(hostname -I | awk '{print $1}')"
    echo "TOKEN=$("$CL" daemon --print-token 2>/dev/null | tr -d '\r\n')"
    echo "FP=$(openssl s_client -connect 127.0.0.1:8443 </dev/null 2>/dev/null \
          | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
    """

    static func detect(alias: String) async throws -> Detected {
        let output = try await runSSH(alias: alias, script: probeScript)
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch fields["ERR"] {
        case "no-clauth": throw Failure.noClauth
        case "no-daemon": throw Failure.noDaemon
        default: break
        }
        guard let ip = fields["IP"], !ip.isEmpty,
              let token = fields["TOKEN"], token.count >= 32,
              let fingerprint = fields["FP"], fingerprint.count == 64
        else { throw Failure.incomplete }

        // Can this Mac reach the daemon without a tunnel? A failed probe is the
        // answer, not an error — several of these boxes are only reachable
        // through the jump host.
        let direct = RemoteHost(name: alias, host: ip, port: 8443)
        let overTheWire = await RemoteClauthService.probeFingerprint(host: direct)
        log.info("[\(alias, privacy: .public)] direct probe \(overTheWire == nil ? "failed" : "ok", privacy: .public)")

        return Detected(alias: alias,
                        address: ip,
                        token: token,
                        fingerprint: fingerprint,
                        needsTunnel: overTheWire == nil,
                        impostor: (overTheWire != nil && overTheWire != fingerprint) ? overTheWire : nil)
    }

    private static func runSSH(alias: String, script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=25",
                "-o", "StrictHostKeyChecking=accept-new",
                alias, "bash -s"
            ]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            // A box under load, or an alias that hangs on the jump host, must
            // not leave the sheet spinning forever.
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)

            do {
                try process.run()
            } catch {
                watchdog.cancel()
                continuation.resume(throwing: Failure.ssh(error.localizedDescription))
                return
            }
            input.fileHandleForWriting.write(Data(script.utf8))
            input.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            guard process.terminationStatus == 0 else {
                // dpkg warns noisily on these images; the last real line is the
                // one worth showing.
                let detail = String(decoding: errData, as: UTF8.self)
                    .split(separator: "\n")
                    .last { !$0.hasPrefix("dpkg:") }
                    .map(String.init) ?? "exit \(process.terminationStatus)"
                continuation.resume(throwing: Failure.ssh(detail))
                return
            }
            continuation.resume(returning: String(decoding: data, as: UTF8.self))
        }
    }
}
