import Foundation
import os
import CryptoKit

/// Talks to a remote `clauth daemon --listen` over its TLS REST API.
///
/// Three things make this different from an ordinary HTTPS client:
///
/// 1. **Pinned self-signed certificates.** Each container signs its own cert
///    (CN/SAN carry that host's name and IP), so there is no CA to trust. We
///    pin the SHA-256 of the DER and refuse anything else, surfacing a mismatch
///    to the user instead of silently accepting it — a container rebuild
///    re-signs legitimately, and that is the one case worth a prompt.
/// 2. **Long polling.** `GET /api/v1/status?wait=<secs>` with the current ETag
///    blocks until the feed actually changes, so a switch on the remote host
///    reaches us without a polling interval to lose time to.
/// 3. **Slow switches are normal.** `POST /api/v1/switch` waits on a
///    cross-process lock and may refresh a token, so it can legitimately take
///    tens of seconds. Timeouts are sized against the daemon's 120s connection
///    lifetime, not the 10s read bound.
actor RemoteClauthService {
    private let log = Logger(subsystem: "com.ccswitcher", category: "RemoteClauth")

    /// Longest the daemon will hold a `?wait=` request open.
    private static let maxWaitSeconds = 55
    /// The daemon's own connection lifetime; a switch must be allowed to use it.
    private static let switchTimeout: TimeInterval = 120
    /// Generous on purpose: these are shared GPU boxes running training and
    /// inference at load averages in the 70s, where the daemon can wait seconds
    /// for a slice. A tight timeout reported a busy box as offline.
    private static let statusTimeout: TimeInterval = 45

    private var etags: [UUID: String] = [:]

    // MARK: - Status

    /// One status read. `wait` turns it into a long poll that returns early
    /// only when the feed's content changes.
    func fetchStatus(host: RemoteHost, token: String, wait: Bool = false) async -> Result<ClauthStatus?, RemoteError> {
        guard let base = host.baseURL else {
            return .failure(.unreachable("bad host"))
        }
        var comps = URLComponents(url: base.appendingPathComponent("api/v1/status"),
                                  resolvingAgainstBaseURL: false)
        if wait {
            comps?.queryItems = [URLQueryItem(name: "wait", value: String(Self.maxWaitSeconds))]
        }
        guard let url = comps?.url else { return .failure(.unreachable("bad url")) }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = wait ? TimeInterval(Self.maxWaitSeconds) + 15 : Self.statusTimeout
        if wait, let tag = etags[host.id] {
            req.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }

        let delegate = PinnedCertificateDelegate(expected: host.pinnedFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.decodeFailed("no http response"))
            }
            if let tag = http.value(forHTTPHeaderField: "ETag") {
                etags[host.id] = tag
            }
            switch http.statusCode {
            case 304:
                // Nothing moved while we waited — keep the cached view.
                return .success(nil)
            case 200:
                do {
                    return .success(try JSONDecoder().decode(ClauthStatus.self, from: data))
                } catch {
                    return .failure(.decodeFailed(error.localizedDescription))
                }
            case 401, 403:
                return .failure(.unauthorized)
            default:
                return .failure(.unreachable("HTTP \(http.statusCode)"))
            }
        } catch {
            if let mismatch = delegate.mismatch {
                return .failure(mismatch)
            }
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    // MARK: - Switch

    /// Switch the remote daemon to `profile`.
    ///
    /// The daemon republishes `status.json` before answering, so a caller that
    /// re-reads the feed right after sees the new active profile rather than
    /// waiting for the next tick.
    func switchProfile(host: RemoteHost, token: String, profile: String) async -> Result<Void, RemoteError> {
        guard let base = host.baseURL else { return .failure(.unreachable("bad host")) }
        var req = URLRequest(url: base.appendingPathComponent("api/v1/switch"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["profile": profile])
        // Sized against the daemon's connection lifetime: a switch waits on the
        // state flock and may refresh a token before writing a single byte.
        req.timeoutInterval = Self.switchTimeout

        let delegate = PinnedCertificateDelegate(expected: host.pinnedFingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.decodeFailed("no http response"))
            }
            if http.statusCode == 200 {
                etags[host.id] = nil   // force the next read to rebuild
                return .success(())
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(.unauthorized)
            }
            // Refusals carry {"ok":false,"error":"<code>","reason":…}
            struct Refusal: Codable { let error: String?; let reason: String? }
            let body = try? JSONDecoder().decode(Refusal.self, from: data)
            return .failure(.switchRefused(code: body?.error ?? "HTTP \(http.statusCode)",
                                           reason: body?.reason))
        } catch {
            if let mismatch = delegate.mismatch { return .failure(mismatch) }
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    /// Read the certificate a host is currently presenting, without trusting it.
    /// Used by the settings UI to show a fingerprint for the user to accept.
    nonisolated static func probeFingerprint(host: RemoteHost) async -> String? {
        guard let base = host.baseURL else { return nil }
        let delegate = PinnedCertificateDelegate(expected: nil)   // record, don't enforce
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: base.appendingPathComponent("api/v1/health"))
        req.timeoutInterval = 10
        _ = try? await session.data(for: req)
        return delegate.observedFingerprint
    }
}

// MARK: - Certificate pinning

/// Accepts exactly one certificate: the one whose SHA-256 matches the pin.
/// With no pin it records what it saw and accepts once (trust on first use),
/// which is how a host is onboarded from the settings sheet.
private final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expected: String?
    private(set) var observedFingerprint: String?
    private(set) var mismatch: RemoteError?

    init(expected: String?) {
        self.expected = expected
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = der.sha256Hex
        observedFingerprint = fingerprint

        guard let expected, !expected.isEmpty else {
            // First contact: accept and report, so the user can pin it.
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        if fingerprint.caseInsensitiveCompare(expected) == .orderedSame {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            mismatch = .certificateMismatch(expected: expected, actual: fingerprint)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private extension Data {
    /// Uppercase hex SHA-256, matching what `openssl x509 -fingerprint -sha256`
    /// prints once the colons are stripped.
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02X", $0) }.joined()
    }
}
