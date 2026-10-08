import ArgumentParser
import CirclesCore
import CirclesKit
import CirclesCrypto

struct DeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device", abstract: "Your devices and pods.", subcommands: [List.self, Revoke.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the devices your identity certifies.")
        @OptionGroup var global: Global

        func run() async throws {
            for device in try await global.open().devices() {
                let kind = device.capabilities.contains(.storeAndForward) ? "pod" : "device"
                print("\(device.device)  \(kind)" + (device.isThisDevice ? "  (this device)" : "") + (device.revoked ? "  REVOKED" : ""))
            }
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Revoke a lost or stolen device or pod. Its future signatures are rejected, and so is anything in its log past what you've seen."
        )
        @OptionGroup var global: Global
        @Argument(help: "The device ID (from `circles device list`), or a unique prefix.") var device: String

        func run() async throws {
            let account = try await global.open()
            let matches = try await account.devices().filter { $0.device.description.hasPrefix(device) && !$0.isThisDevice }
            guard matches.count == 1, let match = matches.first else {
                throw ValidationError(matches.isEmpty ? "No other device matches \(device)." : "\(device) matches several devices.")
            }
            try await account.revokeDevice(match.device)
            print("Revoked \(match.device). Contacts learn of it at their next sync with you.")
        }
    }
}
