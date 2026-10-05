import AVKit
import SwiftUI

struct RemoteCameraSettingsView: View {
    @EnvironmentObject private var camera: RemoteCameraController
    @State private var forgetConfirmation = false
    @State private var showingExternalButtons = false
    // An explicit horizontal label avoids the native form Picker moving its
    // selection below longer localized labels on compact phones.
    private func accessoryRow(_ role: RemoteCameraRole, editable: Bool) -> some View {
        HStack(spacing: 8) {
            Text(L10n.tr("rc_accessory_device"))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(L10n.tr(role == .camera ? "rc_role_camera" : "rc_role_remote"))
                .foregroundStyle(editable ? Color.accentColor : Color.secondary)
            if editable {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func soundRow(_ cue: RemoteCameraSoundCue, key: String, enabled: Binding<Bool>, volume: Binding<Double>) -> some View {
        VStack(spacing: 4) {
        HStack(spacing: 12) {
            Toggle(L10n.tr(key), isOn: enabled)
                .accessibilityIdentifier(cue == .start ? "camera.sound.start" : "camera.sound.stop")
            Button { camera.previewSound(cue) } label: {
                Image(systemName: "speaker.wave.2.fill").frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.tr("rc_sound_test") + ": " + L10n.tr(key))
            .accessibilityIdentifier(cue == .start ? "camera.sound.test.start" : "camera.sound.test.stop")
        }
        HStack(spacing: 12) {
            Slider(value: Binding(get: { volume.wrappedValue }, set: {
                volume.wrappedValue = ($0 * 100).rounded() / 100
            }), in: 0...1) { Text(L10n.tr(key)) }
                .accessibilityIdentifier(cue == .start ? "camera.sound.volume.start" : "camera.sound.volume.stop")
            Text(volume.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 44, alignment: .trailing)
                .accessibilityIdentifier(cue == .start ? "camera.sound.level.start" : "camera.sound.level.stop")
        }.frame(minHeight: 44)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle(L10n.tr("rc_enable"), isOn: $camera.enabled)
                    .accessibilityIdentifier("camera.enable")
                if camera.enabled {
                    Picker(L10n.tr("rc_role"), selection: $camera.role) {
                        Text(L10n.tr("rc_role_camera")).tag(RemoteCameraRole.camera)
                        Text(L10n.tr("rc_role_remote")).tag(RemoteCameraRole.remote)
                    }.accessibilityIdentifier("camera.role")
                }
            } footer: { Text(L10n.tr("rc_roles_help")) }
            .disabled(camera.configurationLocked)
            if camera.enabled {
                if camera.role == .camera {
                    Section {
                        Menu {
                            Picker(L10n.tr("rc_accessory_device"), selection: $camera.accessoryDevice) {
                                Text(L10n.tr("rc_role_camera")).tag(RemoteCameraRole.camera)
                                Text(L10n.tr("rc_role_remote")).tag(RemoteCameraRole.remote)
                            }
                        } label: {
                            accessoryRow(camera.accessoryDevice, editable: true)
                        }
                        .accessibilityIdentifier("camera.accessory.device")
                    } footer: { Text(L10n.tr(camera.readinessHelp)) }
                    .disabled(camera.configurationLocked)
                } else {
                    Section {
                        accessoryRow(camera.status.accessoryDevice ?? .remote, editable: false)
                    }
                }
                Section {
                        Button { showingExternalButtons = true } label: {
                            Label(L10n.tr("rc_external_title"), systemImage: "keyboard")
                        }.accessibilityIdentifier("camera.external.settings")
                            .disabled(camera.configurationLocked || (camera.showsCamera && camera.accessoryDevice != .camera))
                }
                Section {
                    RemoteCameraConnectionView()
                }
                Section {
                    soundRow(.start, key: "rc_sound_start", enabled: $camera.soundPreferences.start, volume: $camera.soundPreferences.startVolume)
                    soundRow(.stop, key: "rc_sound_stop", enabled: $camera.soundPreferences.stop, volume: $camera.soundPreferences.stopVolume)
                } header: { Text(L10n.tr("rc_sounds")) }
                  footer: { Text(L10n.tr("rc_sounds_help") + "\n\n" + L10n.format("rc_sound_volume_help", "0%")) }
                if camera.role == .camera {
                    Section {
                        RemoteCameraConfigurationFields()
                    } header: { Text(L10n.tr("rc_quality")) }
                      footer: { Text(L10n.tr("rc_quality_help")) }
                    .disabled(camera.configurationLocked)
                }
                Section {
                    Text(L10n.tr(camera.readinessHelp))
                    Text(L10n.tr("rc_exit_help"))
                    Text(L10n.tr("rc_background_help"))
                }.font(.footnote).foregroundStyle(.secondary)
            }
            if camera.trusted {
                Section {
                    Button(L10n.tr("rc_forget"), role: .destructive) { forgetConfirmation = true }
                        .disabled(camera.configurationLocked)
                        .accessibilityIdentifier("camera.forget")
                }
            }
        }
        .background {
            // Keep modern navigation outside the lazy List. Nested legacy
            // isActive links can select the iPad row without pushing its page.
            if #available(iOS 16.0, *) {
                Color.clear.navigationDestination(isPresented: $showingExternalButtons) {
                    RemoteCameraExternalInputSettingsView()
                }
            } else {
                NavigationLink(destination: RemoteCameraExternalInputSettingsView(),
                               isActive: $showingExternalButtons, label: EmptyView.init)
            }
        }
        .navigationTitle(L10n.tr("rc_title"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen.camera.settings")
        .overlay {
            if forgetConfirmation {
                DecisionConfirmationModal(title: L10n.tr("rc_forget"), message: L10n.tr("rc_forget_help"),
                    confirmLabel: L10n.tr("rc_forget"), confirmRole: .destructive, systemName: "link",
                    accessibilityName: "camera.forget.confirmation", onCancel: { forgetConfirmation = false },
                    onConfirm: { camera.forgetPair(); forgetConfirmation = false })
            }
        }
        .overlay { RemoteCameraPairingOverlay() }
#if DEBUG
        .onAppear {
            if ScreenshotState.requested == .settingsCameraButtons || ScreenshotState.requested == .cameraButtonLearning {
                showingExternalButtons = true
            }
        }
#endif
    }
}

struct RemoteCameraConfigurationFields: View {
    @EnvironmentObject private var camera: RemoteCameraController
    var body: some View {
        Picker(L10n.tr("rc_lens"), selection: $camera.settings.lens) {
            ForEach(camera.availableLenses, id: \.self) { lens in
                Text(RemoteCameraSettings.lensTitle(lens, zoom: camera.lensZoomFactors[lens])).tag(lens)
            }
            if !camera.availableLenses.contains(camera.settings.lens) {
                Text(RemoteCameraSettings.lensTitle(camera.settings.lens)).tag(camera.settings.lens).disabled(true)
            }
        }
        Picker(L10n.tr("rc_resolution"), selection: $camera.settings.resolution) {
            Text("4K").tag(2160)
            Text("1080p").tag(1080)
        }.accessibilityIdentifier("camera.resolution")
        Picker(L10n.tr("rc_fps"), selection: $camera.settings.fps) {
            ForEach([24, 30, 60], id: \.self) { Text("\($0)").tag($0) }
        }.accessibilityIdentifier("camera.fps")
        Toggle("HDR", isOn: Binding(get: { camera.settings.hdr }, set: camera.setHDR))
            .disabled(!camera.supportsHDR && !camera.settings.hdr)
            .accessibilityIdentifier("camera.hdr")
        Text(L10n.tr(camera.supportsHDR ? "rc_hdr_help" : "rc_hdr_unavailable"))
            .font(.footnote).foregroundStyle(.secondary)
        Toggle(L10n.tr("rc_stabilization"), isOn: $camera.settings.stabilization)
            .accessibilityIdentifier("camera.stabilization")
        Menu {
            Picker(L10n.tr("rc_orientation"), selection: $camera.settings.orientation) {
                Text(L10n.tr("rc_landscape_right")).tag("landscapeRight")
                Text(L10n.tr("rc_landscape_left")).tag("landscapeLeft")
                Text(L10n.tr("rc_portrait")).tag("portrait")
            }
        } label: {
            HStack(spacing: 8) {
                Text(L10n.tr("rc_orientation")).foregroundStyle(Color.primary).accessibilityIdentifier("camera.orientation.title")
                Spacer(minLength: 0)
                Text(L10n.tr(camera.settings.orientation == "portrait" ? "rc_portrait" : "rc_landscape")).accessibilityIdentifier("camera.orientation.value")
                if camera.settings.orientation != "portrait" {
                    Image(systemName: camera.settings.orientation == "landscapeLeft" ? "arrow.left" : "arrow.right")
                        .environment(\.layoutDirection, .leftToRight)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
            }.lineLimit(1).minimumScaleFactor(0.85).frame(minHeight: 44)
        }.accessibilityIdentifier("camera.orientation")
        Toggle(L10n.tr("rc_audio"), isOn: $camera.settings.audio)
        Picker(L10n.tr("rc_codec"), selection: $camera.settings.codec) {
            Text("HEVC").tag("hevc")
            Text("H.264").tag("h264")
        }.disabled(camera.settings.hdr)
    }
}

struct RemoteCameraConnectionView: View {
    @EnvironmentObject private var camera: RemoteCameraController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if camera.connectionProgress.isBusy {
                    ProgressView().accessibilityIdentifier("camera.connection.progress")
                } else {
                    Image(systemName: camera.connected ? "link" : "antenna.radiowaves.left.and.right")
                }
                Text(L10n.tr(camera.connectionProgress.titleKey(role: camera.role, trusted: camera.trusted)))
                    .accessibilityIdentifier("camera.connection.status")
                    .accessibilityValue(camera.connectionProgress.rawValue)
            }
            .font(.headline)
            .foregroundStyle(camera.connected ? Color.green : Color.primary)
            if !camera.connected {
                Text(L10n.tr("rc_connection_help")).font(.footnote).foregroundStyle(.secondary)
                if camera.connectionProgress.isBusy {
                    CapsuleActionButton(action: camera.cancelConnection, role: .neutral) {
                        Text(L10n.tr("common_cancel"))
                    }.accessibilityIdentifier("camera.connection.cancel")
                } else {
                    CapsuleActionButton(action: camera.connect, role: .primary) {
                        Label(L10n.tr("rc_connect"), systemImage: "link")
                    }.accessibilityIdentifier("camera.connect")
                }
            }
            if let error = camera.linkError {
                Text(L10n.tr(error)).font(.footnote).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RemoteCameraTabView: View {
    @EnvironmentObject private var camera: RemoteCameraController
    @Environment(\.colorScheme) private var scheme
    @State private var showConfiguration = false
    @State private var selectedClip: RemoteCameraClip?
    @State private var shareURL: CameraShareItem?
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "video.fill").font(.title2).foregroundStyle(AppPalette.brandAccent)
                        Text(L10n.tr("rc_role_camera")).font(AppTypography.screenTitle)
                        Spacer()
                    }
                    Text(L10n.tr(camera.readinessHelp)).font(.subheadline).foregroundStyle(.secondary)
                    RemoteCameraConnectionView()
                }.cameraCard(scheme)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(camera.settings.summary).font(.headline)
                            Text(L10n.tr(camera.settings.stabilization ? "rc_stabilization_on" : "rc_stabilization_off"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { showConfiguration = true } label: {
                            Image(systemName: "slider.horizontal.3").frame(width: 48, height: 48)
                        }.accessibilityLabel(L10n.tr("rc_quality"))
                            .accessibilityIdentifier("camera.configuration")
                            .disabled(camera.configurationLocked)
                    }
                    if let error = camera.status.errorKey {
                        Text(L10n.tr(error)).font(.footnote).foregroundStyle(.red)
                    }
                    CapsuleActionButton(action: camera.arm, role: .primary, isEnabled: camera.connected && !camera.configurationLocked) {
                        if camera.preparing { ProgressView() }
                        else { Label(L10n.tr("rc_enter_eco"), systemImage: "moon.fill") }
                    }
                    .disabled(!camera.connected || camera.configurationLocked)
                    .accessibilityIdentifier("camera.enter-black")
                    Text(L10n.tr("rc_exit_help")).font(.footnote).foregroundStyle(.secondary)
                }.cameraCard(scheme)
                Text(L10n.tr("rc_background_help")).font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("rc_recordings")).font(.headline).id("camera.recordings")
                    Text(L10n.tr("rc_storage_help")).font(.footnote).foregroundStyle(.secondary)
                    if camera.recoveryFailed {
                        Text(L10n.tr("rc_recovery_help")).foregroundStyle(.red).font(.footnote)
                        Button(L10n.tr("rc_recovery_files")) { shareURL = CameraShareItem(url: RemoteCameraCapture.pendingDirectory) }
                    }
                    if camera.clips.isEmpty {
                        Text(L10n.tr("rc_no_recordings")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(camera.clips) { clip in
                        VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button { selectedClip = clip } label: {
                                Label(clip.date.formatted(date: .abbreviated, time: .shortened), systemImage: "play.circle")
                                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            }
                            Button { shareURL = CameraShareItem(url: clip.url) } label: {
                                Image(systemName: "square.and.arrow.up").frame(width: 48, height: 48)
                            }.accessibilityLabel(L10n.tr("rc_share"))
                        }
                            let photoState = camera.photos.state(for: clip.url)
                            HStack(alignment: .top, spacing: 8) {
                                if photoState == .saving || photoState == .waiting { ProgressView() }
                                else { Image(systemName: photoState == .saved ? "checkmark.circle.fill" : "photo") }
                                Text(L10n.tr(photoState.titleKey)).font(.footnote)
                                    .accessibilityIdentifier("camera.photos.status")
                            }.foregroundStyle(photoState == .saved ? Color.green : Color.secondary)
                            if photoState.canSave {
                                Button { camera.saveToPhotos(clip) } label: {
                                    Label(L10n.tr("rc_photos_save"), systemImage: "square.and.arrow.down")
                                        .frame(minHeight: 44)
                                }.accessibilityIdentifier("camera.photos.save")
                            }
                            if photoState == .denied {
                                Button(L10n.tr("rc_photos_settings")) {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                                }.frame(minHeight: 44).accessibilityIdentifier("camera.photos.settings")
                            }
                        }

                    }
                }.cameraCard(scheme)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("screen.camera")
        .onAppear {
            camera.reloadClips()
#if DEBUG
            if ScreenshotState.requested == .cameraPhotos {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo("camera.recordings", anchor: .top) }
            }
#endif
        }
        .sheet(isPresented: $showConfiguration) {
            PlatformNavigationContainer {
                Form { RemoteCameraConfigurationFields() }
                    .navigationTitle(L10n.tr("rc_quality"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("common_done")) { showConfiguration = false } } }
#if DEBUG
                    .task {
                        guard ProcessInfo.processInfo.arguments.contains("--ui-camera-configuration") else { return }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("remote-camera-ui-ready")
                        try? Data("camera.configuration".utf8).write(to: ready, options: .atomic)
                    }
#endif
            }
        }
        .sheet(item: $selectedClip) { clip in
            PlatformNavigationContainer {
                VideoPlayer(player: AVPlayer(url: clip.url))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("common_done")) { selectedClip = nil } } }
            }
        }
        .sheet(item: $shareURL) { CameraShareSheet(url: $0.url) }
        .overlay { RemoteCameraPairingOverlay() }
#if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--ui-camera-configuration") { showConfiguration = true }
        }
#endif
        }
    }
}

struct RemoteCameraMapControls: View {
    @EnvironmentObject private var camera: RemoteCameraController
    var showsCapture = true
    var showsInformation = false
    @State private var showConnection = false
    private var showsStop: Bool { camera.visiblePhase == .recording || camera.visiblePhase == .saving }
    private var busy: Bool { camera.commandPending || camera.visiblePhase == .starting || camera.visiblePhase == .saving }
    private var actionEnabled: Bool { showsStop ? camera.canStop : camera.canStart }
    private var statusText: String { camera.commandPending ? L10n.tr("rc_awaiting") : camera.visiblePhase.title + (camera.controlLockSeconds > 0 ? " · " + camera.controlLockText : "") }
    private var needsAttention: Bool {
        !camera.isFresh || camera.status.errorKey != nil || camera.linkError != nil
            || camera.status.thermalWarning || (camera.status.battery >= 0 && camera.status.battery <= 10)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in controls }
    }
    private var controls: some View {
        VStack(spacing: 8) {
            if showsCapture {
            Button { camera.send(showsStop ? .stop : .start) } label: {
                ZStack {
                    Circle().fill(Color.white.opacity(0.55))
                    Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                    if busy {
                        ProgressView().tint(.black).scaleEffect(1.35)
                    } else if camera.controlLockSeconds > 0 {
                        Text(camera.controlLockText).font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.black)
                            .accessibilityIdentifier("camera.remote.cooldown")
                    } else if showsStop {
                        RoundedRectangle(cornerRadius: 4).fill(Color.black).frame(width: 27.6, height: 27.6)
                    } else {
                        Circle().fill(Color.red).frame(width: 33.6, height: 33.6)
                    }
                }
                .frame(width: 67.2, height: 67.2)
                .opacity(actionEnabled || busy || camera.controlLockSeconds > 0 ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!actionEnabled)
            .accessibilityLabel(L10n.tr(showsStop ? "rc_stop" : "rc_start"))
            .accessibilityValue(statusText)
            .accessibilityIdentifier(showsStop ? "camera.remote.stop" : "camera.remote.start")

            }
            if showsInformation {
            Button { showConnection = true } label: {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if camera.connectionProgress.isBusy { ProgressView() }
                        else { Image(systemName: "info").font(.system(size: 18, weight: .semibold)) }
                    }
                    .frame(width: 44, height: 44)
                    .background { Circle().fill(.ultraThinMaterial).opacity(0.65) }
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                    if needsAttention {
                        Circle().fill(Color.orange).frame(width: 8, height: 8).padding(3)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("rc_camera_info"))
            .accessibilityValue(camera.connectionProgress.isBusy ? L10n.tr(camera.role == .remote ? "rc_search_camera" : "rc_wait_remote") : statusText)
            .accessibilityIdentifier("camera.remote.connect")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(showsCapture ? "camera.remote.controls" : "camera.remote.info-controls")
        .background { if showsCapture { ExternalButtonInputSurface() } }
#if DEBUG
        .task {
            if showsInformation && (ScreenshotState.requested == .mapCameraSearching || ScreenshotState.requested == .mapCameraInfo) {
                try? await Task.sleep(nanoseconds: 600_000_000)
                showConnection = true
            }
        }
#endif
        .sheet(isPresented: $showConnection) {
            PlatformNavigationContainer {
                List {
                    Section {
                        Text(camera.visiblePhase.title).font(.headline)
                            .accessibilityIdentifier("camera.remote.state")
                        if camera.commandPending {
                            HStack { ProgressView(); Text(L10n.tr("rc_awaiting")) }
                        }
                        if camera.isFresh {
                            if camera.status.phase == .recording {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    Label(SpeedFormatter.duration(camera.displayedElapsed), systemImage: "record.circle")
                                        .monospacedDigit()
                                }
                            }
                            Label(camera.status.settings.summary + " · " + RemoteCameraSettings.lensTitle(camera.status.settings.lens, zoom: camera.status.lensZoom), systemImage: "video")
                            Text(L10n.tr(camera.status.settings.stabilization ? "rc_stabilization_on" : "rc_stabilization_off"))
                            Label(camera.status.battery < 0 ? "—" : "\(camera.status.battery)%", systemImage: "battery.100")
                            Label(ByteCountFormatter.string(fromByteCount: camera.status.freeBytes, countStyle: .file), systemImage: "internaldrive")
                            if camera.status.battery >= 0 && camera.status.battery <= 10 {
                                Text(L10n.tr("rc_battery_warning")).foregroundStyle(.orange)
                            }
                            if camera.status.thermalWarning { Text(L10n.tr("rc_thermal_warning")).foregroundStyle(.orange) }
                            if let key = camera.status.errorKey { Text(L10n.tr(key)).foregroundStyle(.red) }
                        } else { Text(L10n.tr("rc_offline_help")).foregroundStyle(.secondary) }
                    }
                    Section { RemoteCameraConnectionView() }
                }
                .navigationTitle(L10n.tr("rc_role_camera"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("common_done")) { showConnection = false } } }
                .overlay { if showsInformation { RemoteCameraPairingOverlay() } }
            }
        }
        .overlay { if showsInformation { RemoteCameraPairingOverlay() } }
    }
}

struct RemoteCameraBlackView: View {
    @EnvironmentObject private var camera: RemoteCameraController
    @Environment(\.scenePhase) private var scenePhase
    @State private var reveal = false
    @State private var returnDeadline: TimeInterval = 0
    @State private var remainingSeconds = 20

    private func showControls() {
        guard !reveal else { return }
        returnDeadline = ProcessInfo.processInfo.systemUptime + 20
        remainingSeconds = 20
        camera.restoreBrightness()
        reveal = true
    }

    private func returnToBlack() {
        reveal = false
        camera.dimScreen()
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(count: 5, perform: showControls)
                .accessibilityLabel(L10n.tr("rc_exit_help"))
                .accessibilityIdentifier("camera.black-screen")
                .accessibilityAction(named: Text(L10n.tr("rc_exit"))) {
                    showControls()
                }
            if reveal {
                VStack(spacing: 18) {
                    Image(systemName: "video.fill").font(.largeTitle).foregroundStyle(AppPalette.brandAccent)
                    Text(L10n.tr("rc_title")).font(AppTypography.screenTitle)
                    Text(camera.status.phase.title).font(.headline)
                    if camera.controlLockSeconds > 0 {
                        Label(camera.controlLockText, systemImage: "timer").monospacedDigit()
                            .accessibilityIdentifier("camera.local.cooldown")
                    }
                    Text(L10n.tr("rc_exit_confirmation")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Label(L10n.format("rc_auto_black", remainingSeconds), systemImage: "timer")
                        .font(.subheadline.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("camera.black.countdown")
                        .accessibilityValue(String(remainingSeconds))
                    CapsuleActionButton(action: returnToBlack, role: .primary) {
                        Text(L10n.tr("rc_keep_black"))
                    }.accessibilityIdentifier("camera.black.resume")
                    if camera.status.phase == .error {
                        if let key = camera.status.errorKey { Text(L10n.tr(key)).font(.footnote) }
                        Button(L10n.tr("rc_retry"), action: camera.retryCamera).frame(minHeight: 44)
                    }
                    CapsuleActionButton(action: camera.disarm, role: .neutral) {
                        Text(L10n.tr("rc_exit"))
                    }.accessibilityIdentifier("camera.black.exit")
                }
                .padding(24).frame(maxWidth: 420)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
                .padding(24)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("camera.black.exit-panel")
            }
        }
        .background {
            ExternalButtonInputSurface()
            if #available(iOS 17.2, *) {
                CameraShutterInteraction(enabled: camera.cameraButtonsEnabled, action: camera.handleCaptureButton)
            }
        }
        .statusBar(hidden: !reveal)
        .persistentSystemOverlaysHiddenIfAvailable(!reveal)
        .interactiveDismissDisabled()
        .task(id: reveal) {
            guard reveal else { return }
            while !Task.isCancelled && reveal {
                let remaining = returnDeadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { returnToBlack(); return }
                remainingSeconds = Int(ceil(remaining))
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(1, remaining) * 1_000_000_000))
                } catch { return }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active && reveal { returnToBlack() }
        }
        .onAppear {
            camera.dimScreen()
#if DEBUG
            if ScreenshotState.requested == .cameraExit { showControls() }
#endif
        }
        .onDisappear { camera.restoreBrightness() }
    }
}

struct RemoteCameraPairingOverlay: View {
    @EnvironmentObject private var camera: RemoteCameraController
    var body: some View {
        if let code = camera.pairingCode {
            DecisionConfirmationModal(title: L10n.tr("rc_verify"),
                message: L10n.tr(camera.connectionProgress == .awaitingApproval ? "rc_wait_approval" : "rc_verify_help"), detail: code,
                confirmLabel: L10n.tr("rc_codes_match"), systemName: "lock.shield",
                accessibilityName: "camera.pairing", isProcessing: camera.connectionProgress == .awaitingApproval, onCancel: camera.rejectPairing, onConfirm: camera.approvePairing)
        }
    }
}

private struct CameraShareItem: Identifiable { let id = UUID(); let url: URL }
private struct CameraShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
private extension View {
    func cameraCard(_ scheme: ColorScheme) -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.08)))
    }
    @ViewBuilder func persistentSystemOverlaysHiddenIfAvailable(_ hidden: Bool) -> some View {
        if #available(iOS 16, *) { persistentSystemOverlays(hidden ? .hidden : .automatic) } else { self }
    }
}

/// Native capture events carry a phase, not a raw HID usage/code.
/// The owning Camera screen has a genuine running AVCaptureSession while ready.
@available(iOS 17.2, *)
struct CameraShutterInteraction: UIViewRepresentable {
    let enabled: Bool
    let action: (String) -> Void
    final class Surface: UIView {
        var action: (String) -> Void = { _ in }
        lazy var captureInteraction = AVCaptureEventInteraction(primary: { [weak self] event in
            guard event.phase == .ended else { return }
            self?.action("primary")
        }, secondary: { [weak self] event in
            guard event.phase == .ended else { return }
            self?.action("secondary")
        })
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.addInteraction(view.captureInteraction)
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {
        view.action = action
        view.captureInteraction.isEnabled = enabled
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        view.captureInteraction.isEnabled = false
        view.removeInteraction(view.captureInteraction)
        view.action = { _ in }
    }
}
