public import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto

/// Delivers one content-free wake-up to one device.
public protocol PushSender: Sendable {
    func wake(token: String, topic: String?) async throws
}

/// The HTTP the senders need: a POST, returning status and body.
public protocol HTTPPoster: Sendable {
    func post(_ url: URL, headers: [String: String], body: [UInt8]) async throws -> (status: Int, body: [UInt8])
}

/// `URLSession`, which speaks HTTP/2 to APNs where the platform's HTTP stack
/// supports it (Apple platforms; libcurl with nghttp2 on Linux).
public struct URLSessionPoster: HTTPPoster {
    public init() {}

    public func post(_ url: URL, headers: [String: String], body: [UInt8]) async throws -> (status: Int, body: [UInt8]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, Array(data))
    }
}

/// Base64url without padding, as JWTs use.
func base64URL(_ bytes: some Sequence<UInt8>) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func json(_ object: [String: Any]) -> [UInt8] {
    Array((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
}

/// A JWT's signing input: base64url(header) "." base64url(claims).
func jwtSigningInput(header: [String: Any], claims: [String: Any]) -> String {
    base64URL(json(header)) + "." + base64URL(json(claims))
}

// MARK: - APNs

/// Apple Push Notification service, with token-based (.p8 key) auth. Sends
/// background pushes: no alert, no sound, no content, just "sync now".
public actor APNsSender: PushSender {
    public struct Credentials: Sendable {
        /// The .p8 key's PEM text.
        public var keyPEM: String
        public var keyID: String
        public var teamID: String
        public var production: Bool

        public init(keyPEM: String, keyID: String, teamID: String, production: Bool) {
            self.keyPEM = keyPEM
            self.keyID = keyID
            self.teamID = teamID
            self.production = production
        }
    }

    private let key: P256.Signing.PrivateKey
    private let credentials: Credentials
    private let defaultTopic: String?
    private let http: any HTTPPoster
    private let now: @Sendable () -> Date
    private var token: (jwt: String, issued: Date)?

    public init(credentials: Credentials, defaultTopic: String?, http: any HTTPPoster = URLSessionPoster(),
                now: @escaping @Sendable () -> Date = { Date() }) throws(PushError) {
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: credentials.keyPEM)
        } catch {
            throw .invalidCredentials("APNs key: \(error)")
        }
        self.credentials = credentials
        self.defaultTopic = defaultTopic
        self.http = http
        self.now = now
    }

    /// Apple wants a fresh token at most hourly and no more often than every
    /// 20 minutes; reuse one for 50.
    func providerToken() throws -> String {
        if let token, now().timeIntervalSince(token.issued) < 50 * 60 { return token.jwt }
        let issued = now()
        let input = jwtSigningInput(header: ["alg": "ES256", "kid": credentials.keyID],
                                    claims: ["iss": credentials.teamID, "iat": Int(issued.timeIntervalSince1970)])
        let signature = try key.signature(for: Data(input.utf8))
        let jwt = input + "." + base64URL(signature.rawRepresentation)
        token = (jwt, issued)
        return jwt
    }

    public func wake(token deviceToken: String, topic: String?) async throws {
        guard let topic = topic ?? defaultTopic else { throw PushError.invalidCredentials("APNs needs a topic (the app's bundle ID)") }
        let host = credentials.production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        let url = URL(string: "https://\(host)/3/device/\(deviceToken)")!
        let headers = [
            "authorization": "bearer \(try providerToken())",
            "apns-push-type": "background",
            "apns-priority": "5",
            "apns-topic": topic,
            "content-type": "application/json",
        ]
        let (status, body) = try await http.post(url, headers: headers, body: json(["aps": ["content-available": 1]]))
        guard status == 200 else { throw PushError.delivery(status: status, body: String(decoding: body, as: UTF8.self)) }
    }
}

// MARK: - FCM

/// Firebase Cloud Messaging (HTTP v1), authenticated as a service account.
/// Sends a high-priority data message with no content.
public actor FCMSender: PushSender {
    public struct ServiceAccount: Sendable {
        public var projectID: String
        public var clientEmail: String
        /// The RSA private key's PEM text.
        public var privateKeyPEM: String
        public var tokenURI: String

        /// Reads the JSON key file Google issues for a service account.
        public init(json: Data) throws(PushError) {
            guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  let project = object["project_id"] as? String, let email = object["client_email"] as? String,
                  let key = object["private_key"] as? String
            else { throw .invalidCredentials("not a service account key file") }
            projectID = project
            clientEmail = email
            privateKeyPEM = key
            tokenURI = object["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
        }
    }

    private let account: ServiceAccount
    private let key: RSASigner
    private let http: any HTTPPoster
    private let now: @Sendable () -> Date
    private var accessToken: (token: String, expires: Date)?

    public init(account: ServiceAccount, http: any HTTPPoster = URLSessionPoster(),
                now: @escaping @Sendable () -> Date = { Date() }) throws(PushError) {
        key = try RSASigner(pem: account.privateKeyPEM)
        self.account = account
        self.http = http
        self.now = now
    }

    /// An OAuth access token for FCM, from a signed JWT assertion.
    func oauthToken() async throws -> String {
        if let accessToken, accessToken.expires > now().addingTimeInterval(60) { return accessToken.token }
        let issued = Int(now().timeIntervalSince1970)
        let input = jwtSigningInput(
            header: ["alg": "RS256", "typ": "JWT"],
            claims: ["iss": account.clientEmail, "scope": "https://www.googleapis.com/auth/firebase.messaging",
                     "aud": account.tokenURI, "iat": issued, "exp": issued + 3600]
        )
        let assertion = input + "." + base64URL(try key.sign(Data(input.utf8)))
        let form = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)"
        let (status, body) = try await http.post(URL(string: account.tokenURI)!,
                                                 headers: ["content-type": "application/x-www-form-urlencoded"],
                                                 body: Array(form.utf8))
        guard status == 200, let object = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any],
              let token = object["access_token"] as? String
        else { throw PushError.delivery(status: status, body: String(decoding: body, as: UTF8.self)) }
        let lifetime = object["expires_in"] as? Int ?? 3600
        accessToken = (token, now().addingTimeInterval(TimeInterval(lifetime)))
        return token
    }

    public func wake(token deviceToken: String, topic: String?) async throws {
        let url = URL(string: "https://fcm.googleapis.com/v1/projects/\(account.projectID)/messages:send")!
        let message: [String: Any] = ["message": ["token": deviceToken, "data": ["circles": "sync"],
                                                  "android": ["priority": "high"]]]
        let (status, body) = try await http.post(url, headers: ["authorization": "Bearer \(try await oauthToken())",
                                                                "content-type": "application/json"],
                                                 body: json(message))
        guard status == 200 else { throw PushError.delivery(status: status, body: String(decoding: body, as: UTF8.self)) }
    }
}

// MARK: - Test

/// Records wake-ups instead of sending them, for testing a relay without
/// platform credentials.
public final class RecordingSender: PushSender, @unchecked Sendable {
    private let lock = NSLock()
    private var woken: [String] = []
    private let onWake: @Sendable (String) -> Void

    public init(onWake: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onWake = onWake
    }

    public var tokens: [String] { lock.withLock { woken } }

    public func wake(token: String, topic: String?) async throws {
        lock.withLock { woken.append(token) }
        onWake(token)
    }
}
