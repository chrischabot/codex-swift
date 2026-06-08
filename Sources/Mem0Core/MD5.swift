import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Minimal, correct, dependency-free MD5 (RFC 1321) used for mem0's
/// content-hash deduplication of memory text (`hashlib.md5(text).hexdigest()`
/// in Python; `md5_hex` in the Rust port). A stable hex digest is all the
/// dedup path requires; this avoids taking a Crypto dependency in `Mem0Core`.
public enum MD5 {
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// Lowercase hex MD5 of a UTF-8 string.
    public static func hex(_ string: String) -> String {
        let d = digest(Array(string.utf8))
        var out = [UInt8](repeating: 0, count: d.count * 2)
        var j = 0
        for byte in d {
            out[j] = hexDigits[Int(byte >> 4)]; j += 1
            out[j] = hexDigits[Int(byte & 0x0f)]; j += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let k: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    private static func rotl(_ x: UInt32, _ c: UInt32) -> UInt32 {
        (x << c) | (x >> (32 - c))
    }

    private static func digest(_ input: [UInt8]) -> [UInt8] {
        var msg = input
        let originalBits = UInt64(input.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8((originalBits >> (8 &* UInt64(i))) & 0xff)) }

        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        var chunk = 0
        while chunk < msg.count {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let b = chunk + i * 4
                m[i] = UInt32(msg[b])
                    | (UInt32(msg[b + 1]) << 8)
                    | (UInt32(msg[b + 2]) << 16)
                    | (UInt32(msg[b + 3]) << 24)
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ rotl(f, s[i])
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
            chunk += 64
        }

        var out = [UInt8](repeating: 0, count: 16)
        @inline(__always) func put(_ x: UInt32, _ o: Int) {
            out[o] = UInt8(x & 0xff)
            out[o + 1] = UInt8((x >> 8) & 0xff)
            out[o + 2] = UInt8((x >> 16) & 0xff)
            out[o + 3] = UInt8((x >> 24) & 0xff)
        }
        put(a0, 0); put(b0, 4); put(c0, 8); put(d0, 12)
        return out
    }
}

/// Lowercase hex md5 digest of `s` (matches Python `hashlib.md5(...).hexdigest()`).
public func md5Hex(_ s: String) -> String { MD5.hex(s) }

/// Current UTC time as an RFC3339 string (matches Python
/// `datetime.now(timezone.utc).isoformat()` closely enough for storage/tests).
///
/// Uses `gmtime_r` + integer interpolation rather than `ISO8601DateFormatter`,
/// which allocates a formatter per call and dominated the add hot path.
public func nowUTCRFC3339() -> String {
    var tv = timeval()
    gettimeofday(&tv, nil)
    var secs = time_t(tv.tv_sec)
    var t = tm()
    gmtime_r(&secs, &t)

    var b = [UInt8](repeating: 0, count: 32)
    @inline(__always) func put(_ start: Int, _ value: Int, _ width: Int) {
        var v = value
        var i = start + width - 1
        while i >= start { b[i] = UInt8(48 + v % 10); v /= 10; i -= 1 }
    }
    put(0, Int(t.tm_year) + 1900, 4); b[4] = 45
    put(5, Int(t.tm_mon) + 1, 2); b[7] = 45
    put(8, Int(t.tm_mday), 2); b[10] = 84
    put(11, Int(t.tm_hour), 2); b[13] = 58
    put(14, Int(t.tm_min), 2); b[16] = 58
    put(17, Int(t.tm_sec), 2); b[19] = 46
    put(20, Int(tv.tv_usec), 6)
    b[26] = 43; b[27] = 48; b[28] = 48; b[29] = 58; b[30] = 48; b[31] = 48
    return String(decoding: b, as: UTF8.self)
}