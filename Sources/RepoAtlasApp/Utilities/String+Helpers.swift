import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

extension String {
    var normalizedWhitespace: String {
        replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func firstLines(_ count: Int) -> String {
        split(whereSeparator: { $0.isNewline })
            .prefix(count)
            .joined(separator: "\n")
    }

    var estimatedTokenCount: Int {
        max(1, count / 4)
    }

    var sha256Hex: String {
        Self.hashHex(for: self)
    }

    func containsAny(of terms: [String]) -> Bool {
        let lower = lowercased()
        return terms.contains { term in
            !term.isEmpty && lower.contains(term.lowercased())
        }
    }

    private static func hashHex(for string: String) -> String {
        let data = Data(string.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return fnv1a64Hex(data)
        #endif
    }

    private static func fnv1a64Hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x00000100000001B3
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }
}
