import Foundation

/// Soft hyphens at syllable breaks, so a column a few letters wide breaks "Einführung" as
/// "Einfüh-rung" instead of mid-syllable or not at all. Text shows a hyphen only where it
/// actually wraps.
enum Hyphenation {
    static let softHyphen = "\u{00AD}"

    static func soften(_ text: String, locale: Locale = Locale(identifier: "de_DE")) -> String {
        let cfLocale = locale as CFLocale
        guard CFStringIsHyphenationAvailableForLocale(cfLocale) else { return text }
        let ns = NSMutableString(string: text)
        // Words only: the hyphenator's range must not run into spaces or punctuation.
        var words: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, _ in
            if range.length >= 6 { words.append(range) }
        }
        for word in words.reversed() {
            var breaks: [Int] = []
            var index = word.location + word.length
            while true {
                let at = CFStringGetHyphenationLocationBeforeIndex(
                    ns, index, CFRange(location: word.location, length: word.length), 0, cfLocale, nil)
                // Keep at least two letters on each side of a break.
                guard at != kCFNotFound, at < index, at - word.location >= 2 else { break }
                if word.location + word.length - at >= 2 { breaks.append(at) }
                index = at
            }
            for at in breaks { ns.insert(softHyphen, at: at) }   // already descending
        }
        return ns as String
    }
}
