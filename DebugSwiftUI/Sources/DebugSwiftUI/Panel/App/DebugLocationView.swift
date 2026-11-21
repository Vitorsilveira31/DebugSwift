import SwiftUI

/// The last position the app reported, and a mock position for the GPS and network providers.
struct DebugLocationView: View {
    /// Cities to jump to without typing coordinates.
    static let presets: [(name: String, latitude: Double, longitude: Double)] = [
        ("London, England", 51.509980, -0.133700),
        ("Johannesburg, South Africa", -26.204103, 28.047305),
        ("Moscow, Russia", 55.755786, 37.617633),
        ("Mumbai, India", 19.017615, 72.856164),
        ("Tokyo, Japan", 35.702069, 139.775327),
        ("Sydney, Australia", -33.863400, 151.211000),
        ("Hong Kong, China", 22.284681, 114.158177),
        ("Honolulu, HI, USA", 21.282778, -157.829444),
        ("San Francisco, CA, USA", 37.787359, -122.408227),
        ("Mexico City, Mexico", 19.435478, -99.136479),
        ("New York, NY, USA", 40.759211, -73.984638),
        ("Rio de Janeiro, Brazil", -22.903539, -43.209587)
    ]

    @State var current = ""
    @State var latitude = ""
    @State var longitude = ""
    @State var isMocking = false
    @State var status = ""

    var body: some View {
        Form {
            Section("Last reported location") {
                Text(verbatim: current)
                    .font(.system(.footnote, design: .monospaced))
            }
            Section("Preset locations") {
                ForEach(Self.presets, id: \.name) { preset in
                    Button(preset.name) {
                        latitude = String(preset.latitude)
                        longitude = String(preset.longitude)
                        set()
                    }
                }
            }
            Section("Mock location") {
                TextField("Latitude, for example -23.5505", text: $latitude)
                TextField("Longitude, for example -46.6333", text: $longitude)
                Button("Set location") { set() }
                if isMocking {
                    Button("Stop mocking", role: .destructive) { stop() }
                }
            }
            if !status.isEmpty {
                Section("Status") {
                    Text(verbatim: status).font(.caption)
                }
            }
        }
        .navigationTitle("Location")
        .onAppear { refresh() }
    }

    func refresh() {
        current = DebugSwiftRuntime.snapshot(featureID: "location")
        if case let .success(reply) = DebugResourceClient.fetch("app.location.state", as: DebugActionReply.self) {
            isMocking = reply.mocking ?? false
        }
    }

    func set() {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces))
        else {
            status = "Enter the latitude and longitude as numbers."
            return
        }
        report(DebugResourceClient.fetch(
            "app.location.mock",
            ["latitude": String(lat), "longitude": String(lon)],
            as: DebugActionReply.self,
        ))
    }

    func stop() {
        report(DebugResourceClient.fetch("app.location.stop", as: DebugActionReply.self))
    }

    func report(_ result: Result<DebugActionReply, DebugResourceFailure>) {
        switch result {
        case let .success(reply):
            status = reply.message ?? ""
            isMocking = reply.mocking ?? isMocking
        case let .failure(error):
            status = error.message
        }
        refresh()
    }
}
