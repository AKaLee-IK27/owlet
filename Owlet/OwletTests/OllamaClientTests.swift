import XCTest
@testable import Owlet

final class OllamaClientTests: XCTestCase {

    private var fixtureURL: URL {
        Bundle(for: type(of: self))
            .url(forResource: "fake-rewriter", withExtension: "sh")!
    }

    func test_happyPath_returnsStdout() async throws {
        let client = OllamaClient(executablePath: fixtureURL.path, timeoutSeconds: 5)
        let result = try await client.rewrite("hello world")
        XCTAssertEqual(result, "HELLO WORLD")
    }

    func test_emptyOutput_throwsEmptyOutputError() async {
        let client = OllamaClient(
            executablePath: fixtureURL.path,
            environment: ["FAKE_MODE": "empty"],
            timeoutSeconds: 5
        )
        do {
            _ = try await client.rewrite("anything")
            XCTFail("expected throw")
        } catch OllamaClient.Failure.emptyOutput { /* ok */ }
        catch { XCTFail("wrong error: \(error)") }
    }

    func test_timeout_terminatesChildAndThrows() async {
        let client = OllamaClient(
            executablePath: fixtureURL.path,
            environment: ["FAKE_MODE": "slow"],
            timeoutSeconds: 1                       // ← way below the 5 s sleep
        )
        let started = Date()
        do {
            _ = try await client.rewrite("anything")
            XCTFail("expected timeout")
        } catch OllamaClient.Failure.timeout { /* ok */ }
        catch { XCTFail("wrong error: \(error)") }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3, "client should have killed the slow child quickly")
    }

    func test_nonZeroExit_surfacesStderr() async {
        let client = OllamaClient(
            executablePath: fixtureURL.path,
            environment: ["FAKE_MODE": "fail"],
            timeoutSeconds: 5
        )
        do {
            _ = try await client.rewrite("anything")
            XCTFail("expected throw")
        } catch OllamaClient.Failure.backendError(let stderr) {
            XCTAssertTrue(stderr.contains("fake failure"), "got: \(stderr)")
        } catch { XCTFail("wrong error: \(error)") }
    }
}
