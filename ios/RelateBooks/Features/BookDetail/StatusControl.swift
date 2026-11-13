import SwiftUI

/// Want / Reading / Read, plus the dates relevant to the current status.
struct StatusControl: View {
    let model: BookDetailModel
    let userData: BookUserData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Status", selection: Binding(
                get: { userData.status },
                set: { status in Task { await model.setStatus(status) } })) {
                ForEach(ReadingStatus.allCases) { status in
                    Text(status.shortLabel).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("status.picker")
            if let line = userData.datesLine() {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("status.dates")
            }
        }
        .padding(.vertical, 2)
    }
}
