import Foundation

/// Ensures a TLS cert+key exist for the gateway. If either file is missing, a
/// self-signed leaf is generated via `openssl` with a Subject Alternative Name
/// covering localhost + loopback IPs (Chrome ignores CN and REQUIRES a SAN, so
/// a bare `-subj /CN=localhost` cert would be rejected).
///
/// This keeps the single-binary UX: `codexd --listen-web` works with no manual
/// setup. For a Chrome-TRUSTED local cert (no warning), point `certPath`/
/// `keyPath` at an `mkcert`-issued leaf instead — see docs/webgateway/.
enum DevCert {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func ensure(certPath: String, keyPath: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: certPath) && fm.fileExists(atPath: keyPath) { return }

        let dir = (certPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        // Write a temporary OpenSSL config carrying the SAN (the `-addext` flag
        // is not supported by every LibreSSL build shipped on macOS, so use a
        // config file which is portable across OpenSSL and LibreSSL).
        let cfgPath = dir + "/openssl-dev.cnf"
        let cfg = """
        [req]
        distinguished_name = dn
        x509_extensions = v3
        prompt = no
        [dn]
        CN = localhost
        [v3]
        subjectAltName = @san
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        [san]
        DNS.1 = localhost
        IP.1 = 127.0.0.1
        IP.2 = ::1
        """
        try cfg.write(toFile: cfgPath, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: cfgPath) }

        // Pre-create the key file with 0600 so openssl (which honors umask and
        // would otherwise create it world-readable, then we'd chmod with a race
        // window) writes into a private inode — `-keyout` truncates but does not
        // reset the mode of an existing file.
        try? fm.removeItem(atPath: keyPath)
        guard fm.createFile(atPath: keyPath, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else {
            throw Failure(message: "could not create private key file at \(keyPath)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        proc.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath, "-out", certPath,
            "-days", "825", "-config", cfgPath,
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? "unknown"
            throw Failure(message: "openssl failed to generate dev cert (status \(proc.terminationStatus)): \(err)")
        }
        // Re-assert + verify 0600 (fail closed if the key is group/world readable).
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
        if let mode = (try? fm.attributesOfItem(atPath: keyPath)[.posixPermissions] as? NSNumber)?.intValue,
           (mode & 0o077) != 0 {
            throw Failure(message: "private key \(keyPath) has insecure permissions \(String(mode, radix: 8))")
        }
    }
}
