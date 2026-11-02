import Foundation

/// Namespace-agnostic XML reader. ONVIF cameras vary in prefixes, so elements are matched
/// by local name.
final class XMLNode {
    let name: String
    var attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    func first(_ name: String) -> XMLNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    func all(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for child in children {
            if child.name == name { out.append(child) }
            out.append(contentsOf: child.all(name))
        }
        return out
    }

    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func parse(_ data: Data) -> XMLNode? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        return parser.parse() ? delegate.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = XMLNode(name: "#root")
        private lazy var stack: [XMLNode] = [root]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLNode(name: local, attributes: attributes)
            stack.last?.children.append(node)
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}

extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
