import Testing
import Foundation
import Synchronization
import Crypto
import _CryptoExtras
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

    @Test("FCM: an OAuth token from an RS256 service-account assertion, then a data message")
    func fcm() async throws {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let keyFile = try JSONSerialization.data(withJSONObject: [
            "type": "service_account", "project_id": "circles-test", "client_email": "push@circles-test.iam.gserviceaccount.com",
            "private_key": key.pemRepresentation, "token_uri": "https://oauth2.googleapis.com/token",
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
        let signature = _RSA.Signing.RSASignature(rawRepresentation: base64URLDecode(assertion[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data((assertion[0] + "." + assertion[1]).utf8), padding: .insecurePKCS1v1_5))

        #expect(requests[1].url.absoluteString == "https://fcm.googleapis.com/v1/projects/circles-test/messages:send")
        #expect(requests[1].headers["authorization"] == "Bearer ya29.token")
        let message = jsonObject(requests[1].body)["message"] as? [String: Any]
        #expect(message?["token"] as? String == "fcm-device")
        #expect((message?["data"] as? [String: String]) == ["circles": "sync"])
        #expect(throws: PushError.self) { try FCMSender.ServiceAccount(json: Data("{}".utf8)) }
    }
}
