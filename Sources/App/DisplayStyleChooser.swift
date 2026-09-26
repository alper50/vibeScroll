import AppKit
import SwiftUI
import VibeScrollCore

/// Asks, once, where vibeScroll should sit: floating on the desktop or in the
/// notch.
///
/// Only on a Mac with a notch (see `DisplayStyle.shouldAsk`), and only until
/// it is answered. Closing the window without choosing is an answer too — the
/// floating face everyone already knows — so the question is not asked again
/// at every launch.
@MainActor
final class DisplayStyleChooserController: NSObject, NSWindowDelegate {
    static let shared = DisplayStyleChooserController()

    private var window: NSWindow?
    private var onFinish: (() -> Void)?

    func show(then onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
        NSApp.activate(ignoringOtherApps: true)
        if let window { window.makeKeyAndOrderFront(nil); return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Welcome to vibeScroll")
        window.contentView = NSHostingView(rootView: DisplayStyleChooserView { [weak self] style in
            self?.choose(style)
        })
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func choose(_ style: DisplayStyle) {
        DisplayStyleStore.shared.preferred = style
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if DisplayStyleStore.shared.preferred == nil {
            DisplayStyleStore.shared.preferred = .floating
        }
        let finish = onFinish
        onFinish = nil
        window = nil
        finish?()
    }
}

struct DisplayStyleChooserView: View {
    let choose: (DisplayStyle) -> Void
    @State private var selection: DisplayStyle = .notch

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Where should vibeScroll live?")
                    .font(.system(size: 20, weight: .semibold))
                Text("Same sessions, cards and tasks either way. You can change this later in Settings \u{2192} General.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                option(.floating,
                       title: String(localized: "Floating face"),
                       detail: String(localized: "A small face you can drag anywhere. Cards unfold next to it."))
                { FloatingPreview() }
                option(.notch,
                       title: String(localized: "In the notch"),
                       detail: String(localized: "Session quota and running agents beside the camera. Hover to open, click to keep it open."))
                { NotchPreview() }
            }

            Button {
                choose(selection)
            } label: {
                Text("Continue").frame(minWidth: 120)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 600, height: 420)
    }

    private func option<Preview: View>(
        _ style: DisplayStyle, title: String, detail: String,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        let selected = selection == style
        return Button { selection = style } label: {
            VStack(alignment: .leading, spacing: 10) {
                preview()
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 6) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                }
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.06 : 0.02)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                  lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// A wallpaper, a card, and the orb under it.
private struct FloatingPreview: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Wallpaper()
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Color.accentColor.opacity(0.5)).frame(width: 40, height: 5)
                    Capsule().fill(Color.primary.opacity(0.5)).frame(width: 90, height: 6)
                    Capsule().fill(Color.primary.opacity(0.25)).frame(width: 110, height: 4)
                    Capsule().fill(Color.primary.opacity(0.25)).frame(width: 80, height: 4)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
                ZStack {
                    Circle().fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    FaceView(expression: FaceMood.base(for: .working))
                        .padding(8)
                }
                .frame(width: 44, height: 44)
            }
            .padding(12)
        }
    }
}

/// A menu bar with the island in its middle.
private struct NotchPreview: View {
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            Rectangle().fill(.ultraThinMaterial).frame(height: 16)
            NotchShape(topRadius: 3, bottomRadius: 7)
                .fill(Color.black)
                .frame(width: 150, height: 20)
                .overlay {
                    HStack {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.2), lineWidth: 1.5)
                            Circle().trim(from: 0, to: 0.62)
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 12, height: 12)
                        Spacer()
                        HStack(spacing: 3) {
                            Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                            Text(verbatim: "2")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 12)
                }
        }
    }
}

private struct Wallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.36, green: 0.47, blue: 0.72),
                                Color(red: 0.62, green: 0.45, blue: 0.66)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
