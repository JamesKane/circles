import Testing
import Foundation
import Synchronization
import Crypto
#if canImport(Security)
import Security
#elseif canImport(_CryptoExtras)
import _CryptoExtras
#endif
import CirclesCore
import CirclesCrypto
import CirclesNet
@testable import CirclesPush

func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("circles-push-\(UUID().uuidString)").appendingPathComponent("registrations.cbor")
}

/// Records requests and answers from a script.
final class FakeHTTP: HTTPPoster, Sendable {
    struct Request: Sendable { var url: URL; var headers: [String: String]; var body: [UInt8] }
    let requests = Mutex<[Request]>([])
    let respond: @Sendable (URL) -> (Int, [UInt8])

    init(respond: @escaping @Sendable (URL) -> (Int, [UInt8]) = { _ in (200, []) }) {
        self.respond = respond
    }

    func post(_ url: URL, headers: [String: String], body: [UInt8]) async throws -> (status: Int, body: [UInt8]) {
        requests.withLock { $0.append(Request(url: url, headers: headers, body: body)) }
        return respond(url)
    }
}

/// A 2048-bit RSA key for tests only, in PKCS#8 as Google issues them…
let testRSAKey = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDYTwBLldTSkLwq
VyW40Ahs2mUMpY5F4kWE5bU9UM00jkwnAlndQP9GOHXKk/fxbff8xoLfu3TO6KcJ
sF/q429uOOaqU8V32v75PwCupoPb6m1ppgnpaX/g+SchlP7Yv1YZcQPVsIvyWV8S
IwWWYeiGvKPxolSewBHLYkszn8GyecGIKxdLS84xWctVhDzr2Fk2YjwOG8myTfL/
g40Bcmkug1+OGzAfPwszGaNo1XN0XnQ1AOWNdf6HXebDnEnNhGgR/24iS3+6HS4u
PlUlaI9V/meRW+GuntBBp1O7b15C8u3zcttSCUeFqEspSu40vQAI8VjP0/QcNnvT
U9bHP7IZAgMBAAECggEAD+K1ZdeqGpCwkPd3eLwmckATvbsG2NEGQ/1OsyMU/vAY
XaEJknsshC6vT+JQCjYGSVUW1XGB4ZQqeEawtKJhU5nwLsAaN3Qo14st9KWb93Ge
+WxNPAwYbSA/JHM5yBc9Ln8jRfVCQdkYZ0+VIHcuSX7fF2bRihsW83XTigYIhp/R
1XczArx1wGG8rz/6SDYgO9seVx0wm6GOePghTaD9q39V6GmmVxCn2tiJjJBukDzf
KfaYuaN6lek7VRL4kYTe2nm1MKuTXV+rftMOwzIfKL7brMWDAXGANnVz3vX0WfhF
U56ZSpsFf2LlXiu49LanB/fK+l7xIkInYTit9zWU1QKBgQD8eGk5OMDu9PEulpxT
QUhQCSVAujpFdfnPVKszPDcGjhIxZPudyu4xRlMB5GohQSWkudKDB15j5Ny+dfff
GNg+tAAz3Oa3FYkF+nN/yM59IaVZZdATe9oNenzfOCy4t+rvV3+yfW3LQ8TY/1WO
CsqibJOFUr2cITiE7oi0tp+iGwKBgQDbVSrkFhTEEI4ANdroAeCzRujup/+Hs9YT
QdFDEkmfxLeHNn9TULL9YB9iAP1RofBYZi8lZZUsCJWfUxrIL7qplo9+pwIrQi0+
JKg6rH+QYGM+zgeJG5q02DRHES26BmWyxGCuUyDFsKkp4Ela0l1lZYmoLxAX+6sP
xC9wJxhf2wKBgQDR4vx/IKpsPV9f/r+ZCxWly+SXafpVkp2J+naVEoMgRO3k+HGh
nXnlpvQNB6ofWTyFNCJI4dBbtYC6KfJWGx5zCkt80jFPlWyjdrGcUwEuz9DZgCW6
fOUq/WBgZh/vtJ5wOUqkxVeIex9j0ul6O4h3/VGqrb2J1ahaAr/NlGEjbwKBgQCX
u5GSfNwczz8NUjSAcFwcah/Wio4yOO0OIWg9ODeKubIlbkQjRR6uPoM3b2vPv3Hg
FcDj5CSQc9fegsVyW+KMU8YtXigX+Q4HgaCIBrGxFZ1S44E/DsO1/CQeTfoOSUKt
q0EfGA8B9Dby62CT3hgSf2391aESll4+5//RXJp2JQKBgDJQttbRKmDMfyRo2sP/
MmMUCr5z3YV+93zaaEcwvm8NoINjXjc68DBA5Gh4sZSp7DnLBwGLLlNgdVzN2UG7
/e0E328qdmXOQiQPeInkgsnbaq9tsI/ZlDxlaXd3Og8rbicX52RAin1G5cMdflhd
79ITKyor7dZ4Sfd49uTzvBdu
-----END PRIVATE KEY-----
"""
/// …and the same key in PKCS#1, as converted by OpenSSL.
let testRSAKeyPKCS1 = Data(base64Encoded: "MIIEpAIBAAKCAQEA2E8AS5XU0pC8KlcluNAIbNplDKWOReJFhOW1PVDNNI5MJwJZ3UD/Rjh1ypP38W33/MaC37t0zuinCbBf6uNvbjjmqlPFd9r++T8ArqaD2+ptaaYJ6Wl/4PknIZT+2L9WGXED1bCL8llfEiMFlmHohryj8aJUnsARy2JLM5/BsnnBiCsXS0vOMVnLVYQ869hZNmI8DhvJsk3y/4ONAXJpLoNfjhswHz8LMxmjaNVzdF50NQDljXX+h13mw5xJzYRoEf9uIkt/uh0uLj5VJWiPVf5nkVvhrp7QQadTu29eQvLt83LbUglHhahLKUruNL0ACPFYz9P0HDZ701PWxz+yGQIDAQABAoIBAA/itWXXqhqQsJD3d3i8JnJAE727BtjRBkP9TrMjFP7wGF2hCZJ7LIQur0/iUAo2BklVFtVxgeGUKnhGsLSiYVOZ8C7AGjd0KNeLLfSlm/dxnvlsTTwMGG0gPyRzOcgXPS5/I0X1QkHZGGdPlSB3Lkl+3xdm0YobFvN104oGCIaf0dV3MwK8dcBhvK8/+kg2IDvbHlcdMJuhjnj4IU2g/at/VehpplcQp9rYiYyQbpA83yn2mLmjepXpO1US+JGE3tp5tTCrk11fq37TDsMyHyi+26zFgwFxgDZ1c9719Fn4RVOemUqbBX9i5V4ruPS2pwf3yvpe8SJCJ2E4rfc1lNUCgYEA/HhpOTjA7vTxLpacU0FIUAklQLo6RXX5z1SrMzw3Bo4SMWT7ncruMUZTAeRqIUElpLnSgwdeY+TcvnX33xjYPrQAM9zmtxWJBfpzf8jOfSGlWWXQE3vaDXp83zgsuLfq71d/sn1ty0PE2P9VjgrKomyThVK9nCE4hO6ItLafohsCgYEA21Uq5BYUxBCOADXa6AHgs0bo7qf/h7PWE0HRQxJJn8S3hzZ/U1Cy/WAfYgD9UaHwWGYvJWWVLAiVn1MayC+6qZaPfqcCK0ItPiSoOqx/kGBjPs4HiRuatNg0RxEtugZlssRgrlMgxbCpKeBJWtJdZWWJqC8QF/urD8QvcCcYX9sCgYEA0eL8fyCqbD1fX/6/mQsVpcvkl2n6VZKdifp2lRKDIETt5PhxoZ155ab0DQeqH1k8hTQiSOHQW7WAuinyVhsecwpLfNIxT5Vso3axnFMBLs/Q2YAlunzlKv1gYGYf77SecDlKpMVXiHsfY9LpejuId/1Rqq29idWoWgK/zZRhI28CgYEAl7uRknzcHM8/DVI0gHBcHGof1oqOMjjtDiFoPTg3irmyJW5EI0Uerj6DN29rz79x4BXA4+QkkHPX3oLFclvijFPGLV4oF/kOB4GgiAaxsRWdUuOBPw7DtfwkHk36DklCratBHxgPAfQ28utgk94YEn9t/dWhEpZePuf/0VyadiUCgYAyULbW0SpgzH8kaNrD/zJjFAq+c92Ffvd82mhHML5vDaCDY143OvAwQORoeLGUqew5ywcBiy5TYHVczdlBu/3tBN9vKnZlzkIkD3iJ5ILJ22qvbbCP2ZQ8ZWl3dzoPK24nF+dkQIp9RuXDHX5YXe/SEysqK+3WeEn3ePbk87wXbg==")!

/// Checks an RS256 signature with the platform's own RSA code.
func verifyRS256(_ signature: Data, for data: Data, keyPEM: String) -> Bool {
    #if canImport(Security)
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
    guard let key = SecKeyCreateWithData(testRSAKeyPKCS1 as CFData, attributes as CFDictionary, nil),
          let publicKey = SecKeyCopyPublicKey(key)
    else { return false }
    return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    #elseif canImport(_CryptoExtras)
    guard let key = try? _RSA.Signing.PrivateKey(pemRepresentation: keyPEM) else { return false }
    return key.publicKey.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signature), for: data, padding: .insecurePKCS1v1_5)
    #else
    return false
    #endif
}

func base64URLDecode(_ text: Substring) -> Data {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return Data(base64Encoded: base64)!
}

func jsonObject(_ data: some DataProtocol) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(data))) as? [String: Any] ?? [:]
}

@Suite("Push relay")
struct PushTests {
    let phone = DeviceKeyPair().agreementPublicKey
    let otherPhone = DeviceKeyPair().agreementPublicKey

    @Test("messages round-trip")
    func wire() throws {
        let handle = PushHandle.random()
        for message: PushMessage in [.register(platform: .apns, token: "ab12", topic: "dev.circles.Circles"),
                                     .register(platform: .fcm, token: "t", topic: nil), .registered(handle),
                                     .unregister(handle), .ping([handle, .random()]), .ok, .refused("no")] {
            #expect(try CBORDecoder().decode(PushMessage.self, from: CBOREncoder().encode(message)) == message)
        }
    }

    @Test("registrations belong to their device; pings wake, coalesced, and reveal nothing")
    func relay() async throws {
        let sender = RecordingSender()
        let file = temporaryFile()
        let relay = try PushRelay(senders: [.test: sender], file: file, minimumInterval: .milliseconds(300))

        #expect(await relay.handle(.register(platform: .apns, token: "x", topic: nil), from: phone) == .refused("this relay doesn't deliver to apns"))
        #expect(await relay.handle(.register(platform: .test, token: "x", topic: nil), from: nil) == .refused("unauthenticated"))
        guard case .registered(let handle) = await relay.handle(.register(platform: .test, token: "token-1", topic: nil), from: phone) else {
            Issue.record("registration failed"); return
        }
        // A new token keeps the handle, so pods needn't be told.
        #expect(await relay.handle(.register(platform: .test, token: "token-2", topic: nil), from: phone) == .registered(handle))

        #expect(await relay.handle(.ping([handle, handle]), from: nil) == .ok)
        #expect(await relay.handle(.ping([handle]), from: nil) == .ok) // within the interval: coalesced
        #expect(sender.tokens == ["token-2"])
        try await Task.sleep(for: .milliseconds(350))
        #expect(await relay.handle(.ping([handle]), from: nil) == .ok)
        #expect(sender.tokens == ["token-2", "token-2"])

        // Unknown handles get the same answer, and wake nobody.
        #expect(await relay.handle(.ping([.random()]), from: nil) == .ok)
        #expect(sender.tokens.count == 2)
        #expect(await relay.handle(.ping(Array(repeating: handle, count: 65)), from: nil) == .refused("too many handles"))

        // Survives a restart; only the registering device can remove it.
        let reopened = try PushRelay(senders: [.test: sender], file: file)
        #expect(await reopened.registrationCount == 1)
        #expect(await reopened.handle(.unregister(handle), from: otherPhone) == .refused("not yours"))
        #expect(await reopened.handle(.unregister(handle), from: phone) == .ok)
        #expect(await reopened.registrationCount == 0)
    }

    @Test("register and ping over Noise, with the relay's key pinned")
    func overNoise() async throws {
        let sender = RecordingSender()
        let relayKeys = DeviceKeyPair(), phoneKeys = DeviceKeyPair(), podKeys = DeviceKeyPair()
        let relayKey = relayKeys.agreementPublicKey
        let relay = try PushRelay(senders: [.test: sender], file: nil)
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: NoiseHandshake(role: .responder, device: relayKeys))
        let task = Task { try await relay.serve(listener) }
        defer { task.cancel() }

        let reply = try await PushClient.request(.register(platform: .test, token: "phone-token", topic: nil), host: "127.0.0.1",
                                                 port: listener.port, key: relayKey, handshake: NoiseHandshake(role: .initiator, device: phoneKeys))
        guard case .registered(let handle) = reply else { Issue.record("got \(reply)"); return }
        #expect(try await PushClient.request(.ping([handle]), host: "127.0.0.1", port: listener.port, key: relayKey,
                                             handshake: NoiseHandshake(role: .initiator, device: podKeys)) == .ok)
        #expect(sender.tokens == ["phone-token"])
        await #expect(throws: PushError.refused("wrong relay key")) {
            try await PushClient.request(.ping([handle]), host: "127.0.0.1", port: listener.port, key: phoneKeys.agreementPublicKey,
                                         handshake: NoiseHandshake(role: .initiator, device: podKeys))
        }
        let address = PushClient.address(host: "127.0.0.1", port: listener.port, key: relayKey)
        #expect(try PushClient.parse(address: address) == ("127.0.0.1", UInt16(listener.port), relayKey))
    }

    @Test("APNs: a background push with an ES256 provider token, reused for 50 minutes")
    func apns() async throws {
        let key = P256.Signing.PrivateKey()
        let http = FakeHTTP()
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let sender = try APNsSender(credentials: .init(keyPEM: key.pemRepresentation, keyID: "KEY123", teamID: "TEAM45", production: false),
                                    defaultTopic: "dev.circles.Circles", http: http, now: { clock.withLock { $0 } })
        try await sender.wake(token: "devicetoken", topic: nil)
        let request = try #require(http.requests.withLock { $0.first })
        #expect(request.url.absoluteString == "https://api.sandbox.push.apple.com/3/device/devicetoken")
        #expect(request.headers["apns-push-type"] == "background")
        #expect(request.headers["apns-priority"] == "5")
        #expect(request.headers["apns-topic"] == "dev.circles.Circles")
        #expect((jsonObject(request.body)["aps"] as? [String: Any])?["content-available"] as? Int == 1)

        let jwt = try #require(request.headers["authorization"]?.dropFirst("bearer ".count))
        let parts = jwt.split(separator: ".")
        #expect(jsonObject(base64URLDecode(parts[0]))["kid"] as? String == "KEY123")
        #expect(jsonObject(base64URLDecode(parts[1]))["iss"] as? String == "TEAM45")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: base64URLDecode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))

        clock.withLock { $0 += 49 * 60 }
        try await sender.wake(token: "devicetoken", topic: "other.topic")
        clock.withLock { $0 += 2 * 60 }
        try await sender.wake(token: "devicetoken", topic: nil)
        let tokens = http.requests.withLock { $0.map { $0.headers["authorization"] } }
        #expect(tokens[0] == tokens[1] && tokens[1] != tokens[2])
        #expect(http.requests.withLock { $0[1].headers["apns-topic"] } == "other.topic")

        let failing = try APNsSender(credentials: .init(keyPEM: key.pemRepresentation, keyID: "K", teamID: "T", production: true),
                                     defaultTopic: "t", http: FakeHTTP { _ in (410, Array(#"{"reason":"Unregistered"}"#.utf8)) })
        await #expect(throws: PushError.delivery(status: 410, body: #"{"reason":"Unregistered"}"#)) {
            try await failing.wake(token: "gone", topic: nil)
        }
    }

    @Test("the PKCS#1 key inside a PKCS#8 key is found (the Apple signing path), matching OpenSSL")
    func pkcs8() throws {
        let der = try #require(RSASigner.der(fromPEM: testRSAKey))
        #expect(RSASigner.pkcs1(fromPKCS8: der).map { Data($0) } == testRSAKeyPKCS1)
        #expect(RSASigner.pkcs1(fromPKCS8: Array(der.prefix(40))) == nil)
        #expect(RSASigner.pkcs1(fromPKCS8: [0x30, 0x82]) == nil)
    }

    @Test("FCM: an OAuth token from an RS256 service-account assertion, then a data message",
          .enabled(if: RSASigner.isAvailable))
    func fcm() async throws {
        let keyFile = try JSONSerialization.data(withJSONObject: [
            "type": "service_account", "project_id": "circles-test", "client_email": "push@circles-test.iam.gserviceaccount.com",
            "private_key": testRSAKey, "token_uri": "https://oauth2.googleapis.com/token",
        ])
        let http = FakeHTTP { url in
            url.host == "oauth2.googleapis.com" ? (200, Array(#"{"access_token":"ya29.token","expires_in":3600}"#.utf8)) : (200, [])
        }
        let sender = try FCMSender(account: try .init(json: keyFile), http: http)
        try await sender.wake(token: "fcm-device", topic: nil)
        try await sender.wake(token: "fcm-device-2", topic: nil)
        let requests = http.requests.withLock { $0 }
        #expect(requests.count == 3) // one token exchange, reused for both messages

        let form = String(decoding: requests[0].body, as: UTF8.self)
        #expect(form.hasPrefix("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="))
        let assertion = form.split(separator: "=").last!.split(separator: ".")
        let claims = jsonObject(base64URLDecode(assertion[1]))
        #expect(claims["scope"] as? String == "https://www.googleapis.com/auth/firebase.messaging")
        #expect(claims["iss"] as? String == "push@circles-test.iam.gserviceaccount.com")
        #expect(verifyRS256(base64URLDecode(assertion[2]), for: Data((assertion[0] + "." + assertion[1]).utf8), keyPEM: testRSAKey))

        #expect(requests[1].url.absoluteString == "https://fcm.googleapis.com/v1/projects/circles-test/messages:send")
        #expect(requests[1].headers["authorization"] == "Bearer ya29.token")
        let message = jsonObject(requests[1].body)["message"] as? [String: Any]
        #expect(message?["token"] as? String == "fcm-device")
        #expect((message?["data"] as? [String: String]) == ["circles": "sync"])
        #expect(throws: PushError.self) { try FCMSender.ServiceAccount(json: Data("{}".utf8)) }
    }
}
