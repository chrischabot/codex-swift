import XCTest
@testable import BenchKit

final class BenchKitTests: XCTestCase {

    // MARK: MiniTOML

    func testMiniTOMLParsesTaskShape() {
        let toml = """
        version = "1.0"

        [metadata]
        ext_id = "kh701jywhzgddknqwzsq6npjv98226tq"
        task_id = "superjson-error-stack-serialization"
        original_title = 'Error Stack Serialization Support'  # note: single quotes
        language = "typescript"

        [verifier]
        timeout_sec = 1800.0

        [environment]
        allow_internet = false
        cpus = 2
        memory_mb = 8192
        """
        let t = MiniTOML(string: toml)
        XCTAssertEqual(t.string("version"), "1.0")
        XCTAssertEqual(t.string("metadata.ext_id"), "kh701jywhzgddknqwzsq6npjv98226tq")
        XCTAssertEqual(t.string("metadata.original_title"), "Error Stack Serialization Support")
        XCTAssertEqual(t.string("metadata.language"), "typescript")
        XCTAssertEqual(t.double("verifier.timeout_sec"), 1800.0)
        XCTAssertEqual(t.bool("environment.allow_internet"), false)
        XCTAssertEqual(t.int("environment.cpus"), 2)
        XCTAssertEqual(t.int("environment.memory_mb"), 8192)
    }

    // MARK: Scorer

    func testWilsonInterval() {
        // 1/1 success, 95% Wilson lower bound is the classic ~0.207.
        let (lo, hi) = Scorer.wilson(success: 1, n: 1)
        XCTAssertEqual(lo, 0.2065, accuracy: 0.01)
        XCTAssertEqual(hi, 1.0, accuracy: 0.0001)
        // 0/1
        let (lo0, hi0) = Scorer.wilson(success: 0, n: 1)
        XCTAssertEqual(lo0, 0.0, accuracy: 0.0001)
        XCTAssertEqual(hi0, 0.7935, accuracy: 0.01)
        // 50/100 centers on 0.5
        let (lo5, hi5) = Scorer.wilson(success: 50, n: 100)
        XCTAssertLessThan(lo5, 0.5); XCTAssertGreaterThan(hi5, 0.5)
    }

    func testSummarizePass1AndLanguageSplit() {
        func tr(_ id: String, _ lang: BenchLanguage, reward: Int) -> TaskResult {
            TaskResult(taskId: id, extId: id, language: lang, category: .featureRequest,
                       mode: .agent, status: reward == 1 ? .passed : .failed, reward: reward,
                       verifier: nil, agent: nil, quality: nil, judge: nil, wallTimeSec: 1, error: nil)
        }
        let s = Scorer.summarize([
            tr("a", .go, reward: 1), tr("b", .go, reward: 0), tr("c", .python, reward: 1),
        ])
        XCTAssertEqual(s.n, 3); XCTAssertEqual(s.resolved, 2)
        XCTAssertEqual(s.pass1, 2.0/3.0, accuracy: 1e-9)
        XCTAssertEqual(s.byLanguage["go"]?.pass1, 0.5)
        XCTAssertEqual(s.byLanguage["python"]?.resolved, 1)
    }

    // MARK: PRNG / sampling

    func testSplitMix64Deterministic() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        let seqA = (0..<5).map { _ in a.next() }
        let seqB = (0..<5).map { _ in b.next() }
        XCTAssertEqual(seqA, seqB)
        var c = SplitMix64(seed: 43)
        XCTAssertNotEqual(seqA.first, c.next())
    }

    // MARK: Pricing

    func testPricing() {
        XCTAssertEqual(Pricing.cost(model: "gpt-5.4", inputTokens: 1_000_000, outputTokens: 0), 1.25, accuracy: 1e-9)
        XCTAssertEqual(Pricing.cost(model: "gpt-4o-mini", inputTokens: 0, outputTokens: 1_000_000), 0.60, accuracy: 1e-9)
        XCTAssertEqual(Pricing.cost(model: "unknown-model", inputTokens: 1_000_000, outputTokens: 1_000_000), 0)
    }

    func testLanguageLoose() {
        XCTAssertEqual(BenchLanguage(loose: "TypeScript"), .typescript)
        XCTAssertEqual(BenchLanguage(loose: "ts"), .typescript)
        XCTAssertEqual(BenchLanguage(loose: "golang"), .go)
        XCTAssertNil(BenchLanguage(loose: "cobol"))
    }

    // MARK: Catalog (integration over the vendored data — always present)

    func testCatalogLoadsAll113Tasks() throws {
        guard let root = TaskCatalog.defaultRoot() else {
            throw XCTSkip("Benchmarks/deep-swe not found from cwd")
        }
        let catalog = try TaskCatalog(root: root)
        XCTAssertEqual(catalog.tasks.count, 113)
        // Language distribution from the manifest.
        let counts = Dictionary(grouping: catalog.tasks, by: { $0.language }).mapValues(\.count)
        XCTAssertEqual(counts[.typescript], 35)
        XCTAssertEqual(counts[.go], 34)
        XCTAssertEqual(counts[.python], 34)
        XCTAssertEqual(counts[.javascript], 5)
        XCTAssertEqual(counts[.rust], 5)
        // Spot-check a known task's fields.
        let t = try catalog.task("superjson-error-stack-serialization")
        XCTAssertEqual(t.language, .typescript)
        XCTAssertEqual(t.baseCommitHash, "010c4bdb4b8758844fd44eacf38e42b22eba8aea")
        XCTAssertFalse(t.allowInternet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.testShPath))
    }

    func testRandomSampleReproducibleWithSeed() throws {
        guard let root = TaskCatalog.defaultRoot() else { throw XCTSkip("no catalog") }
        let catalog = try TaskCatalog(root: root)
        let a = catalog.randomSample(3, seed: 7).map(\.id)
        let b = catalog.randomSample(3, seed: 7).map(\.id)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 3)
        let c = catalog.randomSample(3, seed: 8).map(\.id)
        XCTAssertNotEqual(a, c)   // overwhelmingly likely
    }
}
