import AgentDockCore
import SwiftUI

struct ResetNotificationSettings: View {
    @ObservedObject var controller: ResetReminderController

    var body: some View {
        Form {
            Section {
                Toggle("Notify me before banked Codex resets expire", isOn: Binding(
                    get: { controller.policy.enabled },
                    set: { enabled in
                        if enabled { Task { await controller.enableNotifications() } }
                        else { controller.policy.enabled = false }
                    }
                ))
                LabeledContent("macOS permission") {
                    HStack {
                        Text(controller.permission).foregroundStyle(.secondary)
                        Button("Open Notification Settings…", action: controller.openNotificationSettings)
                    }
                }
                LabeledContent("Test") {
                    Button("Send Test Notification") { Task { await controller.sendTestNotification() } }
                }
                if let error = controller.notificationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Reset Expiration")
            } footer: {
                Text("Choose the Alerts style in macOS Notification Settings for persistent alerts. Alerts use the last checked availability; leave AgentDock running to detect redemptions and new resets.")
            }

            ResetPolicyEditor(policy: Binding(get: { controller.policy }, set: { controller.policy = $0.validated }))
                .disabled(!controller.policy.enabled)
        }
        .formStyle(.grouped)
        .task { await controller.updatePermission() }
    }
}

struct ResetPolicyEditor: View {
    @Binding var policy: ResetReminderPolicy
    @State private var customAmount = 2
    @State private var customUnit = 60

    private let presetMinutes = [10080, 4320, 1440, 360, 60, 15]
    private let repeatChoices = [0, 1, 3, 6, 12, 24]
    private let snoozeChoices = [15, 30, 60, 120, 240, 1440]

    var body: some View {
        Section {
            ForEach(presetMinutes, id: \.self) { minutes in
                Toggle(label(for: minutes), isOn: Binding(
                    get: { policy.warningMinutes.contains(minutes) },
                    set: { selected in
                        var times = policy.warningMinutes.filter { $0 != minutes }
                        if selected { times.append(minutes) }
                        policy.warningMinutes = times.sorted(by: >)
                    }
                ))
            }
            ForEach(policy.warningMinutes.filter { !presetMinutes.contains($0) }, id: \.self) { minutes in
                LabeledContent(label(for: minutes)) {
                    Button("Remove", role: .destructive) { policy.warningMinutes.removeAll { $0 == minutes } }
                }
            }
            LabeledContent("Custom") {
                HStack {
                    TextField("Amount", value: $customAmount, format: .number)
                        .labelsHidden()
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Picker("Unit", selection: $customUnit) {
                        Text("minutes").tag(1)
                        Text("hours").tag(60)
                        Text("days").tag(1440)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add") {
                        let minutes = customAmount * customUnit
                        policy.warningMinutes = Array(Set(policy.warningMinutes + [minutes])).sorted(by: >)
                    }
                    .disabled(customAmount < 1 || customAmount > 525600 / customUnit)
                }
            }
        } header: {
            Text("Remind Me")
        } footer: {
            if policy.warningMinutes.isEmpty {
                Text("Select at least one time to schedule alerts.").foregroundStyle(.orange)
            } else {
                Text("Each selected time sends one reminder for every reset.")
            }
        }

        Section {
            Picker("Repeat", selection: $policy.repeatHours) {
                ForEach(choices(repeatChoices, including: policy.repeatHours), id: \.self) { hours in
                    Text(hours == 0 ? "Only at selected times" : "Every \(durationLabel(minutes: hours * 60))").tag(hours)
                }
            }
            Picker("Snooze for", selection: $policy.snoozeMinutes) {
                ForEach(choices(snoozeChoices, including: policy.snoozeMinutes), id: \.self) { minutes in
                    Text(durationLabel(minutes: minutes)).tag(minutes)
                }
            }
            Toggle("Play a sound", isOn: $policy.sound)
        }

        Section {
            Toggle("Quiet hours", isOn: $policy.quietHours)
            if policy.quietHours {
                Picker("From", selection: $policy.quietStartHour) {
                    ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
                Picker("Until", selection: $policy.quietEndHour) {
                    ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
            }
        } footer: {
            if policy.quietHours {
                Text(policy.quietStartHour == policy.quietEndHour
                    ? "Quiet hours are off while the start and end times match."
                    : "A reminder that would fall after expiration is moved before quiet hours.")
            }
        }
    }

    private func choices(_ presets: [Int], including current: Int) -> [Int] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    private func label(for minutes: Int) -> String {
        "\(durationLabel(minutes: minutes)) before"
    }

    private func durationLabel(minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440) \(minutes == 1440 ? "day" : "days")" }
        if minutes % 60 == 0 { return "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")" }
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
