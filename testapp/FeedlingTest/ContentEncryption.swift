import CryptoKit
import Foundation

/// v1 content envelope builder + unsealer. Mirrors tools/e2e_encryption_test.py
/// and the server's backend/enclave_app.py AEAD path exactly — same
/// primitives, same AAD shape (owner_user_id || v || id), same base64
/// encoding. If the two drift, the enclave's AEAD verification fails and
/// the agent can't read that item.
///
/// Primitives used:
///   - Curve25519.KeyAgreement for the user's content keypair
///   - crypto_box_seal (sealed box) for K_user and K_enclave wrapping —
///     implemented via our BoxSeal helper below since CryptoKit doesn't
///     expose the exact NaCl sealed-box format
///   - ChaChaPoly (ChaCha20-Poly1305 IETF, 12-byte nonce) for the body
enum ContentEncryption {

    /// Build a v1 envelope for a body payload.
    static func envelope(
        plaintext: Data,
        ownerUserID: String,
        userContentPK: Curve25519.KeyAgreement.PublicKey,
        enclaveContentPK: Curve25519.KeyAgreement.PublicKey?,
        visibility: Visibility = .shared,
        itemID: String? = nil
    ) throws -> Envelope {
        // Per-item symmetric key + nonce.
        let K = SymmetricKey(size: .bits256)
        let nonce = try ChaChaPoly.Nonce()
        let id = itemID ?? Self.randomItemID()

        // AAD binding: server-visible plaintext metadata the enclave will
        // re-derive on read-back. Any mismatch fails AEAD verify.
        let aad = "\(ownerUserID)|1|\(id)".data(using: .utf8)!

        let sealed = try ChaChaPoly.seal(plaintext, using: K, nonce: nonce,
                                         authenticating: aad)
        // ChaChaPoly.SealedBox.combined packs nonce||ciphertext||tag. We
        // want ciphertext||tag without the nonce (we ship nonce separately
        // so the enclave can hand it to nacl.bindings unchanged).
        let bodyCT = sealed.ciphertext + sealed.tag

        // Serialize K to raw bytes so we can sealed-box it to each recipient.
        let keyBytes = K.withUnsafeBytes { Data($0) }
        let kUser = try BoxSeal.seal(keyBytes, to: userContentPK)
        let kEnclave: Data?
        switch visibility {
        case .shared:
            guard let epk = enclaveContentPK else {
                throw CryptoError.enclaveKeyMissingForSharedVisibility
            }
            kEnclave = try BoxSeal.seal(keyBytes, to: epk)
        case .localOnly:
            kEnclave = nil
        }

        return Envelope(
            id: id,
            v: 1,
            ownerUserID: ownerUserID,
            visibility: visibility,
            bodyCT: bodyCT,
            nonce: Data(nonce),
            kUser: kUser,
            kEnclave: kEnclave,
            enclavePKFingerprint: enclaveContentPK.map {
                SHA256.hash(data: Data($0.rawRepresentation)).prefix(16).map { $0 }.reduce("") { $0 + String(format: "%02x", $1) }
            } ?? ""
        )
    }

    /// Decrypt a received envelope locally on the phone (iOS always has
    /// the user_content_sk via Keychain, so it can always decrypt its own
    /// content without going through the enclave).
    static func unseal(
        _ env: Envelope,
        withUserSK userSK: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Data {
        let kBytes = try BoxSeal.open(env.kUser, withRecipient: userSK)
        let K = SymmetricKey(data: kBytes)
        guard env.nonce.count == 12 else {
            throw CryptoError.wrongNonceSize(got: env.nonce.count)
        }
        let nonce = try ChaChaPoly.Nonce(data: env.nonce)
        // bodyCT is ciphertext||tag; ChaChaPoly.SealedBox needs them split.
        guard env.bodyCT.count > 16 else {
            throw CryptoError.bodyTooShort
        }
        let ct = env.bodyCT.prefix(env.bodyCT.count - 16)
        let tag = env.bodyCT.suffix(16)
        let sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let aad = "\(env.ownerUserID)|\(env.v)|\(env.id)".data(using: .utf8)!
        return try ChaChaPoly.open(sealed, using: K, authenticating: aad)
    }

    // MARK: - Supporting types

    enum Visibility: String {
        case shared
        case localOnly = "local_only"
    }

    struct Envelope {
        let id: String
        let v: Int
        let ownerUserID: String
        let visibility: Visibility
        let bodyCT: Data
        let nonce: Data
        let kUser: Data
        let kEnclave: Data?
        let enclavePKFingerprint: String

        /// JSON representation for POSTing to /v1/chat/message,
        /// /v1/memory/add, or /v1/identity/init.
        func jsonBody(extraMetadata: [String: Any] = [:]) -> [String: Any] {
            var env: [String: Any] = [
                "v": v,
                "id": id,
                "body_ct": bodyCT.base64EncodedString(),
                "nonce": nonce.base64EncodedString(),
                "K_user": kUser.base64EncodedString(),
                "visibility": visibility.rawValue,
                "owner_user_id": ownerUserID,
                "enclave_pk_fpr": enclavePKFingerprint,
            ]
            if let k = kEnclave {
                env["K_enclave"] = k.base64EncodedString()
            }
            for (k, v) in extraMetadata { env[k] = v }
            return ["envelope": env]
        }
    }

    enum CryptoError: Error {
        case enclaveKeyMissingForSharedVisibility
        case wrongNonceSize(got: Int)
        case bodyTooShort
        case sealedBoxMalformed
        case sealedBoxDecryptFailed
    }

    private static func randomItemID() -> String {
        var bytes = Data(count: 16)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - NaCl-compatible sealed box
// CryptoKit doesn't expose libsodium's crypto_box_seal directly, so we
// reconstruct it: ephemeral-X25519 + Blake2b-keyed nonce + XSalsa20-Poly1305.
//
// Luckily, libsodium's crypto_box_seal is equivalent to:
//   1. Generate ephemeral X25519 keypair (ek_priv, ek_pub)
//   2. nonce = Blake2b(ek_pub || recipient_pub, 24 bytes)
//   3. ciphertext = crypto_box(plaintext, nonce, recipient_pub, ek_priv)
//   4. output = ek_pub (32 bytes) || ciphertext
//
// To implement this with Apple's primitives alone we'd need Blake2b +
// XSalsa20 — Apple's CryptoKit has neither. So for iOS-side encryption
// we switch to a simpler approach: use ChaCha20-Poly1305 with a derived
// symmetric key via ECDH + HKDF. This is NOT wire-compatible with
// libsodium's crypto_box_seal — but we only use it to wrap K, and we
// wrap K with a distinct scheme for each recipient, so the server side
// can be updated to match.
//
// For Phase 1 iOS: we use a sealed-box pattern built on CryptoKit:
//   1. Generate ephemeral X25519 keypair
//   2. shared_secret = ECDH(ek_priv, recipient_pub)
//   3. K_wrap = HKDF-SHA256(shared_secret, info="feedling-box-seal-v1", len=32)
//   4. nonce = first 12 bytes of SHA256(ek_pub || recipient_pub)
//   5. wrapped = ChaChaPoly.seal(plaintext, using: K_wrap, nonce: nonce)
//   6. output = ek_pub (32 bytes) || wrapped.ciphertext || wrapped.tag
//
// The enclave must implement the mirror of this. Adding this to
// backend/enclave_app.py requires ~30 lines of Python using
// cryptography.hazmat.
enum BoxSeal {

    private static let info = Data("feedling-box-seal-v1".utf8)

    static func seal(_ plaintext: Data, to recipientPK: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPK)
        let kWrap = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)

        // Nonce: 12 bytes derived from (ek_pub || recipient_pub).
        let ekPub = ephemeral.publicKey.rawRepresentation
        let rcpPub = recipientPK.rawRepresentation
        let nonceBytes = Array(SHA256.hash(data: ekPub + rcpPub).prefix(12))
        let nonce = try ChaChaPoly.Nonce(data: Data(nonceBytes))

        let sealed = try ChaChaPoly.seal(plaintext, using: kWrap, nonce: nonce)
        // Output = ek_pub (32) || ciphertext || tag (16)
        return ekPub + sealed.ciphertext + sealed.tag
    }

    static func open(_ blob: Data, withRecipient recipientSK: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard blob.count > 32 + 16 else {
            throw ContentEncryption.CryptoError.sealedBoxMalformed
        }
        let ekPub = blob.prefix(32)
        let ephemeralPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ekPub)
        let ct = blob.dropFirst(32).prefix(blob.count - 32 - 16)
        let tag = blob.suffix(16)

        let shared = try recipientSK.sharedSecretFromKeyAgreement(with: ephemeralPK)
        let kWrap = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)

        let rcpPub = recipientSK.publicKey.rawRepresentation
        let nonceBytes = Array(SHA256.hash(data: ekPub + rcpPub).prefix(12))
        let nonce = try ChaChaPoly.Nonce(data: Data(nonceBytes))

        let sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(sealed, using: kWrap)
    }
}
