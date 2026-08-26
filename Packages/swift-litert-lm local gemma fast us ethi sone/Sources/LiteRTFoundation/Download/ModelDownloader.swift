// swift-litert-lm — in-app model downloader (single `.litertlm` file)
//
// A LiteRT-LM model is one large `.litertlm` file (~2.6 GB for Gemma 4 E2B), so
// this is a focused single-file downloader built around RANGE-CHUNKED
// PARALLELISM with CROSS-LAUNCH RESUME. The mechanics — and the comments that
// explain *why* each one exists — are ported from a device-tested Hugging Face
// downloader; they encode hard-won iPhone lessons:
//
//   • A POOL of independent URLSessions (one HTTP/2 connection each). A single
//     URLSession multiplexes ALL its tasks onto ONE HTTP/2 connection per host
//     (one congestion/flow window ≈ one stream; `httpMaximumConnectionsPerHost`
//     is ignored under H2), so fanning N chunks over one session caps at ~1
//     stream and collapses (-1005) when overloaded. Each fan-out slot gets its
//     OWN session so aggregate throughput scales with N.
//   • `waitsForConnectivity = false`. On iOS a dead CDN connection drops with
//     -1005 "network connection lost"; with waitsForConnectivity=true the retry
//     then blocks forever "waiting for connectivity" (the request timeout does
//     not run while waiting) → the download hangs silently at 0 bytes.
//   • A per-chunk WALL-CLOCK deadline. `timeoutIntervalForRequest` is only an
//     idle timer that resets on every received byte, so a connection that
//     degrades to a crawl (HF's shared HTTP/2 connection sometimes does this)
//     never trips it and the download wedges. The deadline races the transfer
//     against a hard timeout and re-rolls the HF resolve onto a fresh CDN.
//   • A resume bitmap (one byte per chunk) written AFTER the data is flushed, so
//     bit==1 ⟹ bytes present. A quit/crash costs at most the one in-flight
//     chunk, never the whole file.
//   • A single-flight guard so two overlapping downloads of the same file don't
//     fight over the same byte ranges and knock each other out with -1005.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Downloads a single `.litertlm` model file with chunked parallelism, retries,
/// and cross-launch resume. Safe to call repeatedly: an already-complete file is
/// a no-op, and an interrupted one resumes from where it stopped.
public actor ModelDownloader {

  /// Download progress snapshot.
  public struct Progress: Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public var fraction: Double { totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 1) : 0 }
  }

  public static let shared = ModelDownloader()
  public init() {}

  // Size of the session pool = number of independent TCP connections at once.
  private static let maxConnections = 8
  // Files larger than this are split into byte-range chunks of this size. 16 MiB
  // keeps peak RAM (chunkSize × maxConnections ≈ 128 MB) modest while making the
  // progress bar advance smoothly.
  private static let chunkSize: Int64 = 16 * 1024 * 1024
  private static let maxChunkRetries = 6
  private static let chunkDeadlineSeconds: UInt64 = 30
  private static let redirector = RangePreservingRedirector()

  // Single-flight: destinations currently being downloaded.
  private var activeDestinations: Set<String> = []

  /// Download `url` into `destination` (a file path). Resumes if a prior attempt
  /// left a partial. `expectedBytes`, when known (e.g. from the catalog), avoids
  /// a HEAD round-trip and is used if the server doesn't report a length.
  ///
  /// - Throws: on network failure after retries, HTTP errors, or disk errors.
  public func download(
    from url: URL,
    to destination: URL,
    expectedBytes: Int64? = nil,
    onProgress: (@Sendable (Progress) -> Void)? = nil
  ) async throws {
    let fm = FileManager.default

    // Already placed atomically by a prior run → done.
    if fm.fileExists(atPath: destination.path) { return }

    // Single-flight on this destination.
    let key = destination.standardizedFileURL.path
    if activeDestinations.contains(key) {
      throw Self.err("a download to \(destination.lastPathComponent) is already in progress")
    }
    activeDestinations.insert(key)
    defer { activeDestinations.remove(key) }

    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

    // Resolve the authoritative size: server first, then caller hint.
    let totalBytes = try await Self.resolveSize(of: url) ?? expectedBytes
      ?? { throw Self.err("could not determine size of \(url.lastPathComponent)") }()

    let staging = destination.appendingPathExtension("partial")
    let bitsURL = destination.appendingPathExtension("dl-bits")

    let bg = BackgroundAssertion(name: "litertlm-download")
    defer { bg.end() }

    let cfg = URLSessionConfiguration.default
    cfg.httpMaximumConnectionsPerHost = 1
    cfg.waitsForConnectivity = false
    cfg.timeoutIntervalForRequest = 25
    cfg.timeoutIntervalForResource = 7 * 24 * 60 * 60
    let pool = (0..<max(1, Self.maxConnections)).map { _ in URLSession(configuration: cfg) }
    defer { pool.forEach { $0.invalidateAndCancel() } }

    // Plan chunks, resuming any already-written ones from the bitmap.
    let geo = Self.chunkGeometry(totalBytes)
    var done = [UInt8](repeating: 0, count: geo.count)
    if let saved = try? Data(contentsOf: bitsURL), saved.count == geo.count,
      fm.fileExists(atPath: staging.path) {
      done = [UInt8](saved)
    } else {
      fm.createFile(atPath: staging.path, contents: nil)
      try Data(count: geo.count).write(to: bitsURL)
    }
    Self.excludeFromBackup(staging)

    var completed: Int64 = 0
    var pending: [Segment] = []
    for (i, g) in geo.enumerated() {
      if done[i] != 0 {
        completed += g.length
      } else {
        pending.append(
          Segment(url: url, dest: staging, offset: g.offset, length: g.length,
            ranged: g.ranged, chunkIndex: i, bits: bitsURL))
      }
    }
    onProgress?(Progress(completedBytes: completed, totalBytes: totalBytes))

    // Bounded fan-out: keep `maxConnections` chunks in flight, refilling as each
    // lands. Each slot is pinned to its own pool session (= its own connection);
    // a finished task returns its slot (to reuse the session) and the chunk's
    // length (to advance progress).
    if !pending.isEmpty {
      try await withThrowingTaskGroup(of: (slot: Int, length: Int64).self) { group in
        var iterator = pending.makeIterator()
        var inFlight = 0
        var slot = 0
        for _ in 0..<pool.count {
          guard let seg = iterator.next() else { break }
          let s = slot; slot += 1
          let sess = pool[s]
          group.addTask { try await Self.fetchChunk(seg, via: sess); return (s, seg.length) }
          inFlight += 1
        }
        while inFlight > 0 {
          let (freed, length) = try await group.next()!
          inFlight -= 1
          completed += length
          onProgress?(Progress(completedBytes: completed, totalBytes: totalBytes))
          if let seg = iterator.next() {
            let sess = pool[freed]
            group.addTask { try await Self.fetchChunk(seg, via: sess); return (freed, seg.length) }
            inFlight += 1
          }
        }
      }
    }

    // Atomic placement: the staging file is fully written → move it into place.
    try? fm.removeItem(at: destination)
    try fm.moveItem(at: staging, to: destination)
    try? fm.removeItem(at: bitsURL)
    Self.excludeFromBackup(destination)
  }

  // One byte-range of the file.
  private struct Segment: Sendable {
    let url: URL
    let dest: URL
    let offset: Int64
    let length: Int64
    let ranged: Bool
    let chunkIndex: Int
    let bits: URL
  }

  // HEAD the resolve URL (following the HF→CDN redirect) for an authoritative
  // Content-Length. Returns nil if the server doesn't report one.
  private static func resolveSize(of url: URL) async throws -> Int64? {
    var req = URLRequest(url: url)
    req.httpMethod = "HEAD"
    let (_, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { return nil }
    guard (200..<400).contains(http.statusCode) else {
      throw err("HTTP \(http.statusCode) resolving \(url.lastPathComponent)")
    }
    if let len = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(len), n > 0 {
      return n
    }
    return nil
  }

  // Byte-range geometry for a file (or one whole-file segment if small enough).
  private static func chunkGeometry(_ size: Int64) -> [(offset: Int64, length: Int64, ranged: Bool)] {
    guard size > chunkSize else { return [(0, max(size, 0), false)] }
    var out: [(Int64, Int64, Bool)] = []
    var off: Int64 = 0
    while off < size {
      let len = min(chunkSize, size - off)
      out.append((off, len, true))
      off += len
    }
    return out
  }

  // Fetch one chunk, write it at its offset, then mark its bitmap bit. The data
  // write+close happens BEFORE the bit is set so a crash can never leave bit==1
  // over missing bytes. Retries re-fetch only this chunk.
  private static func fetchChunk(_ seg: Segment, via session: URLSession) async throws {
    var attempt = 0
    while true {
      do {
        var req = URLRequest(url: seg.url)
        if seg.ranged {
          req.setValue(
            "bytes=\(seg.offset)-\(seg.offset + seg.length - 1)", forHTTPHeaderField: "Range")
        }
        let (data, resp) = try await dataWithDeadline(req, via: session, seconds: chunkDeadlineSeconds)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard seg.ranged ? code == 206 : code == 200 else {
          throw err("HTTP \(code) for \(seg.url.lastPathComponent)")
        }
        let fh = try FileHandle(forWritingTo: seg.dest)
        do {
          try fh.seek(toOffset: UInt64(seg.offset))
          try fh.write(contentsOf: data)
          try fh.close()
        } catch { try? fh.close(); throw error }
        let bh = try FileHandle(forWritingTo: seg.bits)
        do {
          try bh.seek(toOffset: UInt64(seg.chunkIndex))
          try bh.write(contentsOf: Data([1]))
          try bh.close()
        } catch { try? bh.close(); throw error }
        return
      } catch {
        if Task.isCancelled { throw error }
        attempt += 1
        if attempt > maxChunkRetries { throw error }
        try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
      }
    }
  }

  // A wall-clock deadline around one GET (redirect + body): races the transfer
  // against a hard timeout and cancels the loser. 30 s for 16 MiB = a 0.5 MB/s
  // floor, far below real Wi-Fi, so only genuinely stuck transfers are cut.
  private static func dataWithDeadline(
    _ req: URLRequest, via session: URLSession, seconds: UInt64
  ) async throws -> (Data, URLResponse) {
    try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
      group.addTask { try await session.data(for: req, delegate: redirector) }
      group.addTask {
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        throw err("chunk stalled > \(seconds)s")
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw err("no chunk result") }
      return first
    }
  }

  private static func excludeFromBackup(_ url: URL) {
    var v = URLResourceValues()
    v.isExcludedFromBackup = true
    var u = url
    try? u.setResourceValues(v)
  }

  private static func err(_ msg: String) -> Error {
    NSError(domain: "LiteRTModelDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
  }
}

// A no-op-on-macOS wrapper around a UIKit finite-length background-task assertion,
// so a quick app-switch mid-download doesn't drop the connection.
private struct BackgroundAssertion {
  #if canImport(UIKit)
  private let id: UIBackgroundTaskIdentifier
  init(name: String) {
    var handle: UIBackgroundTaskIdentifier = .invalid
    handle = UIApplication.shared.beginBackgroundTask(withName: name) {
      if handle != .invalid { UIApplication.shared.endBackgroundTask(handle) }
    }
    id = handle
  }
  func end() { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
  #else
  init(name: String) {}
  func end() {}
  #endif
}

// Carries the `Range` header onto the redirected request. HF `resolve/...`
// 302-redirects to the CDN; if URLSession ever dropped Range across the redirect
// the CDN would send the full file (200) and the chunk would buffer the whole
// file into RAM. This guarantees the redirected GET stays a 206 partial.
private final class RangePreservingRedirector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    var req = request
    if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
      req.setValue(range, forHTTPHeaderField: "Range")
    }
    completionHandler(req)
  }
}
