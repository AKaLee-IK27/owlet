import XCTest
@testable import Owlet

final class DiffEngineTests: XCTestCase {

    func test_identical_strings_allUnchanged() {
        let result = DiffEngine.diff("hello world", "hello world")
        XCTAssertEqual(result.segments.map(\.kind), [.unchanged, .unchanged])
        XCTAssertEqual(result.removedRatio, 0.0)
    }

    func test_single_word_substitution() {
        let result = DiffEngine.diff("the cat sat", "the dog sat")
        XCTAssertEqual(result.segments.map(\.text), ["the", "cat", "dog", "sat"])
        XCTAssertEqual(result.segments.map(\.kind), [.unchanged, .removed, .added, .unchanged])
    }

    func test_addition_only() {
        let result = DiffEngine.diff("hello", "hello world")
        XCTAssertEqual(result.segments.map(\.text), ["hello", "world"])
        XCTAssertEqual(result.segments.map(\.kind), [.unchanged, .added])
    }

    func test_removal_only() {
        let result = DiffEngine.diff("hello world", "hello")
        XCTAssertEqual(result.segments.map(\.kind), [.unchanged, .removed])
        XCTAssertEqual(result.removedRatio, 0.5)
    }

    func test_empty_original_allAdded() {
        let result = DiffEngine.diff("", "new text")
        XCTAssertEqual(result.segments.map(\.kind), [.added, .added])
        XCTAssertEqual(result.removedRatio, 0.0)
    }

    func test_empty_rewritten_allRemoved() {
        let result = DiffEngine.diff("old text", "")
        XCTAssertEqual(result.segments.map(\.kind), [.removed, .removed])
        XCTAssertEqual(result.removedRatio, 1.0)
    }

    func test_full_rewrite_highRemovalRatio() {
        let result = DiffEngine.diff("the quick brown fox", "a slow red animal")
        XCTAssertEqual(result.removedRatio, 1.0, accuracy: 0.01)
    }

    func test_shouldCollapse_at70percent() {
        XCTAssertFalse(DiffResult.shouldCollapse(removedRatio: 0.69))
        XCTAssertTrue(DiffResult.shouldCollapse(removedRatio: 0.71))
        XCTAssertTrue(DiffResult.shouldCollapse(removedRatio: 0.70 + .ulpOfOne))
    }
}
