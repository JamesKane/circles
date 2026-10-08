import ArgumentParser
import Foundation
import CirclesNet
import CirclesKit
import CirclesPush
import CirclesCLISupport

@main
struct PushServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "circles-push",
        abstract: "A push relay: wakes Circles phones through APNs or FCM when their pods have something. It never sees content."
    )

    @Option(help: "Data directory for the relay key and registrations. Defaults to $CIRCLES_PUSH_HOME or ~/.circles-push.") var home: String?
    @Option(help: "Address to bind.") var bind = "0.0.0.0"
    @Option(help: "TCP port to listen on.") var port = 7467
    @Option(help: "The public host name or address to print in the relay address.") var publicHost: String?

    @Option(help: "APNs: path to the .p8 auth key.") var apnsKey: String?
    @Option(help: "APNs: the key's ID.") var apnsKeyId: String?
    @Option(help: "APNs: your team ID.") var apnsTeam: String?
    @Option(help: "APNs: the app's bundle ID, used when a device registers without one.") var apnsTopic: String?
    @Flag(help: "APNs: use the production service (default: sandbox).") var apnsProduction = false
    @Option(help: "FCM: path to the service account key (JSON).") var fcmServiceAccount: String?
    @Flag(help: "Accept the test platform: wake-ups are only printed.") var test = false

    func validate() throws {
        if apnsKey != nil, apnsKeyId == nil || apnsTeam == nil {
            throw ValidationError("--apns-key needs --apns-key-id and --apns-team.")
        }
        if apnsKey == nil, fcmServiceAccount == nil, !test {
            throw ValidationError("Configure at least one platform: --apns-key, --fcm-service-account, or --test.")
        }
    }

    func run() async throws {
        let directory = directoryURL(home, environment: "CIRCLES_PUSH_HOME", default: ".circles-push")
        let identity = try RelayIdentity(home: directory)
        var senders: [PushPlatform: any PushSender] = [:]
        if let apnsKey, let apnsKeyId, let apnsTeam {
            senders[.apns] = try APNsSender(
                credentials: .init(keyPEM: try String(contentsOfFile: apnsKey, encoding: .utf8), keyID: apnsKeyId,
                                   teamID: apnsTeam, production: apnsProduction),
                defaultTopic: apnsTopic
            )
        }
        if let fcmServiceAccount {
            senders[.fcm] = try FCMSender(account: try .init(json: try Data(contentsOf: URL(fileURLWithPath: fcmServiceAccount))))
        }
        if test { senders[.test] = RecordingSender { token in say("Test wake-up for \(token)") } }
        let relay = try PushRelay(senders: senders, file: directory.appendingPathComponent("registrations.cbor")) { say($0) }
        let (bind, port, publicHost) = (self.bind, self.port, self.publicHost)
        let platforms = senders.keys.map { "\($0)" }.sorted().joined(separator: ", ")
        try await runUntilInterrupted {
            let listener = try await NoiseListener(host: bind, port: port, handshake: identity.makeHandshake())
            say("Push relay for \(platforms) listening on \(bind):\(listener.port), with \(await relay.registrationCount) registrations.")
            say("Devices register with:")
            say("  circles push register \(PushClient.address(host: publicHost ?? bind, port: listener.port, key: identity.agreementKey)) --platform <apns|fcm|test> --token <token>")
            try await relay.serve(listener)
        }
    }
}
