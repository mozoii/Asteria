import Foundation
import Testing
@testable import AsteriaCore

@Suite("FlatXML reader")
struct FlatXMLTests {

    @Test func readsScalarFieldsAndInts() throws {
        let xml = try FlatXML(parsing: Data(#"<root status_code="200"><paired>1</paired><name>Asteria</name></root>"#.utf8))
        #expect(xml.value("name") == "Asteria")
        #expect(xml.int("paired") == 1)
        #expect(xml.value("missing") == nil)
        #expect(xml.int("name") == nil)
    }

    @Test func exposesRootStatusEnvelope() throws {
        let xml = try FlatXML(parsing: Data(##"<root status_code="403" status_message="lacks the &quot;Launch&quot; permission"><x>0</x></root>"##.utf8))
        let status = try #require(xml.rootStatus)
        #expect(status.code == 403)
        #expect(status.message == #"lacks the "Launch" permission"#)
    }

    @Test func rootStatusNilWhenNoStatusCode() throws {
        let xml = try FlatXML(parsing: Data("<root><x>1</x></root>".utf8))
        #expect(xml.rootStatus == nil)
    }

    @Test func readsRepeatedRecordBlocks() throws {
        let doc = #"""
        <root status_code="200"><App><AppTitle>Desktop</AppTitle><ID>1</ID></App><App><AppTitle>Tom &amp; Jerry</AppTitle><ID>2</ID></App></root>
        """#
        let xml = try FlatXML(parsing: Data(doc.utf8))
        let apps = xml.records("App")
        #expect(apps.count == 2)
        #expect(apps[0].value("ID") == "1")
        #expect(apps[0].value("AppTitle") == "Desktop")
        #expect(apps[1].value("AppTitle") == "Tom & Jerry")
        #expect(xml.records("None").isEmpty)
    }

    @Test func handlesXmlDeclarationAndWhitespace() throws {
        let doc = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<root status_code=\"200\"><state>  FREE  </state></root>\n"
        let xml = try FlatXML(parsing: Data(doc.utf8))
        #expect(xml.value("state") == "FREE")
        #expect(xml.rootStatus?.code == 200)
    }

    @Test func throwsOnMalformedXML() {
        #expect(throws: FlatXMLError.self) {
            _ = try FlatXML(parsing: Data("<root><hostname>".utf8))
        }
    }
}
