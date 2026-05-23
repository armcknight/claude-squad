import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: SessionMonitor
    let loginItemManager: LoginItemManagerProtocol
    let globalHotkey: GlobalHotkey
    weak var logger: Logger?

    @State private var launchAtLogin: Bool = false
    @State private var hotkeyCombo: GlobalHotkey.KeyCombo = .default
    @State private var selectedTab: SettingsTab = .general
    @State private var pollFrequency: TimeInterval = AppSettings.pollFrequency

    private let pollFrequencyOptions: [TimeInterval] = [1, 3, 5, 10, 30, 60]

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case about = "About"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch selectedTab {
            case .general:
                generalTab
            case .about:
                aboutTab
            }

            Spacer()
        }
        .frame(width: 400, height: 280)
        .onAppear {
            launchAtLogin = loginItemManager.isEnabled
            hotkeyCombo = globalHotkey.currentCombo
            pollFrequency = AppSettings.pollFrequency
        }
    }

    private var generalTab: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        try loginItemManager.setEnabled(newValue)
                    } catch {
                        logger?.error("Failed to set launch at login: \(error.localizedDescription)")
                        launchAtLogin = !newValue
                    }
                }

            LabeledContent("Global Hotkey") {
                HotkeyRecorderView(currentCombo: hotkeyCombo) { newCombo in
                    hotkeyCombo = newCombo
                    globalHotkey.updateCombo(newCombo)
                }
            }

            Picker("Poll Interval", selection: $pollFrequency) {
                ForEach(pollFrequencyOptions, id: \.self) { value in
                    Text(pollFrequencyLabel(value)).tag(value)
                }
            }
            .onChange(of: pollFrequency) { _, newValue in
                AppSettings.pollFrequency = newValue
                monitor.updateRefreshInterval(newValue)
            }
        }
        .formStyle(.grouped)
    }

    private func pollFrequencyLabel(_ interval: TimeInterval) -> String {
        if interval == 60 { return "1 minute" }
        let seconds = Int(interval)
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    private var aboutTab: some View {
        Form {
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                LabeledContent("Version", value: version)
            }
            if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                LabeledContent("Build", value: build)
            }
            if let commit = Bundle.main.infoDictionary?["GIT_COMMIT_HASH"] as? String, !commit.isEmpty {
                LabeledContent("Commit", value: commit)
            }
            if let branch = Bundle.main.infoDictionary?["GIT_BRANCH_NAME"] as? String, !branch.isEmpty {
                LabeledContent("Branch", value: branch)
            }
        }
        .formStyle(.grouped)
    }
}
