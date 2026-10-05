import SwiftUI

struct RemoteCameraExternalInputSettingsView: View {
    @EnvironmentObject private var input: RemoteCameraExternalInput
    @EnvironmentObject private var camera: RemoteCameraController
    var body: some View {
        List {
            Section {
                Toggle(L10n.tr("rc_external_enable"), isOn: Binding(get: { input.preferences.enabled }, set: input.setEnabled))
                    .accessibilityIdentifier("camera.external.enable")
            } footer: { Text(L10n.tr(camera.showsCamera ? "rc_camera_learning_help" : "rc_external_help")) }
            if input.preferences.enabled {
                if !camera.showsCamera {
                Section(L10n.tr("rc_external_devices")) {
                    if input.devices.isEmpty {
                        Text(L10n.tr("rc_external_no_device")).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(input.devices.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "link")
                        }
                    }
                }
                }
                Section {
                    ForEach(input.preferences.bindings) { binding in
                        Button { input.beginLearning(binding) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(binding.button.displayName).foregroundStyle(.primary)
                                Text(binding.action.title).font(.subheadline).foregroundStyle(.secondary)
                                Text(binding.button.diagnosticCode).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("camera.external.binding.\(binding.id)")
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { input.preferences.bindings[$0].id }
                        ids.forEach(input.remove)
                    }
                    Button { input.beginLearning() } label: {
                        Label(L10n.tr("rc_external_assign"), systemImage: "plus.circle.fill")
                            .frame(minHeight: 44)
                    }.accessibilityIdentifier("camera.external.assign")
                } header: { Text(L10n.tr("rc_external_bindings")) }
                  footer: { if !camera.showsCamera { Text(L10n.tr("rc_external_scope")) } }
            }
        }
        .navigationTitle(L10n.tr("rc_external_title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.camera.external")
        .sheet(isPresented: Binding(get: { input.learning }, set: { if !$0 { input.cancelLearning() } })) {
            RemoteCameraButtonLearningView()
        }
#if DEBUG
        .task {
            if ScreenshotState.requested == .cameraButtonLearning {
                input.setEnabled(true)
                for _ in 0..<100 {
                    if input.available { break }
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                }
                // Wait for the QA-only navigation push before presenting its sheet.
                do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
                input.beginLearning()
                if let code = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-camera-capture=") })?.split(separator: "=").last {
                    camera.handleCaptureButton(String(code))
                }
                if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-external-key=") }),
                   let code = Int(argument.dropFirst("--ui-external-key=".count)) {
                    input.receiveUIKit(code: code, pressed: true)
                    input.receiveUIKit(code: code, pressed: false)
                }
            }
        }
#endif
    }
}

private struct RemoteCameraButtonLearningView: View {
    @EnvironmentObject private var input: RemoteCameraExternalInput
    @EnvironmentObject private var camera: RemoteCameraController
    var body: some View {
        PlatformNavigationContainer {
            List {
                if camera.showsCamera {
                    Section {
                        Text(L10n.tr("rc_camera_learning_help"))
                    }
                }
                Section {
                    // Keep status and progress inside one stable List row. A standalone
                    // conditional ProgressView can leave an empty reused cell after retry.
                    VStack(alignment: .leading, spacing: 12) {
                        if let key = camera.buttonTestError {
                            Label(L10n.tr(key), systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red).accessibilityIdentifier("camera.external.error")
                        } else if camera.buttonTestPreparing {
                            HStack(spacing: 12) {
                                ProgressView().accessibilityHidden(true)
                                Text(L10n.tr("rc_external_preparing"))
                            }.accessibilityIdentifier("camera.buttons.preparing")
                        } else if let button = input.candidate {
                            Label(L10n.tr("rc_external_recognized"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(button.displayName).font(.headline).accessibilityIdentifier("camera.external.detected")
                            Text(button.diagnosticCode).font(.body.monospaced()).textSelection(.enabled)
                                .accessibilityIdentifier("camera.external.code")
                        } else {
                            HStack(spacing: 12) {
                                if input.timedOut {
                                    Image(systemName: "clock").foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityIdentifier("camera.external.listening")
                                }
                                Text(L10n.tr(input.timedOut ? "rc_external_timeout" : "rc_external_press"))
                                    .accessibilityIdentifier("camera.external.listen-status")
                                Spacer(minLength: 0)
                                Text(String(format: "0:%02d", input.learningSecondsRemaining))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .fixedSize().accessibilityIdentifier("camera.external.countdown")
                            }
                        }
                        if input.candidate != nil || input.timedOut || camera.buttonTestError != nil {
                            Button(L10n.tr("rc_external_again"), action: camera.listenForButtonAgain)
                                .buttonStyle(.borderless)
                                .frame(minHeight: 44).accessibilityIdentifier("camera.external.listen-again")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("camera.external.status-row")
                } footer: {
                    Text(L10n.tr(!camera.showsCamera && input.timedOut ? "rc_external_unrecognized" : "rc_external_learning_help"))
                }
                Section {
                    Picker(L10n.tr("rc_external_action"), selection: $input.selectedAction) {
                        ForEach(CameraButtonAction.allCases) { action in Text(action.title).tag(action) }
                    }.accessibilityIdentifier("camera.external.action")
                }
            }
            .navigationTitle(L10n.tr("rc_external_assign"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common_cancel"), action: input.cancelLearning)
                        .accessibilityIdentifier("camera.external.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common_done"), action: input.saveLearning)
                        .disabled(input.candidate == nil)
                        .accessibilityIdentifier("camera.external.save")
                }
            }
            .accessibilityIdentifier("screen.camera.external-learning")
            .background {
                ExternalButtonInputSurface(isLearning: true)
                if #available(iOS 17.2, *), camera.showsCamera {
                    CameraShutterInteraction(enabled: camera.buttonTestReady && input.learning,
                        action: camera.handleCaptureButton)
                }
            }
#if DEBUG
            .onAppear {
                if ScreenshotState.requested == .cameraButtonLearning {
                    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("remote-camera-ui-ready")
                    try? Data("camera.button-learning".utf8).write(to: file, options: .atomic)
                }
            }
#endif
        }
    }
}
