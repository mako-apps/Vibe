import CommonCrypto
import CryptoKit
import ExpoModulesCore
import Foundation
import Security

private struct HybridPayload: Decodable {
  let v: Int
  let iv: String
  let c: String
  let k: String
  let s: String?
}

private func decodePEM(_ pem: String) -> Data? {
  let withoutHeaders = pem
    .components(separatedBy: .newlines)
    .filter { !$0.hasPrefix("-----") }
    .joined()
  if let data = Data(base64Encoded: withoutHeaders) {
    return data
  }
  let sanitized = pem.replacingOccurrences(
    of: "\\s+",
    with: "",
    options: .regularExpression
  )
  return Data(base64Encoded: sanitized)
}

private func privateSecKey(from pem: String) -> SecKey? {
  guard let keyData = decodePEM(pem) else {
    return nil
  }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
  ]
  return SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, nil)
}

private func publicSecKey(from pem: String) -> SecKey? {
  guard let keyData = decodePEM(pem) else {
    return nil
  }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
    kSecAttrKeyClass as String: kSecAttrKeyClassPublic
  ]
  return SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, nil)
}

private func rsaDecryptOAEP(privateKey: SecKey, encrypted: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let decrypted = SecKeyCreateDecryptedData(
    privateKey,
    .rsaEncryptionOAEPSHA256,
    encrypted as CFData,
    &error
  ) as Data?
  if decrypted != nil {
    return decrypted
  }
  _ = error?.takeRetainedValue()
  return nil
}

private func rsaEncryptOAEP(publicKey: SecKey, plain: Data) -> Data? {
  var error: Unmanaged<CFError>?
  let encrypted = SecKeyCreateEncryptedData(
    publicKey,
    .rsaEncryptionOAEPSHA256,
    plain as CFData,
    &error
  ) as Data?
  if encrypted != nil {
    return encrypted
  }
  _ = error?.takeRetainedValue()
  return nil
}

private func randomBytes(count: Int) throws -> Data {
  var data = Data(count: count)
  let status = data.withUnsafeMutableBytes { buffer in
    guard let baseAddress = buffer.baseAddress else {
      return errSecParam
    }
    return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
  }
  if status != errSecSuccess {
    throw NSError(
      domain: "ChatNativeCore",
      code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "Secure random generation failed (\(status))"]
    )
  }
  return data
}

private func decryptHybridMessage(
  privateKey: SecKey,
  ciphertext: String,
  isMyMessage: Bool
) -> String {
  let trimmed = ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    return ""
  }
  if !trimmed.hasPrefix("{") {
    return "[Decryption Failed - Format]"
  }

  do {
    let payloadData = Data(trimmed.utf8)
    let payload = try JSONDecoder().decode(HybridPayload.self, from: payloadData)

    var keyCandidates: [String] = []
    if isMyMessage {
      if let senderKey = payload.s {
        keyCandidates.append(senderKey)
      }
      keyCandidates.append(payload.k)
    } else {
      keyCandidates.append(payload.k)
      if let senderKey = payload.s {
        keyCandidates.append(senderKey)
      }
    }

    var aesKeyData: Data?
    for keyCandidate in keyCandidates {
      guard let encryptedKey = Data(base64Encoded: keyCandidate) else {
        continue
      }
      if let decryptedKey = rsaDecryptOAEP(privateKey: privateKey, encrypted: encryptedKey) {
        aesKeyData = decryptedKey
        break
      }
    }

    guard let aesKeyData else {
      throw NSError(
        domain: "ChatNativeCore",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Could not decrypt AES key"]
      )
    }

    guard
      let ivData = Data(base64Encoded: payload.iv),
      let combinedData = Data(base64Encoded: payload.c),
      combinedData.count >= 16
    else {
      throw NSError(
        domain: "ChatNativeCore",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Invalid ciphertext payload"]
      )
    }

    let ciphertextData = combinedData.prefix(combinedData.count - 16)
    let tagData = combinedData.suffix(16)
    let nonce = try AES.GCM.Nonce(data: ivData)
    let sealedBox = try AES.GCM.SealedBox(
      nonce: nonce,
      ciphertext: ciphertextData,
      tag: tagData
    )
    let plaintextData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: aesKeyData))
    return String(data: plaintextData, encoding: .utf8) ?? ""
  } catch {
    return "[Decryption Failed]"
  }
}

private func encryptHybridMessage(
  recipientPublicKeyPem: String,
  message: String,
  myPublicKeyPem: String?
) throws -> String {
  guard let recipientKey = publicSecKey(from: recipientPublicKeyPem) else {
    throw NSError(
      domain: "ChatNativeCore",
      code: 10,
      userInfo: [NSLocalizedDescriptionKey: "Invalid recipient public key"]
    )
  }

  let aesKey = try randomBytes(count: 32)
  let iv = try randomBytes(count: 12)
  let nonce = try AES.GCM.Nonce(data: iv)
  let sealed = try AES.GCM.seal(
    Data(message.utf8),
    using: SymmetricKey(data: aesKey),
    nonce: nonce
  )

  guard let encryptedKeyRecipient = rsaEncryptOAEP(publicKey: recipientKey, plain: aesKey) else {
    throw NSError(
      domain: "ChatNativeCore",
      code: 11,
      userInfo: [NSLocalizedDescriptionKey: "Recipient RSA encrypt failed"]
    )
  }

  var senderEncryptedKeyBase64: String?
  if let myPublicKeyPem, let myPublicKey = publicSecKey(from: myPublicKeyPem) {
    if let encryptedSenderKey = rsaEncryptOAEP(publicKey: myPublicKey, plain: aesKey) {
      senderEncryptedKeyBase64 = encryptedSenderKey.base64EncodedString()
    }
  }

  let combinedCipher = sealed.ciphertext + sealed.tag
  var json: [String: Any] = [
    "v": 1,
    "iv": iv.base64EncodedString(),
    "c": combinedCipher.base64EncodedString(),
    "k": encryptedKeyRecipient.base64EncodedString()
  ]
  if let senderEncryptedKeyBase64 {
    json["s"] = senderEncryptedKeyBase64
  }

  let serialized = try JSONSerialization.data(withJSONObject: json, options: [])
  guard let payloadString = String(data: serialized, encoding: .utf8) else {
    throw NSError(
      domain: "ChatNativeCore",
      code: 12,
      userInfo: [NSLocalizedDescriptionKey: "Could not encode payload"]
    )
  }
  return payloadString
}

public class ChatNativeCoreModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeCore")

    Function("isSupported") {
      true
    }

    Function("supportsCryptoPipeline") {
      true
    }

    AsyncFunction("decryptMessagesBatch") { (input: [String: Any]) throws -> [String: Any] in
      guard let privateKeyPem = input["privateKey"] as? String else {
        return ["messages": [String: String]()]
      }
      guard let privateKey = privateSecKey(from: privateKeyPem) else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 21,
          userInfo: [NSLocalizedDescriptionKey: "Invalid private key"]
        )
      }
      let items = input["items"] as? [[String: Any]] ?? []
      var messages: [String: String] = [:]
      messages.reserveCapacity(items.count)

      for item in items {
        guard
          let id = item["id"] as? String,
          let encryptedContent = item["encryptedContent"] as? String
        else {
          continue
        }
        let isFromMe = (item["isFromMe"] as? Bool) ?? false
        let decrypted = decryptHybridMessage(
          privateKey: privateKey,
          ciphertext: encryptedContent,
          isMyMessage: isFromMe
        )
        if !decrypted.isEmpty {
          messages[id] = decrypted
        }
      }
      return ["messages": messages]
    }

    AsyncFunction("encryptMessage") { (input: [String: Any]) throws -> String in
      guard let recipientPublicKeyPem = input["recipientPublicKey"] as? String else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 20,
          userInfo: [NSLocalizedDescriptionKey: "recipientPublicKey is required"]
        )
      }
      let message = (input["message"] as? String) ?? ""
      let myPublicKeyPem = input["myPublicKey"] as? String
      return try encryptHybridMessage(
        recipientPublicKeyPem: recipientPublicKeyPem,
        message: message,
        myPublicKeyPem: myPublicKeyPem
      )
    }

    AsyncFunction("normalizeRowsBatch") { (input: [String: Any]) -> [String: Any] in
      return [
        "rows": input["rows"] ?? [],
        "changed": false
      ]
    }

    // MARK: - PBKDF2 Key Derivation (CommonCrypto, hardware-accelerated)

    AsyncFunction("deriveKey") { (input: [String: Any]) throws -> String in
      guard let passphrase = input["passphrase"] as? String,
            let salt = input["salt"] as? String else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 30,
          userInfo: [NSLocalizedDescriptionKey: "passphrase and salt are required"]
        )
      }
      let iterations = UInt32((input["iterations"] as? Int) ?? 600_000)
      let keyLength = (input["keyLength"] as? Int) ?? 32

      let passphraseData = Data(passphrase.utf8)
      let saltData = Data(salt.utf8)
      var derivedKey = Data(count: keyLength)

      let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
        passphraseData.withUnsafeBytes { passphraseBytes in
          saltData.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
              CCPBKDFAlgorithm(kCCPBKDF2),
              passphraseBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
              passphraseData.count,
              saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
              saltData.count,
              CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
              iterations,
              derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
              keyLength
            )
          }
        }
      }

      guard status == kCCSuccess else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 31,
          userInfo: [NSLocalizedDescriptionKey: "PBKDF2 derivation failed (\(status))"]
        )
      }
      return derivedKey.base64EncodedString()
    }

    // MARK: - File-Level AES-256-GCM Encryption (CryptoKit)

    AsyncFunction("encryptFileData") { (input: [String: Any]) throws -> [String: String] in
      guard let dataBase64 = input["data"] as? String,
            let fileData = Data(base64Encoded: dataBase64) else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 40,
          userInfo: [NSLocalizedDescriptionKey: "Invalid base64 file data"]
        )
      }
      let aesKey = try randomBytes(count: 32)
      let iv = try randomBytes(count: 12)
      let nonce = try AES.GCM.Nonce(data: iv)
      let sealed = try AES.GCM.seal(
        fileData,
        using: SymmetricKey(data: aesKey),
        nonce: nonce
      )
      var combined = Data()
      combined.append(iv)
      combined.append(sealed.ciphertext)
      combined.append(sealed.tag)
      return [
        "encryptedBase64": combined.base64EncodedString(),
        "keyBase64": aesKey.base64EncodedString(),
      ]
    }

    AsyncFunction("decryptFileData") { (input: [String: Any]) throws -> String in
      guard let encryptedBase64 = input["encryptedBase64"] as? String,
            let keyBase64 = input["keyBase64"] as? String,
            let combined = Data(base64Encoded: encryptedBase64),
            let aesKey = Data(base64Encoded: keyBase64),
            combined.count > 28 else {
        throw NSError(
          domain: "ChatNativeCore",
          code: 50,
          userInfo: [NSLocalizedDescriptionKey: "Invalid encrypted file data or key"]
        )
      }
      let iv = combined.prefix(12)
      let ciphertextData = combined.dropFirst(12).dropLast(16)
      let tagData = combined.suffix(16)
      let nonce = try AES.GCM.Nonce(data: iv)
      let sealedBox = try AES.GCM.SealedBox(
        nonce: nonce,
        ciphertext: ciphertextData,
        tag: tagData
      )
      let plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: aesKey))
      return plaintext.base64EncodedString()
    }
  }
}
