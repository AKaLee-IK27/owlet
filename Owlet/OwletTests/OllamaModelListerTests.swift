import XCTest
@testable import Owlet

final class OllamaModelListerTests: XCTestCase {

    func test_parses_standard_output() {
        let raw = """
        NAME              ID              SIZE      MODIFIED
        qwen3:8b          abc123          4.7 GB    2 days ago
        llama3.1:8b       def456          4.7 GB    1 week ago
        mistral:7b        ghi789          4.1 GB    3 weeks ago
        """
        XCTAssertEqual(
            OllamaModelLister.parse(raw),
            ["qwen3:8b", "llama3.1:8b", "mistral:7b"]
        )
    }

    func test_parses_single_model() {
        let raw = """
        NAME      ID      SIZE    MODIFIED
        qwen3:8b  abc     4.7 GB  2 days ago
        """
        XCTAssertEqual(OllamaModelLister.parse(raw), ["qwen3:8b"])
    }

    func test_header_only_returns_empty() {
        let raw = "NAME    ID    SIZE    MODIFIED\n"
        XCTAssertEqual(OllamaModelLister.parse(raw), [])
    }

    func test_completely_empty_returns_empty() {
        XCTAssertEqual(OllamaModelLister.parse(""), [])
    }

    func test_blank_lines_are_skipped() {
        let raw = """
        NAME      ID      SIZE    MODIFIED
        qwen3:8b  abc     4.7 GB  2 days ago

        llama3.1:8b  def  4.7 GB  1 week ago
        """
        XCTAssertEqual(OllamaModelLister.parse(raw), ["qwen3:8b", "llama3.1:8b"])
    }
}
