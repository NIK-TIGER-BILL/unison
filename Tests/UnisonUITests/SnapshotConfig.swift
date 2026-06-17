// `import Foundation` + `import Testing` triggers the
// `_Testing_Foundation` cross-import overlay, which is missing from
// the Command Line Tools-only `Testing.framework` install — that
// failure shows up as `no such module '_Testing_Foundation'` even
// though both base modules resolve fine. Foundation comes in
// transitively via AppKit/SwiftUI, so we leave it implicit here.

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import Testing

// MARK: - Standard sizes

/// Canonical sizes our screens render at. Each matches the design HTML
/// mock in `design/<name>-final/index.html` and the corresponding
/// `*WindowController` in `UnisonApp`.
public enum SnapSize {
    public static let popover = CGSize(width: 340, height: 420)
    public static let onboarding = CGSize(width: 440, height: 620)
    public static let settings = CGSize(width: 560, height: 1620)
    public static let transcript = CGSize(width: 600, height: 360)
    public static let logo = CGSize(width: 256, height: 256)
}

// MARK: - Recording mode

/// Set `RECORD_SNAPSHOTS=1` to (re)record all snapshots; otherwise
/// existing PNGs are compared against new renders and a missing PNG is
/// silently recorded on first run.
public enum SnapshotRecordMode {
    case missing
    case all

    @MainActor public static var current: Self {
        ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" ? .all : .missing
    }
}

// MARK: - Snapshot helper

/// Renders a SwiftUI view at `size` and compares (or records) the
/// resulting bitmap against `__Snapshots__/<testFile>/<test>.png`.
///
/// The renderer wraps the view in an `NSHostingView` of the requested
/// size, lays it out synchronously, then captures the AppKit hierarchy
/// via `bitmapImageRepForCachingDisplay`. The PNG is stored next to
/// the test source so committed snapshots travel with the repo.
@MainActor
public func snap<V: View>(
    _ view: V,
    size: CGSize,
    named name: String? = nil,
    file: StaticString = #filePath,
    test: String = #function
) {
    let bitmap = renderToPNG(view: view, size: size)
    let url = snapshotURL(file: file, test: test, named: name)
    let mode = SnapshotRecordMode.current

    // A failed render must never become a reference or a silent pass.
    guard !bitmap.isEmpty else {
        Issue.record("Snapshot render produced no image data for \(url.lastPathComponent) — bitmap rep or PNG encode failed.")
        return
    }

    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    switch mode {
    case .all:
        do {
            try bitmap.write(to: url)
            // Record mode is for refreshing references, not for proving
            // anything — fail loudly so a leaked RECORD_SNAPSHOTS=1
            // (especially on CI) can't turn the whole suite green.
            Issue.record("Recorded \(url.lastPathComponent) (RECORD_SNAPSHOTS=1). Re-run without the flag to verify.")
        } catch {
            Issue.record("Failed to record snapshot \(url.lastPathComponent): \(error)")
        }
    case .missing:
        guard fm.fileExists(atPath: url.path), let existing = try? Data(contentsOf: url) else {
            // Auto-recording a missing reference and passing would make
            // every new/renamed test vacuously green (and on CI the
            // recorded file is discarded, so it would assert nothing
            // forever). Record the candidate, but fail the run.
            try? bitmap.write(to: url)
            Issue.record(
                "No reference snapshot for \(url.lastPathComponent) — recorded a new one. Inspect and commit it, then re-run."
            )
            return
        }
        if !imagesMatch(existing, bitmap, perceptualPrecision: 0.96) {
            // Persist the new render alongside the old one for inspection.
            let failURL = url.deletingPathExtension().appendingPathExtension("failed.png")
            try? bitmap.write(to: failURL)
            Issue.record(
                "Snapshot mismatch for \(url.lastPathComponent). New image written to \(failURL.lastPathComponent). Set RECORD_SNAPSHOTS=1 to overwrite."
            )
        }
    }
}

/// Render-only smoke check — no reference comparison.
///
/// Use for surfaces whose offscreen capture is non-deterministic and so
/// cannot carry a stable pixel reference. The transparent floating
/// transcript panel is the case in point: `bitmapImageRepForCachingDisplay`
/// of a `backgroundColor = .clear` window captures the same Liquid-Glass
/// content BIMODALLY across process/compositor state — fully transparent
/// (alpha 0) in one run, composited-onto-opaque-black in another — so no
/// single committed PNG matches every run. The bubble-bearing transcript
/// snapshots happen to be stable enough to keep as pixel references, but
/// the near-empty `transcript_empty` has so little opaque content that the
/// background mode dominates and it flip-flops (green in isolation, red in
/// the full suite, and vice-versa). This still exercises the real value:
/// the view builds, lays out at the requested size, and renders without
/// crashing or producing an empty/degenerate buffer.
@MainActor
public func snapSmoke<V: View>(_ view: V, size: CGSize) {
    let bitmap = renderToPNG(view: view, size: size)
    #expect(!bitmap.isEmpty, "Render produced no image data (\(Int(size.width))×\(Int(size.height)))")
    // Confirm it decodes to the expected dimensions — catches a layout
    // collapse / wrong-size render that an emptiness check alone misses.
    if let src = CGImageSourceCreateWithData(bitmap as CFData, nil),
       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        #expect(img.width == Int(size.width) && img.height == Int(size.height),
                "Render size \(img.width)×\(img.height) != expected \(Int(size.width))×\(Int(size.height))")
    } else {
        Issue.record("Render output is not a decodable image")
    }
}

// MARK: - Rendering

/// Wrap a SwiftUI view in an NSHostingView of the requested size and
/// flush AppKit's layout. Returns a PNG-encoded `Data` blob.
@MainActor
private func renderToPNG<V: View>(view: V, size: CGSize) -> Data {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()

    // Some SwiftUI materials require the view to be in a window to
    // render correctly. Attach to a transparent offscreen NSWindow.
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.contentView = host
    window.displayIfNeeded()

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        return Data()
    }
    host.cacheDisplay(in: host.bounds, to: rep)

    // Pin the output to 1x. `bitmapImageRepForCachingDisplay` renders at
    // the offscreen window's backing scale (inherited from the main
    // screen), but all committed references are 1x — on a Retina-main
    // machine every render would come out 2x and fail the size guard
    // wholesale. On 1x machines this branch is a no-op, so existing
    // references stay bit-identical.
    let wantW = Int(size.width)
    let wantH = Int(size.height)
    if rep.pixelsWide != wantW || rep.pixelsHigh != wantH, let cg = rep.cgImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(
            data: nil, width: wantW, height: wantH, bitsPerComponent: 8,
            bytesPerRow: wantW * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: wantW, height: wantH))
            if let scaled = ctx.makeImage() {
                let scaledRep = NSBitmapImageRep(cgImage: scaled)
                scaledRep.size = size
                return scaledRep.representation(using: .png, properties: [:]) ?? Data()
            }
        }
        return Data()
    }

    guard let png = rep.representation(using: .png, properties: [:]) else {
        return Data()
    }
    return png
}

// MARK: - Comparison

/// Pixel-level diff with a per-pixel tolerance. Returns `true` when
/// the two PNG blobs are within `perceptualPrecision` (1.0 = identical).
private func imagesMatch(
    _ a: Data,
    _ b: Data,
    perceptualPrecision: Double
) -> Bool {
    guard
        let srcA = CGImageSourceCreateWithData(a as CFData, nil),
        let srcB = CGImageSourceCreateWithData(b as CFData, nil),
        let imgA = CGImageSourceCreateImageAtIndex(srcA, 0, nil),
        let imgB = CGImageSourceCreateImageAtIndex(srcB, 0, nil),
        imgA.width == imgB.width,
        imgA.height == imgB.height
    else {
        return false
    }
    let width = imgA.width
    let height = imgA.height
    let bytesPerRow = width * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
    var bufA = [UInt8](repeating: 0, count: width * height * 4)
    var bufB = [UInt8](repeating: 0, count: width * height * 4)

    guard
        let ctxA = CGContext(
            data: &bufA, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
        ),
        let ctxB = CGContext(
            data: &bufB, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
        )
    else { return false }

    ctxA.draw(imgA, in: CGRect(x: 0, y: 0, width: width, height: height))
    ctxB.draw(imgB, in: CGRect(x: 0, y: 0, width: width, height: height))

    let total = bufA.count
    var mismatched = 0
    let threshold = 20 // per-channel byte tolerance for "close enough"
    var i = 0
    while i < total {
        let dr = abs(Int(bufA[i])     - Int(bufB[i]))
        let dg = abs(Int(bufA[i + 1]) - Int(bufB[i + 1]))
        let db = abs(Int(bufA[i + 2]) - Int(bufB[i + 2]))
        let da = abs(Int(bufA[i + 3]) - Int(bufB[i + 3]))
        if dr > threshold || dg > threshold || db > threshold || da > threshold {
            mismatched += 1
        }
        i += 4
    }
    let totalPixels = total / 4
    let matchRatio = 1.0 - Double(mismatched) / Double(totalPixels)
    return matchRatio >= perceptualPrecision
}

// MARK: - Paths

/// Stable filename derived from the calling test. Strips the trailing
/// `()` Swift Testing appends to `#function`.
private func snapshotURL(file: StaticString, test: String, named: String?) -> URL {
    let testFile = URL(fileURLWithPath: String(describing: file))
    let testFileBase = testFile.deletingPathExtension().lastPathComponent
    let snapDir = testFile
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__")
        .appendingPathComponent(testFileBase)

    var name = test
        .replacingOccurrences(of: "()", with: "")
        .replacingOccurrences(of: "(", with: "_")
        .replacingOccurrences(of: ")", with: "")
        .replacingOccurrences(of: ":", with: "_")
        .replacingOccurrences(of: " ", with: "_")
    if let extra = named {
        name += "." + extra
    }
    name += ".png"
    return snapDir.appendingPathComponent(name)
}
