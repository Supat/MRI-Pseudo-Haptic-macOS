//
//  ContentView.swift
//
//  Main split-layout window: sidebar with controls on the left, live
//  camera preview + hand overlay + HUD on the right.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
                .background(.ultraThinMaterial)

            Divider()

            previewArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
        .onAppear {
            appState.refreshCameras()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MRI Pseudo Haptic")
                .font(.title2)
                .bold()

            Group {
                Text("Camera").font(.headline)
                Picker("Camera", selection: Binding(
                    get: { appState.selectedCameraID ?? "" },
                    set: { appState.selectedCameraID = $0 }
                )) {
                    ForEach(appState.availableCameras) { cam in
                        Text("\(cam.model) — \(cam.serial)").tag(cam.id)
                    }
                    if appState.availableCameras.isEmpty {
                        Text("No cameras").tag("")
                    }
                }
                .pickerStyle(.menu)
                .disabled(appState.isStreaming)

                HStack {
                    Button("Refresh") { appState.refreshCameras() }
                        .disabled(appState.isStreaming)
                    if appState.isStreaming {
                        Button("Stop") { appState.stopStreaming() }
                    } else {
                        Button("Start") { appState.startStreaming() }
                            .disabled(appState.selectedCameraID == nil)
                    }
                }
            }

            Divider()

            Group {
                Text("TCP Broadcaster").font(.headline)
                HStack {
                    Text("Port")
                    TextField("Port", value: Binding(
                        get: { Int(appState.broadcastPort) },
                        set: { appState.broadcastPort = UInt16(max(1, min(65535, $0))) }
                    ), format: .number)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .disabled(appState.broadcasterStatus.hasPrefix("Listening"))
                }
                HStack {
                    if appState.broadcasterStatus.hasPrefix("Listening") {
                        Button("Stop Server") { appState.stopBroadcaster() }
                    } else {
                        Button("Start Server") { appState.startBroadcaster() }
                    }
                }
                Text(appState.broadcasterStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Clients: \(appState.connectedClients)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("nc 127.0.0.1 \(appState.broadcastPort)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Group {
                Text("Status").font(.headline)
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.lastProcessingLatencyMs > 0 {
                    Text(String(format: "Latency: %.1f ms",
                                appState.lastProcessingLatencyMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            if let processed = appState.latestFrame {
                CameraPreviewView(pixelBuffer: processed.pixelBuffer)
                    .aspectRatio(
                        processed.imageSize.width / max(processed.imageSize.height, 1),
                        contentMode: .fit
                    )
                HandOverlayView(processed: processed)
            } else {
                Text("Waiting for camera frames…")
                    .foregroundStyle(.white.opacity(0.6))
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    StatusHUDView(wrist: appState.wristAngle)
                        .padding(20)
                }
            }
        }
    }
}
