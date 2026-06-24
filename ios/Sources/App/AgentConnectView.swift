import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Drives the "connect your computer" flow shown inside a Claude/Codex chat while
/// no paired computer is online. Owns pairing-code requests and status polling so
/// the panel can flip to "connected" the moment the daemon dials in.
@MainActor
final class AgentConnectModel: ObservableObject {
  /// `"claude"` / `"codex"`.
  let provider: String
  /// Display name shown in copy ("Claude" / "Codex").
  let displayName: String

  @Published var status: AgentBridgeStatus = .disconnected
  @Published var ticket: AgentPairingTicket?
  @Published var isRequestingCode = false
  @Published var isShowingCode = false
  @Published var errorMessage: String?

  /// Invoked once a computer comes online so the host can reveal the input bar.
  var onConnected: (() -> Void)?

  private var pollTask: Task<Void, Never>?

  init(provider: String, displayName: String) {
    self.provider = provider
    self.displayName = displayName
  }

  func onAppear() {
    startPolling()
  }

  func onDisappear() {
    stopPolling()
  }

  /// Polls bridge status every couple of seconds while the panel is on screen.
  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshStatusOnce()
        if Task.isCancelled { return }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  func refreshStatusOnce() async {
    guard let config = AppSessionConfig.current else { return }
    do {
      let next = try await AgentPairingService.status(config: config)
      status = next
      if next.connected {
        isShowingCode = false
        stopPolling()
        onConnected?()
      }
    } catch {
      // Transient — keep the last known status and let the next tick retry.
    }
  }

  func requestCode() {
    guard !isRequestingCode else { return }
    guard let config = AppSessionConfig.current else {
      errorMessage = AgentPairingError.noSession.localizedDescription
      return
    }
    isRequestingCode = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer { self.isRequestingCode = false }
      do {
        let ticket = try await AgentPairingService.requestPairing(config: config)
        self.ticket = ticket
        self.isShowingCode = true
        self.startPolling()
      } catch {
        self.errorMessage = error.localizedDescription
      }
    }
  }
}

/// Bottom panel rendered in place of the composer for an unconnected agent chat.
struct AgentConnectPanel: View {
  @ObservedObject var model: AgentConnectModel
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 12) {
        ZStack {
          Circle().fill(palette.accent.opacity(0.16))
          Image(systemName: "laptopcomputer.and.iphone")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(palette.accent)
        }
        .frame(width: 44, height: 44)

        VStack(alignment: .leading, spacing: 3) {
          Text("Connect your computer")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.text)
          Text(
            "\(model.displayName) runs on your own computer with your own subscription. Pair it once to start chatting here."
          )
          .font(.system(size: 13))
          .foregroundStyle(palette.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Image(systemName: "lock.shield")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText)
        Text("Pairing is end-to-end and revocable. Only you can connect a computer.")
          .font(.system(size: 11.5))
          .foregroundStyle(palette.secondaryText)
        Spacer(minLength: 0)
      }

      Button(action: { model.requestCode() }) {
        HStack(spacing: 8) {
          if model.isRequestingCode {
            ProgressView().tint(.white)
          } else {
            Image(systemName: "qrcode")
          }
          Text(model.isRequestingCode ? "Preparing…" : "Connect \(model.displayName)")
            .font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .foregroundStyle(.white)
        .background(palette.accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
      .disabled(model.isRequestingCode)

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(16)
    .background(palette.card)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(palette.secondaryText.opacity(0.12), lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .onAppear { model.onAppear() }
    .onDisappear { model.onDisappear() }
    .sheet(isPresented: $model.isShowingCode) {
      AgentConnectQRSheet(model: model)
    }
  }
}

/// QR + copyable command + live "waiting for your computer" status.
private struct AgentConnectQRSheet: View {
  @ObservedObject var model: AgentConnectModel
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss
  @State private var didCopy = false

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    NavigationView {
      ScrollView {
        VStack(spacing: 20) {
          Text("On the computer you want \(model.displayName) to use, run this in a terminal:")
            .font(.system(size: 14))
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.top, 8)

          if let payload = model.ticket?.qrPayload, let image = AgentQRRenderer.image(for: payload) {
            Image(uiImage: image)
              .interpolation(.none)
              .resizable()
              .scaledToFit()
              .frame(width: 220, height: 220)
              .padding(14)
              .background(Color.white)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          } else {
            ProgressView().frame(width: 220, height: 220)
          }

          if let command = model.ticket?.command {
            VStack(spacing: 10) {
              Text(command)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
                .background(palette.background)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

              Button(action: { copyCommand(command) }) {
                HStack(spacing: 6) {
                  Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                  Text(didCopy ? "Copied" : "Copy command")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.accent)
              }
            }
          }

          statusRow

          VStack(spacing: 6) {
            Label(
              "The code is single-use and expires in ~10 minutes.",
              systemImage: "clock")
            Label(
              "Don't have it installed? `npx` fetches vibe-bridge automatically (Node 18+).",
              systemImage: "shippingbox")
          }
          .font(.system(size: 12))
          .foregroundStyle(palette.secondaryText)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
      }
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("Pair your computer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var statusRow: some View {
    HStack(spacing: 10) {
      if model.status.connected {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text("Computer connected — you're ready to chat.")
          .foregroundStyle(palette.text)
      } else {
        ProgressView().controlSize(.small)
        Text("Waiting for your computer to connect…")
          .foregroundStyle(palette.secondaryText)
      }
      Spacer(minLength: 0)
    }
    .font(.system(size: 14, weight: .medium))
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(palette.card)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private func copyCommand(_ command: String) {
    UIPasteboard.general.string = command
    withAnimation { didCopy = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
      withAnimation { didCopy = false }
    }
  }
}

/// Minimal QR generator (the one in SettingsView is file-private).
enum AgentQRRenderer {
  private static let context = CIContext()

  static func image(for value: String) -> UIImage? {
    guard !value.isEmpty else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
