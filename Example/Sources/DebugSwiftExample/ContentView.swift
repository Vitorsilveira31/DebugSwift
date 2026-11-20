import DebugSwiftUI
import Foundation
import SwiftUI

/// The list of demos. Each one exercises a DebugSwift tool; the debug panel shows the result.
struct ContentView: View {
    @State var showDebugger = false
    @State var deepLink: DeepLink?
    @State var showsFloatingButton = DebugSwiftRuntime.isFloatingButtonVisible

    var body: some View {
        NavigationStack {
            List {
                Section("DebugSwift") {
                    Button("Open debug panel") { openDebugger() }
                    Button(showsFloatingButton ? "Hide floating button" : "Show floating button") {
                        showsFloatingButton.toggle()
                        DebugSwiftRuntime.isFloatingButtonVisible = showsFloatingButton
                    }
                }

                Section("Network") {
                    DemoLink("REST API Demo", "Test all HTTP methods against a fake REST API") {
                        MockRequestView()
                    }
                    DemoLink("GraphQL Inspector Test", "Test GraphQL operation parsing with a public endpoint") {
                        GraphQLDemoView()
                    }
                    DemoLink("Network Injection Testing", "Test delay, failure and rewrite injection") {
                        NetworkInjectionExampleView()
                    }
                    DemoLink("WebSocket Inspector Test", "Test WebSocket connections") {
                        WebSocketTestView()
                    }
                    #if os(iOS)
                    DemoLink("Google WebView", "Test WebKit integration with controls") {
                        WebViewTestView()
                    }
                    #endif
                }

                Section("Performance") {
                    DemoLink("Hang / ANR Demo", "Block the main thread to trigger hang detection") {
                        HangDemoView()
                    }
                    DemoLink("Disk I/O Test Suite", "Generate write activity to exercise the Disk panel") {
                        DiskIOTestView()
                    }
                    DemoLink("Memory Leak Demo", "Leave an object alive after its screen closes") {
                        LeakView()
                    }
                    #if os(iOS)
                    DemoLink("Backtrace Capture Demo", "Programmatically capture call stacks via SE-0419 API") {
                        BacktraceDemoView()
                    }
                    #endif
                }

                Section("App") {
                    DemoLink("OSLog Console Test", "Log messages at every level") {
                        OSLogTestView()
                    }
                    DemoLink("Security Audit Test", "Seed sensitive UserDefaults for the security audit") {
                        SecurityAuditTestView()
                    }
                    DemoLink("Deep Link Test View", "Show how a debugswift:// link is parsed") {
                        DeepLinkTestView(url: URL(string: "debugswift://test?id=123"))
                    }
                }

                #if os(iOS)
                Section("Interface") {
                    DemoLink("HyperionSwift Measurement Tool", "Interactive UI element measurement and spacing tool") {
                        HyperionSwiftDemoView()
                    }
                    DemoLink("Map", "Show the user's location on a map") {
                        MapView()
                    }
                }
                #endif
            }
            .navigationTitle("DebugSwift Examples")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openDebugger()
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .accessibilityLabel("Debugger")
                }
            }
        }
        .sheet(isPresented: $showDebugger) {
            DebugSwiftRuntime.panel { showDebugger = false }
        }
        .sheet(item: $deepLink) { link in
            DeepLinkTestView(url: link.url)
        }
        .onOpenURL { url in
            guard url.scheme == "debugswift" else { return }
            deepLink = DeepLink(url: url)
        }
        .onAppear {
            DebugFloatingButton.onTap = { openDebugger() }
            showsFloatingButton = DebugSwiftRuntime.isFloatingButtonVisible
        }
    }

    private func openDebugger() {
        showDebugger = true
    }
}

/// A deep link that arrived while the app was open.
struct DeepLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A row that opens one demo.
struct DemoLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let destination: () -> Destination

    init(_ title: String, _ subtitle: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
