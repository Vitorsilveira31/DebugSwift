import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

struct DebugSwiftGridOverlaySettingsView: View {
    @State var settings = DebugSwiftGridOverlayState()

    private let colorNames = ["Red", "Blue", "Green", "Yellow", "White", "Gray"]
    private let colors: [Color] = [.red, .blue, .green, .yellow, .white, .gray]

    var body: some View {
        Form {
            Section("Overlay") {
                Toggle("Show grid overlay", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { value in update { $0.isEnabled = value } }
                ))
            }

            if settings.isEnabled {
                Section("Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        Slider(value: Binding(
                            get: { settings.size },
                            set: { value in update { $0.size = value } }
                        ), in: 4.0...64.0, step: 1.0)
                        Text("Size: \(Int(settings.size.rounded())) dp")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Slider(value: Binding(
                            get: { settings.opacity },
                            set: { value in update { $0.opacity = value } }
                        ), in: 0.1...1.0)
                        Text("Opacity: \(Int((settings.opacity * 100).rounded()))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Color") {
                    HStack(spacing: 14) {
                        ForEach(0..<colors.count, id: \.self) { index in
                            colorButton(index)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Grid overlay")
        .onAppear { settings = DebugSwiftRuntime.gridOverlaySettings() }
    }

    func colorButton(_ index: Int) -> some View {
        let isSelected = settings.colorIndex == index
        let checkmark: Color = index == 4 ? Color.black : Color.white
        return Button {
            update { $0.colorIndex = index }
        } label: {
            DebugSwiftColorSwatch(color: colors[index], isSelected: isSelected, checkmarkColor: checkmark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: colorNames[index]))
    }

    private func update(_ change: (inout DebugSwiftGridOverlayState) -> Void) {
        var updated = settings
        change(&updated)
        settings = updated
        _ = DebugSwiftRuntime.setGridOverlaySettings(updated)
    }
}
struct DebugSwiftColorSwatch: View {
    let color: Color
    let isSelected: Bool
    let checkmarkColor: Color

    var body: some View {
        let ringWidth = isSelected ? 2.0 : 0.0
        Circle()
            .fill(color)
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: ringWidth))
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundColor(checkmarkColor)
                }
            }
    }
}
struct DebugSwiftInterfaceSettingView: View {
    let featureID: String
    @State var isEnabled = false

    private var title: String {
        switch featureID {
        case "touches": "Showing touches"
        case "colorize": "Colorized view borders"
        case "view_borders": "Show view borders"
        case "animations": "Slow animations"
        case "dark_mode": "Dark Mode"
        case "measurement": "UI measurements"
        default: "Interface setting"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(title, isOn: Binding(
                    get: { isEnabled },
                    set: { enabled in
                        isEnabled = enabled
                        DebugSwiftRuntime.setInterfaceSetting(featureID: featureID, enabled: enabled)
                    }
                ))
            }
        }
        .onAppear { isEnabled = DebugSwiftRuntime.interfaceSettingIsEnabled(featureID: featureID) }
    }
}
struct DebugSwiftGridOverlayState {
    var isEnabled = false
    var size = 28.0
    var opacity = 0.5
    var colorIndex = 0
}
