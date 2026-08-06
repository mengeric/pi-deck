import AppKit
import Combine
import SwiftUI

// MARK: - Send → transcript fly payload

/// Snapshot of a just-sent composer payload for the fly-into-transcript animation.
///
/// Captured **before** `clearComposerInput()` so the bubble can keep showing text
/// / file chips after the editor is emptied.
struct ComposerSendFlyPayload: Identifiable, Equatable {
    /// Unique id for SwiftUI identity (one flight per send).
    let id: UUID
    /// Trimmed preview of the user text (may be empty when attachment-only).
    let textPreview: String
    /// File / folder basenames to show as chips.
    let fileNames: [String]
    /// Optional first image thumbnail (JPEG/PNG data already on the attachment).
    let imagePreviewData: Data?
    /// Number of additional images beyond the first (shown as +N).
    let extraImageCount: Int
    /// True when this send only enqueued a follow-up (still flies, subtler style).
    let isQueued: Bool

    /// Builds a fly payload from the current composer fields.
    ///
    /// - Parameters:
    ///   - text: Raw composer text (markers OK; used for preview only).
    ///   - images: Attached images.
    ///   - files: Attached files.
    ///   - folders: Attached folders.
    ///   - isQueued: Whether the send enqueued instead of prompting.
    /// - Returns: Payload, or `nil` when there is nothing visual to animate.
    static func make(
        text: String,
        images: [PiAgentImageAttachment],
        files: [PiAgentFileAttachment],
        folders: [PiAgentFolderAttachment],
        isQueued: Bool
    ) -> ComposerSendFlyPayload? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
        let preview: String
        if trimmed.count > 120 {
            preview = String(trimmed.prefix(117)) + "…"
        } else {
            preview = trimmed
        }
        let names = (files.map { $0.url.lastPathComponent } + folders.map { $0.url.lastPathComponent })
            .filter { !$0.isEmpty }
        // Image payloads store base64 in `data` (RPC-ready), not raw bytes.
        let firstImageData = images.first.flatMap { attachment -> Data? in
            guard !attachment.data.isEmpty else { return nil }
            return Data(base64Encoded: attachment.data)
        }
        guard !preview.isEmpty || !names.isEmpty || firstImageData != nil || !images.isEmpty else {
            return nil
        }
        return ComposerSendFlyPayload(
            id: UUID(),
            textPreview: preview,
            fileNames: Array(names.prefix(4)),
            imagePreviewData: firstImageData,
            extraImageCount: max(0, images.count - (firstImageData == nil ? 0 : 1)),
            isQueued: isQueued
        )
    }
}

// MARK: - Overlay

/// Floating chip that flies from the composer toward the transcript column.
///
/// - Parameter payload: Active flight, or `nil` when idle.
/// - Parameter progress: 0 = at composer, 1 = near transcript (fully flown).
struct ComposerSendFlyBubble: View {
    let payload: ComposerSendFlyPayload
    let progress: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let data = payload.imagePreviewData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
            } else if !payload.fileNames.isEmpty {
                Image(systemName: "doc.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppTheme.brandAccent.opacity(0.12))
                    )
            }

            VStack(alignment: .leading, spacing: 3) {
                if !payload.textPreview.isEmpty {
                    Text(payload.textPreview)
                        .font(AppTheme.Font.footnote.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if !payload.fileNames.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(payload.fileNames, id: \.self) { name in
                            Text(name)
                                .font(AppTheme.Font.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.brandAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(AppTheme.brandAccent.opacity(0.12))
                                )
                                .lineLimit(1)
                        }
                        if payload.extraImageCount > 0 {
                            Text("+\(payload.extraImageCount)")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                } else if payload.extraImageCount > 0 {
                    Text(LanguageStore.shared.t("composer.fly.images", payload.extraImageCount + 1))
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                } else if payload.imagePreviewData != nil {
                    Text(LanguageStore.shared.t("composer.fly.image"))
                        .font(AppTheme.Font.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
                if payload.isQueued {
                    Text(LanguageStore.shared.t("composer.fly.queued"))
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardFill)
                .shadow(color: Color.black.opacity(0.18 * Double(1 - progress)), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.hairlineStroke.opacity(0.7), lineWidth: 1)
        )
        // Fly up into the transcript, shrink slightly, fade out near the end.
        .scaleEffect(1.0 - 0.14 * progress, anchor: .bottom)
        .opacity(Double(1.0 - pow(Double(progress), 1.25) * 0.95))
        .offset(y: -260 * progress)
        .offset(x: 12 * progress)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Controller helper

/// Owns one in-flight send animation (payload + progress).
///
/// Call ``launch`` from the send path; the overlay binds to `payload` / `progress`.
@MainActor
final class ComposerSendFlyController: ObservableObject {
    /// Active payload while animating; `nil` when idle.
    @Published private(set) var payload: ComposerSendFlyPayload?
    /// 0…1 flight progress.
    @Published private(set) var progress: CGFloat = 0

    private var clearTask: Task<Void, Never>?

    /// Starts a fly animation for the given payload.
    ///
    /// - Parameters:
    ///   - payload: Content snapshot.
    ///   - reduceMotion: When true, skips motion and returns immediately.
    /// - Throws: Never.
    func launch(_ payload: ComposerSendFlyPayload, reduceMotion: Bool) {
        clearTask?.cancel()
        self.payload = payload
        progress = 0
        guard !reduceMotion else {
            self.payload = nil
            return
        }
        // Two-phase: spring lift, then settle/fade.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            progress = 1
        }
        clearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 480_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                self.payload = nil
                self.progress = 0
            }
        }
    }
}
