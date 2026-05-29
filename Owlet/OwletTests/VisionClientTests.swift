import XCTest
@testable import Owlet

final class VisionClientTests: XCTestCase {

    func test_buildPayload_hasImagesArray() {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let payload = VisionClient.buildPayload(imageData: imageData, model: "qwen2.5-vl:7b")
        XCTAssertEqual(payload["model"] as? String, "qwen2.5-vl:7b")
        XCTAssertEqual(payload["stream"] as? Bool, false)
        let messages = payload["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        XCTAssertEqual(messages?[1]["role"] as? String, "user")
        let images = messages?[1]["images"] as? [String]
        XCTAssertEqual(images?.count, 1)
        XCTAssertNotNil(images?.first)
    }

    func test_buildPayload_base64EncodesImage() {
        let imageData = Data([0x01, 0x02, 0x03])
        let payload = VisionClient.buildPayload(imageData: imageData, model: "test")
        let messages = payload["messages"] as? [[String: Any]]
        let images = messages?[1]["images"] as? [String]
        XCTAssertEqual(images?.first, imageData.base64EncodedString())
    }

    func test_parseResponse_extractsContent() {
        let json = #"{"message":{"content":"the rewrite"}}"#
        let result = VisionClient.parseResponse(json)
        XCTAssertEqual(result, "the rewrite")
    }

    func test_parseResponse_missingContent_returnsNil() {
        let json = #"{"message":{}}"#
        let result = VisionClient.parseResponse(json)
        XCTAssertNil(result)
    }

    func test_parseResponse_invalidJSON_returnsNil() {
        let result = VisionClient.parseResponse("not json")
        XCTAssertNil(result)
    }
}
