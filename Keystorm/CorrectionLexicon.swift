import Foundation

enum CorrectionLexicalVerdict: String, Codable, Sendable {
    case knownSourceWord, notInExclusionLexicon, unavailable
}

/// Absence from a finite exclusion list is orthographic unknown, never proof
/// that a word is invalid. The model and all other learning gates still apply.
struct CorrectionLexicalAssessment: Codable, Equatable, Sendable {
    var policyVersion = 1
    var evidenceSHA256: String
    var variantSHA256: String
    var verdict: CorrectionLexicalVerdict
    var lexiconSHA256: String?

    init(evidence: CorrectionEvidence, verdict: CorrectionLexicalVerdict, lexiconSHA256: String? = nil) {
        evidenceSHA256 = evidence.sha256
        variantSHA256 = DictationTransformPolicy.sourceDigest(evidence.variant)
        self.verdict = verdict
        self.lexiconSHA256 = lexiconSHA256
    }

    func isBound(to evidence: CorrectionEvidence) -> Bool {
        guard policyVersion == 1, evidenceSHA256 == evidence.sha256,
              variantSHA256 == DictationTransformPolicy.sourceDigest(evidence.variant) else { return false }
        switch verdict {
        case .unavailable:
            return lexiconSHA256.map(DictationTransformPolicy.hasValidDigestFormat) ?? true
        case .knownSourceWord, .notInExclusionLexicon:
            return lexiconSHA256.map(DictationTransformPolicy.hasValidDigestFormat) == true
        }
    }

    func permitsAdditionalAutomaticGate(for evidence: CorrectionEvidence) -> Bool {
        isBound(to: evidence) && verdict == .notInExclusionLexicon
    }
}

protocol CorrectionLexicalAssessing: Sendable {
    func assess(_ evidence: CorrectionEvidence) async -> CorrectionLexicalAssessment
}

/// An immutable, checksummed bundled exclusion list. It never calls an OS
/// spelling provider, modifies user settings, or performs a network request.
actor BundledCorrectionLexicon: CorrectionLexicalAssessing {
    static let shared = BundledCorrectionLexicon()
    static let maxResourceBytes = 8 * 1_024 * 1_024
    static let maxEntries = 200_000

    struct Resource: Sendable {
        var data: Data
        var expectedSHA256: String
    }

    private enum LoadState {
        case notLoaded, unavailable, ready(Set<String>, String)
    }

    private let load: @Sendable () throws -> (Resource, Resource)
    private var state: LoadState = .notLoaded

    init(loader: (@Sendable () throws -> (Resource, Resource))? = nil) {
        load = loader ?? {
            func resource(_ name: String, hash: String) throws -> Resource {
                guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else {
                    throw CorrectionLearningError.unsupportedStore
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maxResourceBytes else {
                    throw CorrectionLearningError.unsupportedStore
                }
                return Resource(data: try Data(contentsOf: url), expectedSHA256: hash)
            }
            return (
                try resource(LearningLexiconResourcePins.englishResourceName, hash: LearningLexiconResourcePins.englishSHA256),
                try resource(LearningLexiconResourcePins.germanResourceName, hash: LearningLexiconResourcePins.germanSHA256)
            )
        }
    }

    func assess(_ evidence: CorrectionEvidence) -> CorrectionLexicalAssessment {
        guard !Task.isCancelled, CorrectionLearningPolicy.validTerm(evidence.variant) else {
            return CorrectionLexicalAssessment(evidence: evidence, verdict: .unavailable)
        }
        if case .notLoaded = state {
            do {
                let (english, german) = try load()
                let englishWords = try Self.words(in: english)
                let germanWords = try Self.words(in: german)
                let digest = DictationTransformPolicy.sourceDigest(
                    "learning-exclusion-v1\nen:" + english.expectedSHA256 + "\nde:" + german.expectedSHA256 + "\n")
                state = .ready(englishWords.union(germanWords), digest)
            } catch {
                state = .unavailable
            }
        }
        guard !Task.isCancelled, case .ready(let words, let hash) = state else {
            return CorrectionLexicalAssessment(evidence: evidence, verdict: .unavailable)
        }
        let normalized = Self.normalized(evidence.variant)
        return CorrectionLexicalAssessment(evidence: evidence,
            verdict: words.contains(normalized) ? .knownSourceWord : .notInExclusionLexicon,
            lexiconSHA256: hash)
    }

    static func normalized(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
    }

    private static func words(in resource: Resource) throws -> Set<String> {
        guard resource.data.count > 0, resource.data.count <= maxResourceBytes,
              DictationTransformPolicy.hasValidDigestFormat(resource.expectedSHA256),
              let text = String(data: resource.data, encoding: .utf8),
              DictationTransformPolicy.sourceDigest(text) == resource.expectedSHA256,
              text.hasSuffix("\n") else { throw CorrectionLearningError.unsupportedStore }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.last == "", lines.count > 1, lines.count <= maxEntries + 1 else {
            throw CorrectionLearningError.unsupportedStore
        }
        var result = Set<String>()
        var previous: String?
        for line in lines.dropLast() {
            let word = String(line)
            guard !word.isEmpty, word.utf8.count <= 128,
                  word.utf8.elementsEqual(normalized(word).utf8),
                  word.unicodeScalars.allSatisfy({
                      CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
                  }),
                  previous.map({ $0.utf8.lexicographicallyPrecedes(word.utf8) }) ?? true,
                  result.insert(word).inserted else { throw CorrectionLearningError.unsupportedStore }
            previous = word
        }
        return result
    }
}

/// Shared by collection, retrieval, and final literal application. A credential
/// label excludes the nearby bounded occurrence even when the term was approved.
enum CorrectionSensitiveContext {
    static func contains(_ text: String) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let single = Set(["password", "passwords", "passphrase", "passphrases", "passcode", "passcodes",
            "credential", "credentials", "secret", "secrets", "token", "tokens", "bearer",
            "passwort", "passworter", "kennwort", "kennworter", "passphrasen",
            "zugangsdaten", "anmeldedaten", "geheimnis", "geheimnisse", "privatschlussel",
            "zugangsschlussel", "wiederherstellungsschlussel", "wiederherstellungsphrase",
            "sicherheitscode", "privatekey", "apikey", "accesskey", "recoverykey",
            "recoveryphrase", "seedphrase", "sshkey", "pin", "pincode", "otp", "totp"])
        let families = ["password", "passphrase", "passwort", "kennwort", "zugangscode",
            "zugangsschl", "zugangskenn", "zugangsnummer", "zugangsgeheim",
            "zugriffscode", "zugriffsschl", "anmeldecode", "anmeldekenn",
            "anmeldeschl", "anmeldenummer", "anmeldepass", "geheimnummer",
            "geheimzahl", "geheimziffer", "geheimcode", "geheimschl",
            "sicherheitsschl", "sicherheitscode", "sicherheitsnummer",
            "sicherheitstoken", "sicherheitskenn", "codewort", "accesscode",
            "securitykey", "securitycode", "secretnumber", "secretcode",
            "secretkey", "secretphrase", "recoverycode", "backupcode"]
        if words.contains(where: { word in
            let withoutTrailingDigits = String(word.reversed().drop(while: \.isNumber).reversed())
            return single.contains(word) || single.contains(withoutTrailingDigits) ||
                families.contains(where: word.hasPrefix)
        }) { return true }
        let joined = words.joined(separator: " ")
        let phrases = ["private key", "private keys", "api key", "api keys", "access key",
            "access keys", "recovery key", "recovery phrase", "seed phrase", "seed words",
            "ssh key", "private schlussel", "privater schlussel", "privaten schlussel",
            "privatem schlussel", "api schlussel", "geheimer schlussel",
            "access code", "security code", "security key", "secret number", "secret code",
            "secret key", "authentication code", "verification code", "one time code",
            "pass code", "pass phrase", "zugangs code", "zugriffs code", "anmelde code",
            "zugangs schlussel", "zugangs schluessel", "zugriffs schlussel",
            "sicherheits schlussel", "sicherheits schluessel", "geheim nummer",
            "geheim zahl", "geheime nummer", "geheimen nummer", "geheime zahl", "geheimen zahl"]
        return phrases.contains { (" " + joined + " ").contains(" " + $0 + " ") }
    }

    /// Frozen finite v3 behavior. Keep independent of future collection guards:
    /// it validates old derived state and never authorizes current application.
    static func containsLegacyV3(evidence: CorrectionEvidence) -> Bool {
        func legacy(_ text: String) -> Bool {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
            let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let single = Set(["password", "passwords", "passphrase", "passphrases", "passcode", "passcodes",
                "credential", "credentials", "secret", "secrets", "token", "tokens", "bearer",
                "passwort", "passworter", "kennwort", "kennworter", "passphrasen",
                "zugangsdaten", "anmeldedaten", "geheimnis", "geheimnisse", "privatschlussel",
                "zugangsschlussel", "wiederherstellungsschlussel", "wiederherstellungsphrase",
                "sicherheitscode", "privatekey", "apikey", "accesskey", "recoverykey",
                "recoveryphrase", "seedphrase", "sshkey", "pin", "pincode", "otp", "totp"])
            if words.contains(where: { word in
                let withoutTrailingDigits = String(word.reversed().drop(while: \.isNumber).reversed())
                return single.contains(word) || single.contains(withoutTrailingDigits) ||
                    ["password", "passphrase", "passwort", "kennwort"].contains(where: word.hasPrefix)
            }) { return true }
            let joined = words.joined(separator: " ")
            let phrases = ["private key", "private keys", "api key", "api keys", "access key",
                "access keys", "recovery key", "recovery phrase", "seed phrase", "seed words",
                "ssh key", "private schlussel", "privater schlussel", "privaten schlussel",
                "privatem schlussel", "api schlussel", "geheimer schlussel"]
            return phrases.contains { (" " + joined + " ").contains(" " + $0 + " ") }
        }
        return legacy(evidence.leftContext + evidence.variant + evidence.rightContext) ||
            legacy(evidence.leftContext + evidence.canonical + evidence.rightContext)
    }

    static func contains(evidence: CorrectionEvidence) -> Bool {
        contains(evidence.leftContext + evidence.variant + evidence.rightContext) ||
            contains(evidence.leftContext + evidence.canonical + evidence.rightContext)
    }

    static func contains(in source: String, around range: Range<String.Index>, replacement: String) -> Bool {
        let left = String(source[..<range.lowerBound].suffix(128))
        let right = String(source[range.upperBound...].prefix(128))
        return contains(left + String(source[range]) + right) || contains(left + replacement + right)
    }
}
