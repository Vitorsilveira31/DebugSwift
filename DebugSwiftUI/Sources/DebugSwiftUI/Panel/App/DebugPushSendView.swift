import SwiftUI

/// Sends one notification now or after a delay, with optional subtitle, badge, sound, category and
/// payload (userInfo) to exercise the app's notification handling.
struct DebugPushSendView: View {
    @State var title = "DebugSwift test"
    @State var message = "A notification from the debugger."
    @State var delay = "0"
    @State var subtitle = ""
    @State var badge = ""
    @State var sound = ""
    @State var category = ""
    @State var payload = ""
    @State var status = ""

    var body: some View {
        Form {
            Section("Notification") {
                TextField("Title", text: $title)
                TextField("Message", text: $message)
                TextField("Delay in seconds", text: $delay)
            }
            Section("Optional") {
                TextField("Subtitle", text: $subtitle)
                TextField("Badge number", text: $badge)
                TextField("Sound (default, or a sound file name)", text: $sound)
                TextField("Category", text: $category)
                TextField("Payload: key=value, key=value", text: $payload)
            }
            Section {
                Button("Send") {
                    // The simulator splits its input on "|", so keep that character out of the text.
                    let clean = { (text: String) in text.replacingOccurrences(of: "|", with: "/") }
                    let fields = [title, message, delay, subtitle, badge, sound, category, payload].map(clean)
                    status = DebugPush.act("notify", fields.joined(separator: "|"))
                }
            }
            if !status.isEmpty {
                Section("Status") {
                    Text(verbatim: status).font(.caption)
                }
            }
        }
        .navigationTitle("Send a notification")
    }
}
