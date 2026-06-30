//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import SwiftUI

@MainActor
struct UTMSingleWindowView: View {
    private var isInteractive: Bool {
        data != nil
    }

    #if WITH_REMOTE
    typealias DataType = UTMRemoteData
    #else
    typealias DataType = UTMData
    #endif
    private let data: DataType?
    @State private var session: VMSessionState?
    @State private var identifier: VMSessionState.WindowID?

    private let vmSessionCreatedNotification = NotificationCenter.default.publisher(for: .vmSessionCreated)
    private let vmSessionEndedNotification = NotificationCenter.default.publisher(for: .vmSessionEnded)
    
    init(data: DataType? = nil) {
        self.data = data
    }
    
    var body: some View {
        ZStack {
            if let session = session {
                VMWindowView(id: identifier!, isInteractive: isInteractive).environmentObject(session)
            } else if isInteractive {
                #if WITH_REMOTE
                RemoteContentView(remoteClientState: data!.remoteClient.state).environmentObject(data!)
                #else
                ClaudeBoxLauncher().environmentObject(data!)
                #endif
            } else {
                VStack {
                    Text("Waiting for VM to connect to display...")
                        .font(.headline)
                    BusyIndicator()
                }
            }
        }
        .onAppear {
            session = VMSessionState.allActiveSessions.first?.value
            if let session = session {
                identifier = session.newWindow().windowID
            }
        }
        .onReceive(vmSessionCreatedNotification) { output in
            let newSession = output.userInfo!["Session"] as! VMSessionState
            withAnimation {
                session = newSession
                identifier = newSession.newWindow().windowID
            }
        }
        .onReceive(vmSessionEndedNotification) { output in
            let endedSession = output.userInfo!["Session"] as! VMSessionState
            if endedSession == session {
                withAnimation {
                    session = nil
                }
            }
        }
    }
}

// MARK: - ClaudeBox Launcher

/// ClaudeBox auto-launcher: on app start, creates (if needed) and starts a
/// preconfigured Alpine ARM64 VM with a serial terminal. Replaces UTM's VM
/// list view so the user lands directly in a terminal session.
@MainActor
struct ClaudeBoxLauncher: View {
    @EnvironmentObject var data: UTMData
    @State private var statusMessage = NSLocalizedString("Initializing…", comment: "ClaudeBoxLauncher")
    @State private var errorMessage: String?
    @State private var hasLaunched = false

    /// Fixed VM name used for the ClaudeBox Alpine instance.
    private static let vmName = "ClaudeBox-Alpine"

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("ClaudeBox")
                .font(.largeTitle.bold())
            if let errorMessage = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundColor(.secondary)
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
        .onAppear {
            guard !hasLaunched else { return }
            hasLaunched = true
            Task {
                await launch()
            }
        }
    }

    // MARK: Launch flow

    private func launch() async {
        // 1. Refresh VM list so we can find an existing ClaudeBox VM.
        statusMessage = NSLocalizedString("Loading…", comment: "ClaudeBoxLauncher")
        await data.listRefresh()

        // 2. JIT check (mirrors ContentView behaviour for TrollStore builds).
        #if WITH_JIT
        if !Main.jitAvailable {
            statusMessage = NSLocalizedString("Enabling JIT…", comment: "ClaudeBoxLauncher")
            if !UTMCapabilities.current.contains(.hasHypervisorSupport) {
                // Try AltJIT / JitStreamer, same as ContentView.
                let jitStreamerAttach = UserDefaults.standard.bool(forKey: "JitStreamerAttach")
                if #available(iOS 15, *), jitStreamerAttach {
                    do {
                        try await data.jitStreamerAttach()
                    } catch {
                        errorMessage = String.localizedStringWithFormat(
                            NSLocalizedString("JIT attach failed: %@. Please ensure TrollStore JIT entitlements are active.", comment: "ClaudeBoxLauncher"),
                            error.localizedDescription)
                        return
                    }
                } else {
                    errorMessage = NSLocalizedString(
                        "JIT is not available. Please launch via TrollStore with JIT enabled.",
                        comment: "ClaudeBoxLauncher")
                    return
                }
            }
        }
        #endif

        // 3. Find or create the Alpine VM.
        var vm = data.virtualMachines.first { $0.config?.information.name == Self.vmName }

        if vm == nil {
            statusMessage = NSLocalizedString("Creating Alpine VM…", comment: "ClaudeBoxLauncher")
            do {
                vm = try await createAlpineVM()
            } catch {
                errorMessage = String.localizedStringWithFormat(
                    NSLocalizedString("Failed to create VM: %@", comment: "ClaudeBoxLauncher"),
                    error.localizedDescription)
                return
            }
        }

        guard let vm = vm else {
            errorMessage = NSLocalizedString("Failed to create VM.", comment: "ClaudeBoxLauncher")
            return
        }

        // 4. Ensure the VM is loaded.
        if !vm.isLoaded {
            do {
                try vm.load()
            } catch {
                errorMessage = String.localizedStringWithFormat(
                    NSLocalizedString("Failed to load VM: %@", comment: "ClaudeBoxLauncher"),
                    error.localizedDescription)
                return
            }
        }

        // 5. Start the VM. UTMData.run(vm:) creates a VMSessionState which
        //    posts .vmSessionCreated; UTMSingleWindowView listens for that
        //    notification and switches to VMWindowView (terminal display).
        statusMessage = NSLocalizedString("Starting VM…", comment: "ClaudeBoxLauncher")
        data.run(vm: vm)
    }

    /// Builds a minimal Alpine ARM64 VM configuration: aarch64/virt machine,
    /// CPU `max`, 512 MB RAM, no graphical display (‑nographic), a single
    /// builtin serial port (SPICE terminal), TCG software emulation.
    private func createAlpineVM() async throws -> VMData {
        let config = UTMQemuConfiguration()
        config.information.name = Self.vmName

        // Architecture & target must be set before reset().
        config.system.architecture = .aarch64
        config.system.target = QEMUTarget_aarch64.virt
        config.reset(forArchitecture: .aarch64, target: QEMUTarget_aarch64.virt)

        // CPU: use `max` for best feature support under TCG.
        config.system.cpu = QEMUCPU_aarch64.max
        config.system.memorySize = 512   // MiB
        config.system.cpuCount = 0       // 0 = match host core count

        // Console-only: clear displays (triggers -nographic) and add a
        // builtin serial port so UTM shows a SwiftTerm terminal.
        config.displays = []
        config.serials = [UTMQemuConfigurationSerial()]

        // Force TCG (software emulation) — iOS has no hypervisor access.
        config.qemu.hasHypervisor = false

        // Persist through UTMData (writes config.plist under Documents/).
        return try await data.create(config: config)
    }
}

struct UTMSingleWindowView_Previews: PreviewProvider {
    static var previews: some View {
        UTMSingleWindowView(data: UTMSingleWindowView.DataType())
    }
}
