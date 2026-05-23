import XCTest
@testable import SwiftCloudKit

final class ArrayChunkingTests: XCTestCase {

    func testChunkedExactDivision() {
        let array = [1, 2, 3, 4]
        let chunks = array.chunked(into: 2)
        XCTAssertEqual(chunks, [[1, 2], [3, 4]])
    }

    func testChunkedRemainder() {
        let array = [1, 2, 3, 4, 5]
        let chunks = array.chunked(into: 2)
        XCTAssertEqual(chunks, [[1, 2], [3, 4], [5]])
    }

    func testChunkedEmptyArray() {
        let array = [Int]()
        let chunks = array.chunked(into: 3)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunkedSingleElement() {
        let array = [1]
        let chunks = array.chunked(into: 3)
        XCTAssertEqual(chunks, [[1]])
    }

    func testChunkedSizeLargerThanArray() {
        let array = [1, 2]
        let chunks = array.chunked(into: 10)
        XCTAssertEqual(chunks, [[1, 2]])
    }
}
