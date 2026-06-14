import Foundation
import PinnedFetcher
import MediaDecode

/// Single web page → markdown. HTML is fetched + readability-extracted in-process
/// (EgressGuard-pinned via `PinnedFetcher`); a PDF URL is downloaded (bounded,
/// pinned) and handed to the sandboxed `extract` verb. Never writes — yields one
/// candidate.
public struct URLAdapter: SourceAdapter {
    public let kind: WikiSourceKind = .url
    let fetcher: PinnedFetcher
    let decoder: SandboxedMediaDecoder
    public init(fetcher: PinnedFetcher, decoder: SandboxedMediaDecoder = SandboxedMediaDecoder()) {
        self.fetcher = fetcher; self.decoder = decoder
    }

    public func enumerate(_ req: IngestRequest) -> AsyncThrowingStream<WikiSourceCandidate, any Error> {
        AsyncThrowingStream { cont in
            Task {
                guard let url = URL(string: req.input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    cont.finish(throwing: WikiIngestError.fetchFailed("malformed URL")); return
                }
                switch await fetcher.fetchReadable(url) {
                case .success(let doc):
                    cont.yield(WikiSourceCandidate(
                        sourceURI: url.absoluteString, rawType: req.rawType ?? .articles,
                        title: req.title ?? doc.title, bodyMarkdown: doc.markdown, contentFormat: .html,
                        provenance: CollectionProvenance(adapter: "url", canonicalURL: url.absoluteString),
                        fetched: req.fetchedAt, extractionStatus: "ok"))
                    cont.finish()
                case .failure(.contentTypeRejected), .failure(.notReadable):
                    // Likely a PDF / binary → download (bounded, pinned) + sandboxed extract.
                    switch await fetcher.download(url) {
                    case .failure(let e): cont.finish(throwing: WikiIngestError.fetchFailed("download: \(e)"))
                    case .success(let blob):
                        defer { try? FileManager.default.removeItem(atPath: blob.path) }
                        guard blob.sniffedMIME == "application/pdf" else {
                            cont.finish(throwing: WikiIngestError.unsupported("content-type \(blob.sniffedMIME)")); return
                        }
                        switch await decoder.extract(path: blob.path, kind: .pdf) {
                        case .failure(let e): cont.finish(throwing: WikiIngestError.fetchFailed("pdf extract: \(e)"))
                        case .success(let r):
                            cont.yield(WikiSourceCandidate(
                                sourceURI: url.absoluteString, rawType: req.rawType ?? .papers,
                                title: req.title ?? url.lastPathComponent, bodyMarkdown: r.markdown,
                                contentFormat: .pdf,
                                provenance: CollectionProvenance(adapter: "url", sha: r.sha256, canonicalURL: url.absoluteString),
                                fetched: req.fetchedAt, extractionStatus: r.extractionStatus.rawValue))
                            cont.finish()
                        }
                    }
                case .failure(let e):
                    cont.finish(throwing: WikiIngestError.fetchFailed("\(e)"))
                }
            }
        }
    }
}

/// Local file → markdown. A PDF goes through the sandboxed `extract` verb; a
/// text/markdown file is read directly. Image-only PDFs yield `ocr-needed`.
public struct FileAdapter: SourceAdapter {
    public let kind: WikiSourceKind = .file
    let decoder: SandboxedMediaDecoder
    public init(decoder: SandboxedMediaDecoder = SandboxedMediaDecoder()) { self.decoder = decoder }

    public func enumerate(_ req: IngestRequest) -> AsyncThrowingStream<WikiSourceCandidate, any Error> {
        AsyncThrowingStream { cont in
            Task {
                let path = req.input
                let fm = FileManager.default
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue, fm.isReadableFile(atPath: path) else {
                    cont.finish(throwing: WikiIngestError.unreadable(path)); return
                }
                let lower = path.lowercased()
                let name = (path as NSString).lastPathComponent
                if lower.hasSuffix(".pdf") {
                    switch await decoder.extract(path: path, kind: .pdf) {
                    case .failure(let e): cont.finish(throwing: WikiIngestError.unreadable("pdf extract: \(e)"))
                    case .success(let r):
                        cont.yield(WikiSourceCandidate(
                            sourceURI: "file://" + path, rawType: req.rawType ?? .papers,
                            title: req.title ?? name, bodyMarkdown: r.markdown, contentFormat: .pdf,
                            provenance: CollectionProvenance(adapter: "file", sha: r.sha256),
                            fetched: req.fetchedAt, extractionStatus: r.extractionStatus.rawValue))
                        cont.finish()
                    }
                } else {
                    guard let data = fm.contents(atPath: path) else {
                        cont.finish(throwing: WikiIngestError.unreadable(path)); return
                    }
                    let text = String(decoding: data, as: UTF8.self)
                    let format: ContentFormat = (lower.hasSuffix(".md") || lower.hasSuffix(".markdown")) ? .markdown : .text
                    let rawType: RawType = req.rawType ?? (format == .markdown ? .articles : .notes)
                    cont.yield(WikiSourceCandidate(
                        sourceURI: "file://" + path, rawType: rawType, title: req.title ?? name,
                        bodyMarkdown: text, contentFormat: format,
                        provenance: CollectionProvenance(adapter: "file"),
                        fetched: req.fetchedAt, extractionStatus: "ok"))
                    cont.finish()
                }
            }
        }
    }
}
