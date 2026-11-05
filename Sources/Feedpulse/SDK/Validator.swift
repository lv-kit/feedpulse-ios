import Foundation

/// クライアント側の入力検証の結果。
public struct FeedpulseValidationResult: Equatable, Sendable {
    /// 検証と正規化（制御文字の除去・前後空白の除去・重複の除去）を通った値。空の任意項目は含まない。
    public var cleaned: [String: FeedpulseValue]
    /// ブロック ID → エラー。空なら送信できる。
    public var errors: [String: FeedpulseFieldError]
    public var isValid: Bool { errors.isEmpty }
}

extension FeedpulseForm {
    /// 項目定義に基づいて入力を検証する。規則はサーバー（`validateFields`）と同じ。
    /// サーバーはこの結果と同じ内容で再検証する（クライアント検証は UX のためで、信頼境界ではない）。
    public func validate(_ values: [String: FeedpulseValue]) -> FeedpulseValidationResult {
        FormValidator.validate(blocks: definition.blocks, values: values)
    }
}

enum FormValidator {
    static let defaultShortMax = 200
    static let defaultLongMax = 5000
    static let emailMax = 254

    static func validate(blocks: [FeedpulseBlock], values: [String: FeedpulseValue]) -> FeedpulseValidationResult {
        var cleaned: [String: FeedpulseValue] = [:]
        var errors: [String: FeedpulseFieldError] = [:]
        for block in blocks {
            guard let raw = values[block.id], !isEmpty(raw) else {
                if block.required { errors[block.id] = .required }
                continue
            }
            switch validateBlock(block, raw) {
            case .failure(let code):
                errors[block.id] = code
            case .success(let value):
                if case .text("") = value {
                    if block.required { errors[block.id] = .required }
                } else {
                    cleaned[block.id] = value
                }
            }
        }
        return .init(cleaned: cleaned, errors: errors)
    }

    private static func isEmpty(_ v: FeedpulseValue) -> Bool {
        switch v {
        case .text(let s): return s.isEmpty
        case .list(let l): return l.isEmpty
        case .number: return false
        }
    }

    /// サーバーの `stripControlChars`: U+0000–001F と U+007F を除く（`keepWhitespace` なら TAB / LF / CR は残す）。
    static func stripControl(_ s: String, keepWhitespace: Bool) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            let v = u.value
            if v == 0x7F { return false }
            if v > 0x1F { return true }
            return keepWhitespace && (v == 0x09 || v == 0x0A || v == 0x0D)
        }))
    }

    /// JS の `String.prototype.trim` 相当（空白と行終端子）。
    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateBlock(_ block: FeedpulseBlock, _ raw: FeedpulseValue) -> Result<FeedpulseValue, FeedpulseFieldError> {
        switch block.type {
        case .shortText, .longText:
            guard case .text(let s) = raw else { return .failure(.type) }
            let isLong = block.type == .longText
            let text = trim(stripControl(s, keepWhitespace: isLong))
            let max = block.maxLength ?? (isLong ? defaultLongMax : defaultShortMax)
            return text.utf16.count > max ? .failure(.tooLong) : .success(.text(text))
        case .email:
            guard case .text(let s) = raw else { return .failure(.type) }
            let text = trim(stripControl(s, keepWhitespace: false))
            return text.utf16.count > emailMax || !isEmail(text) ? .failure(.invalidEmail) : .success(.text(text))
        case .number:
            guard case .number(let n) = raw, n.isFinite else { return .failure(.type) }
            if let min = block.min, n < min { return .failure(.outOfRange) }
            if let max = block.max, n > max { return .failure(.outOfRange) }
            return .success(raw)
        case .select, .radio:
            guard case .text(let s) = raw else { return .failure(.type) }
            return (block.options ?? []).contains { $0.value == s } ? .success(raw) : .failure(.invalidOption)
        case .checkbox:
            guard case .list(let l) = raw else { return .failure(.type) }
            var seen = Set<String>()
            let unique = l.filter { seen.insert($0).inserted }
            let options = block.options ?? []
            return unique.allSatisfy { v in options.contains { $0.value == v } } ? .success(.list(unique)) : .failure(.invalidOption)
        case .rating:
            guard case .number(let n) = raw, n.isFinite, n == n.rounded() else { return .failure(.type) }
            return n < 1 || n > Double(block.max ?? 5) ? .failure(.outOfRange) : .success(raw)
        case .image, .file:
            guard case .list(let l) = raw else { return .failure(.type) }
            if l.contains(where: { !isUUID($0) }) || Set(l).count != l.count { return .failure(.invalidUpload) }
            return l.count > (block.maxFiles ?? 0) ? .failure(.tooManyFiles) : .success(raw)
        case .unknown:
            // 将来のブロック種別。SDK では判定できないのでサーバーに任せる。
            return .success(raw)
        }
    }

    /// `^[^\s@]+@[^\s@]+\.[^\s@]+$`
    static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private static func isUUID(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }
}
