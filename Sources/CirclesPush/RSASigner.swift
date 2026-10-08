import Foundation
#if canImport(Security)
import Security
#elseif canImport(_CryptoExtras)
import _CryptoExtras
#endif

/// RS256 (RSASSA-PKCS1-v1_5 with SHA-256) signing from a PEM private key,
/// for FCM's service-account tokens. Apple platforms use the Security
/// framework; Linux and Android use swift-crypto's `_CryptoExtras`, whose
/// BoringSSL wrapper doesn't build against every Apple SDK. Unavailable on
/// Windows for now.
struct RSASigner: @unchecked Sendable {
    static var isAvailable: Bool {
        #if canImport(Security) || canImport(_CryptoExtras)
        true
        #else
        false
        #endif
    }

    #if canImport(Security)
    private let key: SecKey

    init(pem: String) throws(PushError) {
        guard let der = Self.der(fromPEM: pem) else { throw .invalidCredentials("RSA key: not PEM") }
        // SecKey wants PKCS#1; service-account keys are PKCS#8.
        let pkcs1 = pem.contains("BEGIN PRIVATE KEY") ? Self.pkcs1(fromPKCS8: der) : der
        guard let pkcs1 else { throw .invalidCredentials("RSA key: not a PKCS#8 RSA key") }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error) else {
            throw .invalidCredentials("RSA key: \(error?.takeRetainedValue().localizedDescription ?? "unreadable")")
        }
        self.key = key
    }

    func sign(_ data: Data) throws(PushError) -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) else {
            throw .invalidCredentials("RSA signing: \(error?.takeRetainedValue().localizedDescription ?? "failed")")
        }
        return signature as Data
    }
    #elseif canImport(_CryptoExtras)
    private let key: _RSA.Signing.PrivateKey

    init(pem: String) throws(PushError) {
        do {
            key = try _RSA.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw .invalidCredentials("RSA key: \(error)")
        }
    }

    func sign(_ data: Data) throws(PushError) -> Data {
        do {
            return try key.signature(for: data, padding: .insecurePKCS1v1_5).rawRepresentation
        } catch {
            throw .invalidCredentials("RSA signing: \(error)")
        }
    }
    #else
    init(pem: String) throws(PushError) {
        throw .invalidCredentials("FCM isn't available on this platform yet")
    }

    func sign(_ data: Data) throws(PushError) -> Data {
        throw .invalidCredentials("FCM isn't available on this platform yet")
    }
    #endif

    /// The DER bytes inside a PEM block.
    static func der(fromPEM pem: String) -> [UInt8]? {
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: String(body)).map(Array.init)
    }

    /// The PKCS#1 RSAPrivateKey inside a PKCS#8 PrivateKeyInfo:
    /// SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING key }.
    static func pkcs1(fromPKCS8 der: [UInt8]) -> [UInt8]? {
        guard let outer = element(der, at: 0), outer.tag == 0x30,
              let version = element(der, at: outer.content.lowerBound), version.tag == 0x02,
              let algorithm = element(der, at: version.end), algorithm.tag == 0x30,
              let key = element(der, at: algorithm.end), key.tag == 0x04
        else { return nil }
        return Array(der[key.content])
    }

    /// One DER element: its tag, content range and where the next begins.
    static func element(_ der: [UInt8], at index: Int) -> (tag: UInt8, content: Range<Int>, end: Int)? {
        guard index + 1 < der.count else { return nil }
        let tag = der[index]
        var length = Int(der[index + 1]), start = index + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...3).contains(count), start + count <= der.count else { return nil }
            length = der[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard start + length <= der.count else { return nil }
        return (tag, start..<(start + length), start + length)
    }
}
