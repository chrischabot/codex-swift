import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// SPA fallback for the shadcn client router.
///
/// `FileMiddleware` in Hummingbird is a *catch-the-404* middleware: it calls
/// `next` first and only serves a file when downstream throws `.notFound`.
/// This middleware sits OUTSIDE `FileMiddleware`, so when neither a route nor a
/// real file matches, it returns `index.html` for client-side routes (e.g.
/// `/thread/123`). It deliberately rethrows for `/assets/`, `/api/`, `/media/`
/// and `/ws`: a missing hashed chunk must hard-404, never receive the HTML
/// shell (a `text/html` body for a `<script type=module>` request breaks
/// dynamic `import()` with a MIME error).
struct SPAFallbackMiddleware<Context: RequestContext>: RouterMiddleware {
    let indexBytes: [UInt8]

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HTTPError where error.status == .notFound {
            let path = request.uri.path
            guard request.method == .get || request.method == .head,
                  !path.hasPrefix("/assets/"),
                  !path.hasPrefix("/api/"),
                  !path.hasPrefix("/media/"),
                  path != "/ws"
            else { throw error }

            var headers = HTTPFields()
            headers[.contentType] = "text/html; charset=utf-8"
            headers[.cacheControl] = "no-cache"
            let body: ResponseBody = request.method == .head
                ? .init()
                : ResponseBody(byteBuffer: ByteBuffer(bytes: indexBytes))
            return Response(status: .ok, headers: headers, body: body)
        }
    }
}

/// Installs static serving of the compiled shadcn bundle (`www/dist`):
///   - `SPAFallbackMiddleware` (outer) → client-route deep links → index.html
///   - `FileMiddleware` (inner) → real files with content-type, ETag,
///     conditional GET, native `Range`/206, and per-extension cache-control
///     (hashed assets immutable 1y; HTML revalidated).
///
/// Middlewares are added before any routes so they wrap the whole router.
enum StaticFiles {
    static func install(on router: Router<BasicRequestContext>, wwwRoot: String) {
        let indexPath = wwwRoot + "/index.html"
        let indexHTML = (try? String(contentsOfFile: indexPath, encoding: .utf8))
            ?? "<!doctype html><meta charset=utf-8><title>codex</title><div id=root></div>"
        router.add(middleware: SPAFallbackMiddleware(indexBytes: Array(indexHTML.utf8)))

        let cacheControl = CacheControl([
            (.textJavascript, [.public, .maxAge(31_536_000), .immutable]),
            (.textCss, [.public, .maxAge(31_536_000), .immutable]),
            (.textHtml, [.noCache]),
        ])
        router.add(middleware: FileMiddleware(
            wwwRoot,
            cacheControl: cacheControl,
            searchForIndexHtml: true))
    }
}
