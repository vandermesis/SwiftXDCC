//
//  CertFPIdentityStore.swift
//  SwiftXDCC
//
//  Created by Codex on 13/06/2026.
//

import CryptoKit
import Foundation
@preconcurrency import NIOSSL
import Observation
import Security
import SwiftASN1
import X509

enum CertFPIdentitySource: String, Codable, Sendable {
    case generated
    case imported

    var label: String {
        switch self {
        case .generated: "Generated"
        case .imported: "Imported"
        }
    }
}

struct CertFPIdentity: Codable, Sendable {
    let pemData: Data
    let source: CertFPIdentitySource
    let displayName: String
    let fingerprint: String
    let createdAt: Date
    let expiresAt: Date

    var certificatePEM: String? {
        Self.pemBlock(
            in: pemData,
            pattern: #"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----"#
        )
    }

    var privateKeyPEM: String? {
        Self.pemBlock(
            in: pemData,
            pattern: #"-----BEGIN (?:EC |RSA )?PRIVATE KEY-----[\s\S]*?-----END (?:EC |RSA )?PRIVATE KEY-----"#
        )
    }

    private static func pemBlock(in data: Data, pattern: String) -> String? {
        guard let pem = String(data: data, encoding: .utf8),
              let range = pem.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(pem[range]) + "\n"
    }
}

enum CertFPRegistrationState: Equatable {
    case unavailable
    case needsRegistration
    case registering
    case registered
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: "Certificate unavailable"
        case .needsRegistration: "Not registered"
        case .registering: "Registering…"
        case .registered: "Registered"
        case .failed(let message): message
        }
    }
}

@MainActor
@Observable
final class CertFPIdentityStore {
    private static let keychainService = "vandermesis.SwiftXDCC.certfp"
    private static let keychainAccount = "client-identity"
    private static let registrationsKey = "certfpRegistrations"

    private(set) var identity: CertFPIdentity?
    private(set) var errorMessage: String?

    private var registrations: Set<String>

    init() {
        registrations = Set(
            UserDefaults.standard.stringArray(forKey: Self.registrationsKey) ?? []
        )

        do {
            identity = try Self.loadIdentity()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generate(nickname: String) throws {
        let commonName = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = try Self.makeIdentity(
            commonName: commonName.isEmpty ? "SwiftXDCC User" : commonName
        )
        try replaceIdentity(identity)
    }

    func importPEM(_ data: Data, displayName: String) throws {
        let metadata = try Self.inspectPEM(data)
        let identity = CertFPIdentity(
            pemData: data,
            source: .imported,
            displayName: displayName,
            fingerprint: metadata.fingerprint,
            createdAt: metadata.createdAt,
            expiresAt: metadata.expiresAt
        )

        // NIOSSL requires both a certificate and a matching private key.
        _ = try NIOSSLIdentityValidator.validate(data)
        try replaceIdentity(identity)
    }

    func deleteIdentity() throws {
        try Self.deleteKeychainItem()
        identity = nil
        registrations.removeAll()
        saveRegistrations()
    }

    func registrationState(for hostname: String) -> CertFPRegistrationState {
        guard let identity else { return .unavailable }
        return registrations.contains(registrationKey(
            hostname: hostname,
            fingerprint: identity.fingerprint
        )) ? .registered : .needsRegistration
    }

    func isRegistered(on hostname: String) -> Bool {
        registrationState(for: hostname) == .registered
    }

    func markRegistered(on hostname: String) {
        guard let identity else { return }
        registrations.insert(registrationKey(
            hostname: hostname,
            fingerprint: identity.fingerprint
        ))
        saveRegistrations()
    }

    func markUnregistered(on hostname: String) {
        guard let identity else { return }
        registrations.remove(registrationKey(
            hostname: hostname,
            fingerprint: identity.fingerprint
        ))
        saveRegistrations()
    }

    private func replaceIdentity(_ identity: CertFPIdentity) throws {
        try Self.saveIdentity(identity)
        self.identity = identity
        registrations.removeAll()
        saveRegistrations()
        errorMessage = nil
    }

    private func registrationKey(hostname: String, fingerprint: String) -> String {
        "\(hostname.lowercased())|\(fingerprint)"
    }

    private func saveRegistrations() {
        UserDefaults.standard.set(registrations.sorted(), forKey: Self.registrationsKey)
    }

    private static func makeIdentity(commonName: String) throws -> CertFPIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false,
            kSecAttrIsExtractable as String: true
        ]
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
            throw keyError?.takeRetainedValue() ?? CertFPError.keyGenerationFailed
        }

        let privateKey = try Certificate.PrivateKey(secKey)
        let name = try DistinguishedName {
            OrganizationName("SwiftXDCC")
            CommonName(commonName)
        }
        let now = Date()
        let expiry = Calendar.current.date(byAdding: .year, value: 10, to: now)
            ?? now.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: expiry,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
            },
            issuerPrivateKey: privateKey
        )

        let certificateDocument = try certificate.serializeAsPEM()
        let privateKeyDocument = try privateKey.serializeAsPEM()
        let combinedPEM = [
            certificateDocument.pemString,
            privateKeyDocument.pemString
        ].joined(separator: "\n") + "\n"
        guard let pemData = combinedPEM.data(using: .utf8) else {
            throw CertFPError.invalidPEM
        }
        try NIOSSLIdentityValidator.validate(pemData)

        return CertFPIdentity(
            pemData: pemData,
            source: .generated,
            displayName: "SwiftXDCC CertFP",
            fingerprint: fingerprint(for: certificateDocument.derBytes),
            createdAt: certificate.notValidBefore,
            expiresAt: certificate.notValidAfter
        )
    }

    private static func inspectPEM(
        _ data: Data
    ) throws -> (fingerprint: String, createdAt: Date, expiresAt: Date) {
        guard let pem = String(data: data, encoding: .utf8),
              pem.contains("PRIVATE KEY"),
              let range = pem.range(
                of: #"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----"#,
                options: .regularExpression
              ) else {
            throw CertFPError.invalidPEM
        }

        let certificate = try Certificate(pemEncoded: String(pem[range]))
        let document = try certificate.serializeAsPEM()
        return (
            fingerprint(for: document.derBytes),
            certificate.notValidBefore,
            certificate.notValidAfter
        )
    }

    private static func fingerprint<Bytes: DataProtocol>(for bytes: Bytes) -> String {
        SHA256.hash(data: Data(bytes)).map {
            String(format: "%02X", $0)
        }.joined(separator: ":")
    }

    private static func saveIdentity(_ identity: CertFPIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        let query = baseKeychainQuery
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        try check(status)
    }

    private static func loadIdentity() throws -> CertFPIdentity? {
        var query = baseKeychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try check(status)
        guard let data = result as? Data else {
            throw CertFPError.invalidKeychainData
        }
        let stored = try JSONDecoder().decode(CertFPIdentity.self, from: data)
        let normalized = try normalizedIdentity(stored)
        if normalized.pemData != stored.pemData {
            try saveIdentity(normalized)
        }
        return normalized
    }

    private static func deleteKeychainItem() throws {
        let status = SecItemDelete(baseKeychainQuery as CFDictionary)
        guard status != errSecItemNotFound else { return }
        try check(status)
    }

    private static var baseKeychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String?
            throw CertFPError.keychain(status, message ?? "Unknown Keychain error")
        }
    }

    private static func normalizedIdentity(_ identity: CertFPIdentity) throws -> CertFPIdentity {
        guard let certificate = identity.certificatePEM,
              let privateKey = identity.privateKeyPEM,
              let data = (certificate + privateKey).data(using: .utf8) else {
            throw CertFPError.invalidPEM
        }
        try NIOSSLIdentityValidator.validate(data)
        return CertFPIdentity(
            pemData: data,
            source: identity.source,
            displayName: identity.displayName,
            fingerprint: identity.fingerprint,
            createdAt: identity.createdAt,
            expiresAt: identity.expiresAt
        )
    }
}

/// Keeps PEM validation aligned with the exact NIOSSL parsing used by the client.
private enum NIOSSLIdentityValidator {
    static func validate(_ data: Data) throws {
        let pem = String(decoding: data, as: UTF8.self)
        guard let certificateRange = pem.range(
            of: #"-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----"#,
            options: .regularExpression
        ), let privateKeyRange = pem.range(
            of: #"-----BEGIN (?:EC |RSA )?PRIVATE KEY-----[\s\S]*?-----END (?:EC |RSA )?PRIVATE KEY-----"#,
            options: .regularExpression
        ) else {
            throw CertFPError.invalidPEM
        }

        let certificates = try NIOSSLCertificate.fromPEMBytes(
            Array(pem[certificateRange].utf8)
        )
        let privateKey = try NIOSSLPrivateKey(
            bytes: Array(pem[privateKeyRange].utf8),
            format: .pem
        )
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateChain = certificates.map { .certificate($0) }
        configuration.privateKey = .privateKey(privateKey)
        _ = try NIOSSLContext(configuration: configuration)
    }
}

enum CertFPError: LocalizedError {
    case invalidPEM
    case invalidKeychainData
    case keyGenerationFailed
    case keychain(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .invalidPEM:
            "The PEM must contain an X.509 certificate and its private key."
        case .invalidKeychainData:
            "The stored CertFP identity could not be decoded."
        case .keyGenerationFailed:
            "The P-256 private key could not be generated."
        case .keychain(let status, let message):
            "Keychain error \(status): \(message)"
        }
    }
}
