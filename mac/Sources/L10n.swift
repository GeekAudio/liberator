import Foundation

enum L10n {
    static let language = Bundle.main.preferredLocalizations.first ?? "en"

    static let strings: [String: String] = {
        guard language == "zh-Hans" || language == "zh-Hant",
              let url = Bundle.main.url(forResource: "Interface", withExtension: "json",
                                        subdirectory: nil, localization: language),
              let data = try? Data(contentsOf: url),
              let strings = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return strings
    }()

    static func text(_ source: String) -> String { strings[source] ?? source }

    static func format(_ source: String, _ arguments: String...) -> String {
        // Insert each value once so filenames and messages containing a literal %@ stay intact.
        let localized = text(source).components(separatedBy: "%@")
        let parts = localized.count == arguments.count + 1 ? localized : source.components(separatedBy: "%@")
        guard parts.count == arguments.count + 1 else { return source }
        return zip(parts, arguments).map { $0 + $1 }.joined() + parts[arguments.count]
    }

    static func progress(_ line: String) -> String {
        guard !strings.isEmpty, let divider = line.range(of: "%  ") else { return line }
        let detail = line[divider.upperBound...]
        guard let size = detail.range(of: " (") else {
            return line[..<divider.upperBound] + text(String(detail))
        }
        let amount = detail[size.lowerBound...].replacingOccurrences(of: " of ", with: " / ")
        return line[..<divider.upperBound] + text(String(detail[..<size.lowerBound])) + amount
    }
}
