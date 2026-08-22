import Foundation

public enum FlatXMLError: Error, Equatable {
    case malformed(String)
}

/// One flat GameStream host response. Parser is lenient: missing fields return `nil`, never throw;
/// only malformed XML throws. Nests max two levels deep (`root → block → field`).
public struct FlatXML: Sendable, Equatable {
    /// The `<root>` element's attributes (e.g. `status_code`, `status_message`).
    public let rootAttributes: [String: String]
    private let fields: [String: String]
    private let blocks: [String: [FlatXML]]

    /// Trimmed text of a scalar child field, or `nil` if absent.
    public func value(_ tag: String) -> String? { fields[tag] }

    /// Scalar child field parsed as `Int`, or `nil` if absent/non-numeric.
    public func int(_ tag: String) -> Int? { fields[tag].flatMap { Int($0) } }

    /// Repeated record blocks named `tag` (e.g., `records("App")`), each a `FlatXML` of its fields.
    public func records(_ tag: String) -> [FlatXML] { blocks[tag] ?? [] }

    /// Root envelope with status code and message, or `nil` if no numeric status code.
    public var rootStatus: (code: Int, message: String?)? {
        guard let code = rootAttributes["status_code"].flatMap({ Int($0) }) else { return nil }
        return (code, rootAttributes["status_message"])
    }

    public init(parsing data: Data) throws {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw FlatXMLError.malformed(parser.parserError?.localizedDescription ?? "XML parse failed")
        }
        self.rootAttributes = delegate.rootAttributes
        self.fields = delegate.fields
        self.blocks = delegate.blocks
    }

    /// Record block (children are scalar fields only).
    fileprivate init(fields: [String: String]) {
        self.rootAttributes = [:]
        self.fields = fields
        self.blocks = [:]
    }
}

/// Collects flat document: depth-2 elements are scalar fields unless they have depth-3 children (then record blocks).
private final class Delegate: NSObject, XMLParserDelegate {
    var rootAttributes: [String: String] = [:]
    var fields: [String: String] = [:]
    var blocks: [String: [FlatXML]] = [:]

    private var stack: [String] = []
    private var buffer = ""
    private var recordFields: [String: String] = [:]
    private var recordHasChildren = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if stack.isEmpty { rootAttributes = attributeDict }   // <root …>
        if stack.count == 2 { recordHasChildren = true }      // a depth-2 element with children → record
        stack.append(elementName)
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stack.count {
        case 3:   // a field inside a record block
            recordFields[elementName] = text
        case 2:   // a child of <root>
            if recordHasChildren {
                blocks[elementName, default: []].append(FlatXML(fields: recordFields))
                recordFields = [:]
                recordHasChildren = false
            } else {
                fields[elementName] = text
            }
        default:  // <root> (depth 1) carries only attributes
            break
        }
        if !stack.isEmpty { stack.removeLast() }
        buffer = ""
    }
}
