import AppKit
import XCTest
@testable import agent_deck

/// Pasteboard image → `PiAgentImageAttachment` coverage for composer Cmd+V / drop.
///
/// Uses a **private** `NSPasteboard` name so tests never touch the user's general
/// clipboard and stay portable across machines.
@MainActor
final class PiAgentComposerImagePasteTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        ComposerImagePasteBridge.resetClaimsForTests()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("pi.deck.tests.image-paste.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard?.clearContents()
        pasteboard = nil
        ComposerImagePasteBridge.resetClaimsForTests()
        super.tearDown()
    }

    // MARK: - Bitmap types

    /// PNG clipboard data becomes a single image attachment.
    func testBitmapImagesFromPNGPasteboard() throws {
        let png = try Self.makePNGData(color: .systemRed, size: NSSize(width: 8, height: 6))
        pasteboard.setData(png, forType: .png)

        let attachments = PiAgentComposerImageLoader.bitmapImagesFromPasteboard(pasteboard)
        XCTAssertEqual(attachments.count, 1, "PNG pasteboard should yield one attachment")
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertFalse(attachment.data.isEmpty)
        XCTAssertGreaterThan(attachment.sizeBytes, 0)
        XCTAssertNotNil(Data(base64Encoded: attachment.data))
    }

    /// JPEG clipboard data (common from browsers / some share sheets) is accepted.
    func testBitmapImagesFromJPEGPasteboard() throws {
        let jpeg = try Self.makeJPEGData(color: .systemBlue, size: NSSize(width: 10, height: 10))
        pasteboard.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))

        let attachments = PiAgentComposerImageLoader.bitmapImagesFromPasteboard(pasteboard)
        XCTAssertEqual(attachments.count, 1, "JPEG pasteboard should yield one attachment")
        let attachment = try XCTUnwrap(attachments.first)
        XCTAssertTrue(
            attachment.mimeType == "image/jpeg" || attachment.mimeType == "image/png",
            "Expected jpeg or re-encoded png, got \(attachment.mimeType)"
        )
        XCTAssertFalse(attachment.data.isEmpty)
    }

    /// TIFF clipboard data (macOS screenshot → clipboard) is converted to PNG attachment.
    func testBitmapImagesFromTIFFPasteboard() throws {
        let png = try Self.makePNGData(color: .systemGreen, size: NSSize(width: 4, height: 4))
        let image = try XCTUnwrap(NSImage(data: png))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        pasteboard.setData(tiff, forType: .tiff)

        let attachments = PiAgentComposerImageLoader.bitmapImagesFromPasteboard(pasteboard)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.mimeType, "image/png")
    }

    /// NSImage object-only pasteboard (no raw PNG/JPEG type) still attaches via object read.
    func testBitmapImagesFromNSImageObjectPasteboard() throws {
        let png = try Self.makePNGData(color: .systemOrange, size: NSSize(width: 5, height: 5))
        let image = try XCTUnwrap(NSImage(data: png))
        // writeObjects publishes NSImage without necessarily setting .png data first.
        XCTAssertTrue(pasteboard.writeObjects([image]))

        let attachments = PiAgentComposerImageLoader.bitmapImagesFromPasteboard(pasteboard)
        XCTAssertEqual(attachments.count, 1, "NSImage-only pasteboard should still attach")
        XCTAssertFalse(attachments.first?.data.isEmpty == true)
    }

    /// Empty pasteboard yields no attachments.
    func testBitmapImagesEmptyPasteboard() {
        XCTAssertTrue(PiAgentComposerImageLoader.bitmapImagesFromPasteboard(pasteboard).isEmpty)
    }

    /// Combined loader includes bitmap when file URLs are absent.
    func testImagesFromPasteboardIncludesBitmapWithoutFileURLs() throws {
        let png = try Self.makePNGData(color: .systemPurple, size: NSSize(width: 6, height: 6))
        pasteboard.setData(png, forType: .png)

        let attachments = PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard)
        XCTAssertEqual(attachments.count, 1)
    }

    // MARK: - File URL image path

    /// Image file on disk via file-url pasteboard type is loaded as an attachment.
    func testImageAttachmentFromFileURLOnPasteboard() throws {
        let png = try Self.makePNGData(color: .systemTeal, size: NSSize(width: 7, height: 7))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-deck-paste-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])

        let fromFile = PiAgentComposerImageLoader.imageAttachment(fromFileURL: url)
        XCTAssertNotNil(fromFile)

        let combined = PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard)
        XCTAssertFalse(combined.isEmpty, "file-url image paste should produce attachments")
    }

    /// Ghost file-url (path does not exist) alone must not be treated as a successful
    /// file attachment source; bitmap path should still work if image bytes exist.
    func testGhostFileURLDoesNotBlockBitmap() throws {
        let png = try Self.makePNGData(color: .systemYellow, size: NSSize(width: 3, height: 3))
        pasteboard.clearContents()
        // Declare both a non-existent file URL and PNG bytes (mirrors some producers).
        let ghost = URL(fileURLWithPath: "/tmp/pi-deck-does-not-exist-\(UUID().uuidString).png")
        pasteboard.writeObjects([ghost as NSURL])
        pasteboard.setData(png, forType: .png)

        let bitmaps = PiAgentComposerImageLoader.bitmapImagesFromPasteboard(pasteboard)
        XCTAssertEqual(bitmaps.count, 1, "bitmap must still load when a ghost file-url is present")

        // Ghost path must not decode as an image file.
        XCTAssertNil(PiAgentComposerImageLoader.imageAttachment(fromFileURL: ghost))
    }

    // MARK: - Coalesce path vs bitmap (double-image regression)

    /// Prefer path-backed images when both path and clipboard bitmaps are present.
    func testCoalescePrefersPathImagesOverClipboard() {
        let path = [
            PiAgentImageAttachment(
                name: "disk.png",
                mimeType: "image/png",
                data: "cGF0aA==",
                sizeBytes: 4,
                fileReference: "/tmp/disk.png"
            )
        ]
        let clip = [
            PiAgentImageAttachment(
                name: "pasted-image.png",
                mimeType: "image/png",
                data: "Y2xpcA==",
                sizeBytes: 4,
                fileReference: "pasted-image.png"
            )
        ]
        let merged = PiAgentComposerImageLoader.coalescePasteboardImages(
            pathImages: path,
            clipboardImages: clip
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.fileReference, "/tmp/disk.png")
    }

    /// Clipboard-only when no path images.
    func testCoalesceFallsBackToClipboardWhenNoPath() {
        let clip = [
            PiAgentImageAttachment(
                name: "pasted-image.png",
                mimeType: "image/png",
                data: "Y2xpcA==",
                sizeBytes: 4,
                fileReference: "pasted-image.png"
            )
        ]
        let merged = PiAgentComposerImageLoader.coalescePasteboardImages(
            pathImages: [],
            clipboardImages: clip
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.fileReference, "pasted-image.png")
    }

    /// Screenshot-style pasteboard: real file-url **and** PNG bytes → exactly one image.
    func testResolvedAttachmentsDoesNotDuplicateFileAndBitmap() throws {
        let png = try Self.makePNGData(color: .systemPink, size: NSSize(width: 12, height: 12))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-deck-shot-\(UUID().uuidString).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setData(png, forType: .png)

        let pathOnly = [try XCTUnwrap(PiAgentComposerImageLoader.imageAttachment(fromFileURL: url))]
        let bitmaps = PiAgentComposerImageLoader.bitmapImagesFromPasteboard(pasteboard)
        XCTAssertEqual(pathOnly.count, 1)
        XCTAssertEqual(bitmaps.count, 1, "bitmap path still sees PNG")

        // Old bug: path + bitmap concatenated → 2. New: coalesce → 1.
        let naiveCount = pathOnly.count + bitmaps.count
        XCTAssertEqual(naiveCount, 2)
        let coalesced = PiAgentComposerImageLoader.coalescePasteboardImages(
            pathImages: pathOnly,
            clipboardImages: bitmaps
        )
        XCTAssertEqual(coalesced.count, 1)

        let resolved = PiAgentComposerImageLoader.resolvedPasteboardAttachments(from: pasteboard)
        XCTAssertEqual(resolved.images.count, 1, "screenshot paste must attach exactly one image")
        XCTAssertTrue(resolved.files.isEmpty)
        XCTAssertTrue(resolved.folders.isEmpty)
        XCTAssertTrue(resolved.hasAttachments)
    }

    /// Ghost file-url + PNG resolves to single bitmap (no crash, no empty attach).
    func testResolvedGhostFileURLUsesBitmapOnly() throws {
        let png = try Self.makePNGData(color: .systemIndigo, size: NSSize(width: 5, height: 5))
        let ghost = URL(fileURLWithPath: "/tmp/pi-deck-ghost-\(UUID().uuidString).png")
        pasteboard.clearContents()
        pasteboard.writeObjects([ghost as NSURL])
        pasteboard.setData(png, forType: .png)

        let resolved = PiAgentComposerImageLoader.resolvedPasteboardAttachments(from: pasteboard)
        XCTAssertEqual(resolved.images.count, 1)
    }

    // MARK: - Paste claim (SwiftUI + AppKit double fire)

    /// Second claim inside the window is rejected (AppKit vs onPasteCommand).
    func testPasteClaimRejectsSecondHandlerInWindow() {
        ComposerImagePasteBridge.resetClaimsForTests()
        let t0: TimeInterval = 1_000
        XCTAssertTrue(ComposerImagePasteBridge.claimPasteHandling(now: t0))
        XCTAssertFalse(ComposerImagePasteBridge.claimPasteHandling(now: t0 + 0.1))
        XCTAssertFalse(ComposerImagePasteBridge.claimPasteHandling(now: t0 + 0.4))
    }

    /// After the claim window, a new paste may attach again.
    func testPasteClaimAllowsAfterWindow() {
        ComposerImagePasteBridge.resetClaimsForTests()
        let t0: TimeInterval = 50
        XCTAssertTrue(ComposerImagePasteBridge.claimPasteHandling(now: t0))
        XCTAssertTrue(
            ComposerImagePasteBridge.claimPasteHandling(
                now: t0 + ComposerImagePasteBridge.claimWindow + 0.01
            )
        )
    }

    // MARK: - process pipeline

    /// Direct `imageAttachment(data:)` processes small PNG without dimension note.
    func testImageAttachmentProcessesSmallPNG() throws {
        let png = try Self.makePNGData(color: .black, size: NSSize(width: 16, height: 16))
        let attachment = try XCTUnwrap(
            PiAgentComposerImageLoader.imageAttachment(
                data: png,
                name: "unit.png",
                mimeType: "image/png",
                fileReference: "unit.png"
            )
        )
        XCTAssertEqual(attachment.name, "unit.png")
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertNil(attachment.dimensionNote)
    }

    // MARK: - Helpers

    /// Renders a solid-color PNG for pasteboard tests.
    ///
    /// - Parameters:
    ///   - color: Fill color.
    ///   - size: Pixel size of the bitmap.
    /// - Returns: PNG encoded data.
    private static func makePNGData(color: NSColor, size: NSSize) throws -> Data {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "PiAgentComposerImagePasteTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create bitmap rep"
            ])
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PiAgentComposerImagePasteTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode PNG"
            ])
        }
        return data
    }

    /// Renders a solid-color JPEG for pasteboard tests.
    ///
    /// - Parameters:
    ///   - color: Fill color.
    ///   - size: Pixel size of the bitmap.
    /// - Returns: JPEG encoded data.
    private static func makeJPEGData(color: NSColor, size: NSSize) throws -> Data {
        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "PiAgentComposerImagePasteTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create bitmap rep"
            ])
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw NSError(domain: "PiAgentComposerImagePasteTests", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode JPEG"
            ])
        }
        return data
    }
}
