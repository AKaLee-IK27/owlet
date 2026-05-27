import Foundation

enum OwletVerb: Equatable {
    case rewrite
    case translate
    case grammar
    case unknown(verb: String)
}

enum URLSchemeParser {
    static let scheme = "owlet"

    static func parse(_ url: URL) -> OwletVerb? {
        guard url.scheme == scheme else { return nil }
        guard let verb = url.host, !verb.isEmpty else { return nil }
        switch verb {
        case "rewrite":   return .rewrite
        case "translate": return .translate
        case "grammar":   return .grammar
        default:          return .unknown(verb: verb)
        }
    }
}
