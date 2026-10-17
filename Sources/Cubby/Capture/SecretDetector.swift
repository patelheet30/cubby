import Foundation

/// Spots copied text that looks like a secret (API keys, private keys, tokens, card numbers, one-time codes),
/// so it can be blurred in the drawer and deleted after a few minutes.
enum SecretDetector {
    enum Kind: String { case apiKey = "API key", privateKey = "Private key", token = "Token", card = "Card number", code = "One-time code" }

    /// Known key formats, matched anywhere in the text (a key pasted inside a .env line still counts).
    private static let keyPatterns: [(Kind, NSRegularExpression)] = ([
        (.privateKey, "-----BEGIN [A-Z ]*PRIVATE KEY-----"),
        (.apiKey, #"\bsk-[A-Za-z0-9_-]{20,}"#),                     // OpenAI, Anthropic (sk-ant-…)
        (.apiKey, #"\b[sr]k_(live|test)_[A-Za-z0-9]{16,}"#),        // Stripe secret / restricted
        (.apiKey, #"\bgh[pousr]_[A-Za-z0-9]{30,}"#),                // GitHub
        (.apiKey, #"\bgithub_pat_[A-Za-z0-9_]{40,}"#),
        (.apiKey, #"\bxox[abpr]-[A-Za-z0-9-]{10,}"#),               // Slack
        (.apiKey, #"\bAKIA[0-9A-Z]{16}\b"#),                        // AWS access key ID
        (.apiKey, #"\bAIza[0-9A-Za-z_-]{35}\b"#),                   // Google
        (.apiKey, #"\bglpat-[A-Za-z0-9_-]{20,}"#),                  // GitLab
        (.apiKey, #"\bnpm_[A-Za-z0-9]{36}\b"#),
        (.token, #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#), // JWT
    ] as [(Kind, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    private static let codePhrase = try! NSRegularExpression(
        pattern: #"(?i)\b(code|otp|passcode|verification|pin)\b[^0-9]{0,24}\b(\d{4,8})\b"#)
    private static let uuid = try! NSRegularExpression(pattern: #"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$"#)

    static func check(_ text: String) -> Kind? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let all = NSRange(t.startIndex..., in: t)
        for (kind, re) in keyPatterns where re.firstMatch(in: t, range: all) != nil { return kind }

        if isCardNumber(t) { return .card }
        // One-time codes: a lone 6–8 digit number, or a short message like "Your code is 4821".
        if t.count >= 6, t.count <= 8, t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber) { return .code }
        if t.count < 200, codePhrase.firstMatch(in: t, range: all) != nil { return .code }

        if isHighEntropyToken(t) { return .token }
        return nil
    }

    /// 13–19 digits (spaces or dashes allowed between groups) that pass the Luhn check.
    static func isCardNumber(_ t: String) -> Bool {
        guard t.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return false }
        let digits = t.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            let v = i % 2 == 1 ? d * 2 : d
            sum += v > 9 ? v - 9 : v
        }
        return sum % 10 == 0
    }

    /// One long word mixing character classes with high Shannon entropy, e.g. a random API token with no known prefix.
    /// UUIDs, git hashes (hex only) and URLs don't count.
    static func isHighEntropyToken(_ t: String) -> Bool {
        guard t.count >= 32, t.count <= 512, !t.contains(where: \.isWhitespace), !t.contains("://"),
              uuid.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil else { return false }
        let classes = [t.contains(where: \.isLowercase), t.contains(where: \.isUppercase), t.contains(where: \.isNumber),
                       t.contains { "-_+/=.".contains($0) }].filter { $0 }.count
        guard classes >= 3 else { return false }
        var freq: [Character: Int] = [:]
        t.forEach { freq[$0, default: 0] += 1 }
        let n = Double(t.count)
        let entropy = freq.values.reduce(0.0) { e, c in let p = Double(c) / n; return e - p * log2(p) }
        return entropy >= 4.0
    }
}
