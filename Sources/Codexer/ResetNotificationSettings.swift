import CodexerCore
import SwiftUI

struct ResetNotificationSettings: View {
    @ObservedObject var controller: ResetReminderController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reset Expiration").font(.headline).padding(.top, 16)
            Toggle("Notify me before banked Codex resets expire", isOn: Binding(
                get: { controller.policy.enabled },
                set: { enabled in
                    if enabled { Task { await controller.enableNotifications() } }
                    else { controller.policy.enabled = false }
                }
            ))
            LabeledContent("macOS permission", value: controller.permission)
            HStack {
                Button("Notification Settings…", action: controller.openNotificationSettings)
                Button("Send Test Notification") { Task { await controller.sendTestNotification() } }
            }
            Text("Choose Alerts in macOS Notification Settings for persistent alerts. Focus and system settings control presentation.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = controller.notificationError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Divider()
            ResetPolicyEditor(policy: Binding(get: { controller.policy }, set: { controller.policy = $0.validated }))
            Text("Alerts use your last checked reset availability. Scheduled alerts can appear while AgentDock is closed; leave it running to detect redemptions and new resets. Snoozing persists across restarts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await controller.updatePermission() }
    }
}

struct ResetPolicyEditor: View {
    @Binding var policy: ResetReminderPolicy
    @State private var customAmount = 2
    @State private var customUnit = 60

    private let presetMinutes = [10080, 4320, 1440, 360, 60, 15]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notify before expiration").font(.headline)
            Text("Select multiple times. Each selected time sends one reminder for every reset.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 12) {
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
            }
            HStack {
                TextField("Custom amount", value: $customAmount, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                Picker("Unit", selection: $customUnit) {
                    Text("minutes").tag(1)
                    Text("hours").tag(60)
                    Text("days").tag(1440)
                }.frame(width: 110)
                Button("Add warning time") {
                    let minutes = customAmount * customUnit
                    policy.warningMinutes = Array(Set(policy.warningMinutes + [minutes])).sorted(by: >)
                }
                .disabled(customAmount < 1 || customAmount > 525600 / customUnit)
            }
            ForEach(policy.warningMinutes.filter { !presetMinutes.contains($0) }, id: \.self) { minutes in
                HStack {
                    Text(label(for: minutes))
                    Spacer()
                    Button("Remove") { policy.warningMinutes.removeAll { $0 == minutes } }
                }
            }
            if policy.warningMinutes.isEmpty {
                Text("Select at least one warning time to schedule alerts.").foregroundStyle(.orange)
            }
            Divider()
            numberRow("Also repeat every (hours; 0 = selected times only)", value: $policy.repeatHours, range: 0...8760)
            numberRow("Notification snooze (minutes)", value: $policy.snoozeMinutes, range: 1...10080)
            Toggle("Play a sound", isOn: $policy.sound)
            Toggle("Quiet hours", isOn: $policy.quietHours)
            if policy.quietHours {
                numberRow("Quiet hours begin (0–23)", value: $policy.quietStartHour, range: 0...23)
                numberRow("Quiet hours end (0–23)", value: $policy.quietEndHour, range: 0...23)
                Text("A reminder that would pass expiration is moved before quiet hours. Equal start and end times disable quiet hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func label(for minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440) \(minutes == 1440 ? "day" : "days") before" }
        if minutes % 60 == 0 { return "\(minutes / 60) \(minutes == 60 ? "hour" : "hours") before" }
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes") before"
    }

    private func numberRow(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(label, value: value, format: .number)
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80)
                Stepper(label, value: value, in: range).labelsHidden()
            }
        }
    }
}
