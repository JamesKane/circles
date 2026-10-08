public import CirclesCore
import Crypto

/// Encrypts media attachments as chunks (docs/DESIGN.md §9.3).
///
/// Each attachment gets a fresh 256-bit key. Chunk `i` is sealed with
/// ChaCha20-Poly1305 under that key, with nonce `i` (unique, since the key
/// is used for one attachment only). The associated data binds the chunk's
/// index and the total count, so chunks can't be reordered, dropped or
/// borrowed from another position. Chunk IDs are hashes of the ciphertext,
/// so any node can store and serve chunks without being able to read them.
public enum MediaEncryption {
    public static let chunkSize = 256 * 1024

    public struct Sealed: Sendable {
        public var reference: BlobRef
        /// Encrypted chunks, in order; their hashes are `reference.chunks`.
        public var chunks: [[UInt8]]
    }

    public static func seal(_ data: [UInt8], mediaType: String, width: UInt32? = nil, height: UInt32? = nil) throws(CryptoError) -> Sealed {
        let key = SymmetricKey(size: .bits256)
        let pieces = data.isEmpty ? [[]] : stride(from: 0, to: data.count, by: chunkSize).map {
            Array(data[$0..<min($0 + chunkSize, data.count)])
        }
        var chunks: [[UInt8]] = []
        for (index, piece) in pieces.enumerated() {
            do {
                let box = try ChaChaPoly.seal(piece, using: key, nonce: nonce(index),
                                              authenticating: associatedData(index, of: pieces.count))
                chunks.append(Array(box.ciphertext) + Array(box.tag))
            } catch {
                throw .invalidKey
            }
        }
        let reference = BlobRef(
            chunks: chunks.map { ContentID(hashing: $0) },
            key: key.withUnsafeBytes { Array($0) },
            digest: ContentID(hashing: data),
            byteCount: UInt64(data.count),
            mediaType: mediaType, width: width, height: height
        )
        return Sealed(reference: reference, chunks: chunks)
    }

    /// Decrypts and checks an attachment. `chunks` must be in the order
    /// `reference.chunks` lists them.
    public static func open(_ reference: BlobRef, chunks: [[UInt8]]) throws(CryptoError) -> [UInt8] {
        guard reference.key.count == 32, chunks.count == reference.chunks.count else { throw .decryptionFailed }
        let key = SymmetricKey(data: reference.key)
        var data: [UInt8] = []
        data.reserveCapacity(Int(reference.byteCount))
        for (index, chunk) in chunks.enumerated() {
            guard ContentID(hashing: chunk) == reference.chunks[index], chunk.count >= 16,
                  let box = try? ChaChaPoly.SealedBox(nonce: nonce(index), ciphertext: chunk.dropLast(16), tag: chunk.suffix(16)),
                  let plain = try? ChaChaPoly.open(box, using: key, authenticating: associatedData(index, of: chunks.count))
            else { throw .decryptionFailed }
            data += plain
        }
        guard ContentID(hashing: data) == reference.digest, UInt64(data.count) == reference.byteCount else {
            throw .decryptionFailed
        }
        return data
    }

    private static func nonce(_ index: Int) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: UInt64(index).littleEndian) { bytes += $0 }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    private static func associatedData(_ index: Int, of count: Int) -> [UInt8] {
        Context.mediaChunk + Varint.encode(UInt64(index)) + Varint.encode(UInt64(count))
    }
}
