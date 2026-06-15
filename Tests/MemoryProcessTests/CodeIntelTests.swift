import XCTest
@testable import MemoryProcess

/// Severe coverage for the code-intel chunker + edge extractor (gbrain.md Wave 5.30).
final class CodeIntelTests: XCTestCase {
    private let sample = """
    import Foundation
    import MemoryStore

    public struct Widget {
        func render() {
            paint()
            Color.blue.apply()
        }
        func paint() {
            guard ready() else { return }
        }
    }

    enum Helper {
        static func ready() -> Bool { true }
    }
    """

    // MARK: - chunker

    func testFindsTopLevelAndNestedSymbols() {
        let syms = CodeSymbolChunker.symbols(source: sample)
        let names = syms.map(\.qualifiedName)
        XCTAssertTrue(names.contains("Widget"))
        XCTAssertTrue(names.contains("Widget.render"), "nested func gets a qualified name")
        XCTAssertTrue(names.contains("Widget.paint"))
        XCTAssertTrue(names.contains("Helper"))
        XCTAssertTrue(names.contains("Helper.ready"))
    }

    func testSymbolKindsAndSpans() {
        let syms = CodeSymbolChunker.symbols(source: sample)
        let widget = syms.first { $0.qualifiedName == "Widget" }
        XCTAssertEqual(widget?.kind, "struct")
        XCTAssertEqual(widget?.startLine, 4, "struct Widget starts on line 4")
        XCTAssertGreaterThan(widget?.endLine ?? 0, widget?.startLine ?? 0)
        let render = syms.first { $0.qualifiedName == "Widget.render" }
        XCTAssertEqual(render?.kind, "func")
    }

    func testBraceBalanceClosesNestedBeforeParent() {
        let syms = CodeSymbolChunker.symbols(source: sample)
        let widget = syms.first { $0.qualifiedName == "Widget" }!
        let render = syms.first { $0.qualifiedName == "Widget.render" }!
        // render is nested inside widget → its span is within widget's span.
        XCTAssertGreaterThanOrEqual(render.startLine, widget.startLine)
        XCTAssertLessThanOrEqual(render.endLine, widget.endLine)
    }

    func testEmptyAndNonSwift() {
        XCTAssertEqual(CodeSymbolChunker.symbols(source: ""), [])
        XCTAssertEqual(CodeSymbolChunker.symbols(source: "func x(){}", language: .generic), [])
    }

    func testDetectLanguage() {
        XCTAssertEqual(CodeSymbolChunker.detectLanguage(path: "/a/b.swift"), .swift)
        XCTAssertEqual(CodeSymbolChunker.detectLanguage(path: "/a/b.py"), .generic)
    }

    // MARK: - edge extractor

    func testImportsExtracted() {
        let syms = CodeSymbolChunker.symbols(source: sample)
        let edges = CodeEdgeExtractor.edges(source: sample, symbols: syms)
        let imports = edges.filter { $0.relation == "imports" }.map(\.toName)
        XCTAssertTrue(imports.contains("Foundation"))
        XCTAssertTrue(imports.contains("MemoryStore"))
    }

    func testCallEdgesFromBody() {
        let syms = CodeSymbolChunker.symbols(source: sample)
        let edges = CodeEdgeExtractor.edges(source: sample, symbols: syms)
        let calls = edges.filter { $0.relation == "calls" }
        // render() calls paint() and apply()
        XCTAssertTrue(calls.contains { $0.fromSymbol == "Widget.render" && $0.toName == "paint" })
        XCTAssertTrue(calls.contains { $0.fromSymbol == "Widget.render" && $0.toName == "apply" })
        // paint() body calls ready()
        XCTAssertTrue(calls.contains { $0.fromSymbol == "Widget.paint" && $0.toName == "ready" })
    }

    func testCallEdgesExcludeKeywords() {
        let syms = CodeSymbolChunker.symbols(source: sample)
        let edges = CodeEdgeExtractor.edges(source: sample, symbols: syms)
        // `guard ready()` must NOT produce a "guard" call edge.
        XCTAssertFalse(edges.contains { $0.toName == "guard" })
        XCTAssertFalse(edges.contains { $0.toName == "return" })
    }

    func testEdgesAreDeduplicated() {
        let src = """
        func a() {
            b()
            b()
            b()
        }
        """
        let syms = CodeSymbolChunker.symbols(source: src)
        let edges = CodeEdgeExtractor.edges(source: src, symbols: syms)
        XCTAssertEqual(edges.filter { $0.toName == "b" }.count, 1, "repeated calls dedupe to one edge")
    }
}
