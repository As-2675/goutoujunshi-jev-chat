import Foundation

struct PinyinCandidate: Equatable {
    let text: String
    /// Number of ASCII characters consumed, including explicit syllable separators.
    let consumed: Int
}

/// Small, offline full-Pinyin decoder. No network, input history or learned-word storage.
/// Exact words, bounded sentence segmentation, and incomplete final syllables are supported.
final class PinyinEngine: Sendable {
    private struct Word: Sendable { let text: String; let score: Double; let boundaries: UInt64 }
    private struct Path { let text: String; let score: Double }
    private let words: [String: [Word]]
    private let codes: [String]
    /// 九宫格（T9）索引：数字串 → 拼音码。dictionary 的码本身就是纯字母，
    /// 直接把每个码映射成 2–9 的数字串，用户敲数字就等于敲了一条前缀。
    private let digitIndex: [String: [String]]
    private let digitKeys: [String]
    let entryCount: Int
    private let beamWidth = 5

    init(tsv: String) {
        var entries = [String: [(String, Double, UInt64)]]()
        var count = 0
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, let weight = Double(parts[2]), weight >= 0 else { continue }
            let code = String(parts[0]), word = String(parts[1])
            guard !code.isEmpty, code.count <= 32, !word.isEmpty,
                  code.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { continue }
            let spelling = parts.count > 3 ? String(parts[3]) : code
            entries[code, default: []].append((word, weight, Self.boundaries(spelling)))
            count += 1
        }
        // Frequency is a local dictionary ranking score, unrelated to model probabilities.
        var index = [String: [Word]]()
        for (code, values) in entries {
            index[code] = values.sorted {
                $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
            }.prefix(12).map { Word(text: $0.0, score: log(max(1, $0.1)) - 18, boundaries: $0.2) }
        }
        var byDigit = [String: [String]]()
        for code in index.keys {
            let digits = Self.digits(of: code)
            guard !digits.isEmpty else { continue }
            byDigit[digits, default: []].append(code)
        }
        digitIndex = byDigit
        digitKeys = byDigit.keys.sorted()
        words = index; codes = index.keys.sorted(); entryCount = count
    }

    /// 九宫格输入：数字串按 T9 映射到拼音码（含前缀补全），候选沿用同一份词库排序。
    /// 缺点是不支持任意字母串，好处是不用做数字→字母的组合爆炸。
    func candidates(forDigits digits: String, limit: Int = 24) -> [PinyinCandidate] {
        guard !digits.isEmpty, digits.count <= 24, limit > 0,
              digits.utf8.allSatisfy({ $0 >= 50 && $0 <= 57 }) else { return [] }
        var scored = [(text: String, score: Double)]()
        var scanned = 0
        for key in digitKeysFrom(digits) {
            scanned += 1
            if scanned > 160 { break }
            guard let codes = digitIndex[key] else { continue }
            for code in codes.prefix(8) {
                for word in (words[code] ?? []).prefix(3) {
                    scored.append((word.text, word.score))
                }
            }
        }
        var seen = Set<String>()
        return scored.sorted { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            .filter { seen.insert($0.text).inserted }
            .prefix(limit)
            .map { PinyinCandidate(text: $0.text, consumed: digits.count) }
    }

    private func digitKeysFrom(_ prefix: String) -> ArraySlice<String> {
        var lower = 0, upper = digitKeys.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if digitKeys[middle] < prefix { lower = middle + 1 } else { upper = middle }
        }
        var end = lower
        while end < digitKeys.count, digitKeys[end].hasPrefix(prefix), end - lower < 200 { end += 1 }
        return digitKeys[lower..<end]
    }

    private static func digits(of code: String) -> String {
        var result = ""
        for byte in code.utf8 {
            switch byte {
            case 97, 98, 99: result += "2"          // abc
            case 100, 101, 102: result += "3"       // def
            case 103, 104, 105: result += "4"       // ghi
            case 106, 107, 108: result += "5"       // jkl
            case 109, 110, 111: result += "6"       // mno
            case 112...115: result += "7"           // pqrs
            case 116, 117, 118: result += "8"       // tuv
            case 119, 120, 121, 122: result += "9"  // wxyz
            default: return ""
            }
        }
        return result
    }

    func candidates(for input: String, limit: Int = 24) -> [PinyinCandidate] {
        guard !input.isEmpty, input.count <= 64, limit > 0,
              input.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || $0 == 39 }) else { return [] }
        let raw = Array(input.utf8)
        // Separators are boundaries: xi'an must not match xian (先).
        var paths = Array(repeating: [Path](), count: raw.count + 1)
        paths[0] = [Path(text: "", score: 0)]
        var partial = [(PinyinCandidate, Double)]()
        for start in 0..<raw.count where !paths[start].isEmpty {
            if raw[start] == 39 {
                paths[start + 1] = best(paths[start + 1] + paths[start])
                continue
            }
            var code = "", separators: UInt64 = 0
            for end in (start + 1)...min(raw.count, start + 32) {
                if raw[end - 1] == 39 { separators |= 1 << code.count; continue }
                code += String(UnicodeScalar(raw[end - 1]))
                guard let matches = words[code]?.filter({ ($0.boundaries & separators) == separators }), !matches.isEmpty else { continue }
                var additions = [Path]()
                for path in paths[start] {
                    for word in matches.prefix(beamWidth) {
                        additions.append(Path(text: path.text + word.text, score: path.score + word.score))
                    }
                }
                paths[end] = best(paths[end] + additions)
                if start == 0 && end < raw.count {
                    partial += matches.map { (PinyinCandidate(text: $0.text, consumed: end), $0.score) }
                }
            }
        }
        var result = paths[raw.count].map { PinyinCandidate(text: $0.text, consumed: raw.count) }
        // Preserve more single-word alternatives than the sentence beam retains.
        let normalized = input.replacingOccurrences(of: "'", with: "")
        let boundaries = Self.boundaries(input.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
        if let exact = words[normalized] {
            result = exact.filter { ($0.boundaries & boundaries) == boundaries }
                .map { PinyinCandidate(text: $0.text, consumed: raw.count) } + result
        }
        // Offer word completions for a partially typed final syllable (niha -> 你好).
        var completions = [(PinyinCandidate, Double)]()
        for start in 0..<raw.count where !paths[start].isEmpty {
            let typed = String(decoding: raw[start...], as: UTF8.self)
            let suffix = typed.replacingOccurrences(of: "'", with: "")
            let separators = Self.boundaries(typed)
            guard !suffix.isEmpty, suffix.count <= 16 else { continue }
            for code in prefixCodes(suffix).prefix(160) where code.count > suffix.count {
                for word in (words[code] ?? []).filter({ ($0.boundaries & separators) == separators }).prefix(3) {
                    let path = paths[start][0]
                    completions.append((PinyinCandidate(text: path.text + word.text, consumed: raw.count),
                                        path.score + word.score - Double(code.count - suffix.count) * 1.5))
                }
            }
        }
        result += completions.sorted { $0.1 == $1.1 ? $0.0.text < $1.0.text : $0.1 > $1.1 }.prefix(12).map(\.0)
        // Partial leading words allow manual conversion when the whole sentence is ambiguous.
        result += partial.sorted {
            $0.0.consumed == $1.0.consumed ? $0.1 > $1.1 : $0.0.consumed > $1.0.consumed
        }.map(\.0)
        var seen = Set<String>()
        return Array(result.filter { seen.insert("\($0.consumed):\($0.text)").inserted }.prefix(limit))
    }

    private func best(_ values: [Path]) -> [Path] {
        var seen = Set<String>()
        return Array(values.sorted { $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score }
            .filter { seen.insert($0.text).inserted }.prefix(beamWidth))
    }
    private static func boundaries(_ spelling: String) -> UInt64 {
        var position = 0, mask: UInt64 = 0
        for byte in spelling.utf8 {
            if byte == 39, position < 64 { mask |= 1 << position }
            else { position += 1 }
        }
        return mask
    }
    private func prefixCodes(_ prefix: String) -> ArraySlice<String> {
        var lower = 0, upper = codes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if codes[middle] < prefix { lower = middle + 1 } else { upper = middle }
        }
        var end = lower
        while end < codes.count, codes[end].hasPrefix(prefix), end - lower < 160 { end += 1 }
        return codes[lower..<end]
    }
}

struct PinyinComposition {
    private(set) var raw = ""
    mutating func append(_ character: String) {
        guard raw.count < 64, character.utf8.count == 1,
              let code = character.utf8.first else { return }
        if code >= 97 && code <= 122 { raw += character }
        else if character == "'", !raw.isEmpty, !raw.hasSuffix("'") { raw += character }
    }
    /// Returns true when deletion was handled by the pending composition.
    mutating func backspace() -> Bool {
        guard !raw.isEmpty else { return false }
        raw.removeLast(); return true
    }
    mutating func select(_ candidate: PinyinCandidate) -> String? {
        guard candidate.consumed > 0, candidate.consumed <= raw.count else { return nil }
        raw = String(raw.dropFirst(candidate.consumed))
        while raw.hasPrefix("'") { raw.removeFirst() }
        return candidate.text
    }
    mutating func clear() { raw = "" }
}
