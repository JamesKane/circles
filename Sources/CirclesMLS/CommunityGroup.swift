import Foundation
import Crypto
import MLSProfileRFC9420
import MLSCrypto
import MLSCodec
import MLSFraming
import MLSTreeMath
import MLSTreeKEM
import SecretBytes

/// The `GroupCrypto` boundary of docs/DESIGN.md §8.3: everything Circles needs
/// from MLS (RFC 9420), implemented over swift-mls. Nothing outside this
/// module touches an MLS type, so the implementation can be swapped.
///
/// Fits the community design (§8.3 "Community design for M5"):
/// - Only the community's sequencer commits, and its log is the delivery
///   service, so a commit is created and applied in one step.
/// - Only the sequencer sends application messages (it republishes members'
///   posts), so decryption never needs past rosters.
/// - Member credentials are basic credentials holding the member's identity
///   bytes (their `UserID`'s multicodec bytes).
public struct CommunityGroup: Sendable {
    private var group: MLS.RFC9420.Group
    private let signingKey: [UInt8]

    static let suite = MLS.CipherSuite.curve25519ChaCha

    static var provider: any MLS.CipherSuiteProvider {
        SwiftCryptoProvider().cipherSuiteProvider(for: suite)!
    }

    // MARK: Key packages and joining

    /// What a prospective member must keep, privately, until their Welcome
    /// arrives (or they give up).
    public struct JoinSecrets: Sendable, Codable {
        public var keyPackage: [UInt8]
        var initKey: [UInt8]
        var encryptionKey: [UInt8]
        var signingKey: [UInt8]
    }

    /// A fresh MLS identity for joining a group as `identity`. Returns the
    /// KeyPackage to send and the secrets to keep.
    public static func makeKeyPackage(identity: [UInt8]) throws(GroupCryptoError) -> JoinSecrets {
        do {
            let provider = Self.provider
            let signature = Curve25519.Signing.PrivateKey()
            let signingKey = try MLS.SignatureSecretKey(signature.rawRepresentation)
            let (leafSecret, leafPublic) = try provider.hpkeGenerateKeyPair()
            let (initSecret, initPublic) = try provider.hpkeGenerateKeyPair()
            var leaf = MLS.RFC9420.LeafNode(
                encryptionKey: leafPublic,
                signatureKey: MLS.SignaturePublicKey(signature.publicKey.rawRepresentation),
                credential: .basic(identity: Data(identity)),
                capabilities: .init(versions: [.mls10], cipherSuites: [suite], extensions: [], proposals: [],
                                    credentials: [.init(.basic)]),
                source: .keyPackage(.init(notBefore: 0, notAfter: .max)),
                extensions: [], signature: Data()
            )
            leaf.signature = try MLS.signWithLabel(provider, privateKey: signingKey, label: "LeafNodeTBS",
                                                   content: try leaf.toBeSigned(placement: .keyPackage))
            var keyPackage = MLS.RFC9420.KeyPackage(version: .mls10, cipherSuite: suite, initKey: initPublic,
                                                    leafNode: leaf, extensions: [], signature: Data())
            keyPackage.signature = try MLS.signWithLabel(provider, privateKey: signingKey, label: "KeyPackageTBS",
                                                         content: try keyPackage.toBeSigned())
            return JoinSecrets(
                keyPackage: Array(try keyPackage.mlsEncoded()),
                initKey: initSecret.data.withUnsafeBytes { Array($0) },
                encryptionKey: leafSecret.data.withUnsafeBytes { Array($0) },
                signingKey: Array(signature.rawRepresentation)
            )
        } catch {
            throw .mls(String(describing: error))
        }
    }

    /// The identity a KeyPackage claims, and its reference (to recognize the
    /// Welcome that answers it). The caller must check the identity against
    /// a signature it trusts before adding the KeyPackage to a group.
    public static func inspect(keyPackage bytes: [UInt8]) throws(GroupCryptoError) -> (identity: [UInt8], reference: [UInt8]) {
        do {
            let keyPackage = try MLS.RFC9420.KeyPackage(mlsEncoded: bytes)
            try keyPackage.verifySignature(provider)
            guard case .basic(let identity) = keyPackage.leafNode.credential else { throw GroupCryptoError.unsupportedCredential }
            return (Array(identity), Array(try keyPackage.reference(provider).data))
        } catch let error as GroupCryptoError {
            throw error
        } catch {
            throw .mls(String(describing: error))
        }
    }

    /// Joins from a Welcome. Throws `notForUs` if the Welcome doesn't answer
    /// this KeyPackage (Welcomes are tried against our pending KeyPackages).
    public static func join(welcome bytes: [UInt8], secrets: JoinSecrets) throws(GroupCryptoError) -> CommunityGroup {
        do {
            let provider = Self.provider
            guard case .welcome(let welcome) = try MLS.RFC9420.Message(mlsEncoded: bytes) else { throw GroupCryptoError.malformed }
            let credentials = MLS.RFC9420.Group.JoinerCredentials(
                keyPackage: try MLS.RFC9420.KeyPackage(mlsEncoded: secrets.keyPackage),
                initKey: try MLS.HpkeSecretKey(secrets.initKey),
                encryptionKey: try MLS.HpkeSecretKey(secrets.encryptionKey)
            )
            let pending: MLS.RFC9420.PendingJoin
            do {
                pending = try MLS.RFC9420.Group.joining(provider, welcome: welcome, credentials: credentials, psk: { _ in nil })
            } catch MLS.RFC9420.GroupError.noMatchingWelcomeSecret {
                throw GroupCryptoError.notForUs
            }
            let transition = pending.apply()
            return CommunityGroup(group: transition.group, signingKey: secrets.signingKey)
        } catch let error as GroupCryptoError {
            throw error
        } catch {
            throw .mls(String(describing: error))
        }
    }

    // MARK: The sequencer

    /// A new group with the caller (the sequencer) as its only member.
    public static func create(identity: [UInt8], groupID: [UInt8]) throws(GroupCryptoError) -> CommunityGroup {
        let secrets = try makeKeyPackage(identity: identity)
        do {
            let provider = Self.provider
            let keyPackage = try MLS.RFC9420.KeyPackage(mlsEncoded: secrets.keyPackage)
            let group = try MLS.RFC9420.Group.create(
                provider, groupID: Data(groupID), leafNode: keyPackage.leafNode,
                leafSecretKey: try MLS.HpkeSecretKey(secrets.encryptionKey),
                epochSecret: SecretBytes(randomByteCount: provider.hashSize)
            )
            return CommunityGroup(group: group, signingKey: secrets.signingKey)
        } catch {
            throw .mls(String(describing: error))
        }
    }

    public struct Commit: Sendable {
        /// The commit message, for the community log.
        public var message: [UInt8]
        /// For added members: the Welcome to publish.
        public var welcome: [UInt8]?
    }

    /// Adds members (sequencer only). The commit is applied at once: the
    /// community log is the delivery service, and only the sequencer commits.
    public mutating func add(keyPackages: [[UInt8]]) throws(GroupCryptoError) -> Commit {
        do {
            let proposals = try keyPackages.map { MLS.RFC9420.ProposalOrRef.proposal(.add(try MLS.RFC9420.KeyPackage(mlsEncoded: $0))) }
            return try commit(proposals)
        } catch let error as GroupCryptoError {
            throw error
        } catch {
            throw .mls(String(describing: error))
        }
    }

    /// Removes members by identity (sequencer only).
    public mutating func remove(identities: [[UInt8]]) throws(GroupCryptoError) -> Commit {
        let leaves = try leaves(for: Set(identities))
        guard !leaves.isEmpty else { throw .notAMember }
        return try commit(leaves.map { .proposal(.remove($0)) })
    }

    private mutating func commit(_ proposals: [MLS.RFC9420.ProposalOrRef]) throws(GroupCryptoError) -> Commit {
        do {
            let provider = Self.provider
            let transition = try group.committing(provider, proposals: proposals, signingKey: try key(),
                                                  randomness: .generate(provider))
            group = transition.group
            let sent = transition.takeOutput()
            let message = Array(try sent.message.mlsEncoded())
            let welcome = try sent.welcome.map { Array(try MLS.RFC9420.Message.welcome($0).mlsEncoded()) }
            group = try sent.takePending().apply(onto: group).group
            return Commit(message: message, welcome: welcome)
        } catch {
            throw .mls(String(describing: error))
        }
    }

    // MARK: Members

    public enum CommitOutcome: Sendable, Equatable {
        case applied
        /// We were removed; the group should be discarded.
        case removed
    }

    /// Applies a commit from the sequencer.
    public mutating func process(commit bytes: [UInt8]) throws(GroupCryptoError) -> CommitOutcome {
        do {
            let provider = Self.provider
            guard case .privateMessage(let message) = try MLS.RFC9420.Message(mlsEncoded: bytes) else { throw GroupCryptoError.malformed }
            let transition = try group.validating(provider, commit: message, proposals: MLS.RFC9420.ProposalStore(), psk: { _ in nil })
            group = transition.group
            switch transition.takeOutput() {
            case .pending(let pending):
                let removed = pending.effects.events.contains { if case .membershipRemoved = $0 { true } else { false } }
                group = try pending.apply(onto: group).group
                return removed ? .removed : .applied
            case .rejected(let rejection):
                throw GroupCryptoError.rejected(String(describing: rejection.reason))
            }
        } catch let error as GroupCryptoError {
            throw error
        } catch {
            throw .mls(String(describing: error))
        }
    }

    /// Encrypts content for the group (sequencer only, in this design).
    public mutating func encrypt(_ data: [UInt8]) throws(GroupCryptoError) -> [UInt8] {
        do {
            let message = try group.protect(Self.provider, applicationData: Data(data), signingKey: try key())
            return Array(try MLS.RFC9420.Message.privateMessage(message).mlsEncoded())
        } catch {
            throw .mls(String(describing: error))
        }
    }

    /// Decrypts content from the group. Returns the plaintext and the epoch it
    /// was sent in.
    public mutating func decrypt(_ bytes: [UInt8]) throws(GroupCryptoError) -> (data: [UInt8], epoch: UInt64) {
        do {
            guard case .privateMessage(let message) = try MLS.RFC9420.Message(mlsEncoded: bytes) else { throw GroupCryptoError.malformed }
            let unprotected = try group.unprotect(Self.provider, message: message)
            guard case .application(let data) = unprotected.content else { throw GroupCryptoError.malformed }
            return (Array(data), unprotected.epoch)
        } catch let error as GroupCryptoError {
            throw error
        } catch {
            throw .mls(String(describing: error))
        }
    }

    public var epoch: UInt64 { group.context.epoch }
    public var groupID: [UInt8] { Array(group.context.groupID) }

    /// The identities of the current members.
    public var members: [[UInt8]] {
        group.tree.nonBlankLeaves().compactMap { leaf in
            guard let node = try? MLS.RFC9420.LeafNode(mlsEncoded: leaf.record.encoded),
                  case .basic(let identity) = node.credential
            else { return nil }
            return Array(identity)
        }
    }

    /// Distinguishes a commit from an application message without
    /// processing it.
    public static func isCommit(_ bytes: [UInt8]) -> Bool {
        guard case .privateMessage(let message)? = try? MLS.RFC9420.Message(mlsEncoded: bytes) else { return false }
        return message.contentType == .commit
    }

    private func leaves(for identities: Set<[UInt8]>) throws(GroupCryptoError) -> [MLS.LeafIndex] {
        group.tree.nonBlankLeaves().compactMap { leaf in
            guard let node = try? MLS.RFC9420.LeafNode(mlsEncoded: leaf.record.encoded),
                  case .basic(let identity) = node.credential, identities.contains(Array(identity)), leaf.index != group.myLeafIndex
            else { return nil }
            return leaf.index
        }
    }

    private func key() throws -> MLS.SignatureSecretKey {
        try MLS.SignatureSecretKey(signingKey)
    }

    private init(group: MLS.RFC9420.Group, signingKey: [UInt8]) {
        self.group = group
        self.signingKey = signingKey
    }

    // MARK: Persistence

    /// The whole state (the MLS snapshot plus our signing key, which the
    /// snapshot deliberately leaves out), sealed under `key` (32 bytes).
    /// MLS's contract: persist after every change, before sending or acting.
    public func sealed(with key: [UInt8]) throws(GroupCryptoError) -> [UInt8] {
        do {
            let archive = try group.archive().seal(with: try SecretBytes(bytes: key), aad: Self.archiveAAD, using: .chaChaPoly)
            let inner = Array(archive) + signingKey + [UInt8(signingKey.count)]
            let box = try ChaChaPoly.seal(inner, using: SymmetricKey(data: key), authenticating: Self.stateAAD)
            return Array(box.combined)
        } catch {
            throw .mls(String(describing: error))
        }
    }

    public static func open(sealed bytes: [UInt8], with key: [UInt8]) throws(GroupCryptoError) -> CommunityGroup {
        do {
            let inner = Array(try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: bytes), using: SymmetricKey(data: key),
                                                  authenticating: stateAAD))
            guard let length = inner.last.map(Int.init), inner.count > length + 1 else { throw GroupCryptoError.malformed }
            let signingKey = Array(inner[(inner.count - 1 - length)..<(inner.count - 1)])
            let archive = Data(inner[..<(inner.count - 1 - length)])
            let group = try MLS.RFC9420.Group.restore(
                from: SecretArchive.open(archive, with: try SecretBytes(bytes: key), aad: archiveAAD), provider
            )
            return CommunityGroup(group: group, signingKey: signingKey)
        } catch let error as GroupCryptoError {
            throw error
        } catch {
            throw .mls(String(describing: error))
        }
    }

    private static let archiveAAD = Data("circles/v1/mls-archive".utf8)
    private static let stateAAD = Data("circles/v1/mls-state".utf8)
}

public enum GroupCryptoError: Error, Sendable, Equatable {
    case mls(String)
    case malformed
    case notForUs
    case notAMember
    case unsupportedCredential
    case rejected(String)
}
