import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

/// Shared SwiftUI entry point compiled for Android with Skip Lite.
public struct DebugSwiftAndroidPanel: View {
    public init() {}

    public var body: some View {
        DebugSwiftAndroidPanelContent()
    }
}
struct DebugSwiftAndroidPanelContent: View {
    @State var selectedArea: DebugSwiftArea = .network

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleAreas) { area in
                        Button {
                            selectedArea = area
                        } label: {
                            Text(area.title)
                                .font(Font.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .foregroundColor(selectedArea == area ? Color.white : Color.primary)
                                .background(selectedArea == area ? Color.accentColor : Color.secondary.opacity(0.18))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            if visibleAreas.isEmpty {
                // Every area was hidden with `setup(hideFeatures:)`: no tools to show.
                Text(verbatim: "All debug areas are hidden by this app's DebugSwift setup.")
                    .foregroundColor(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationStack {
                    DebugSwiftFeatureList(area: selectedArea)
                        .navigationTitle(selectedArea.title)
                }
                .id(selectedArea.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(ColorScheme.dark)
        .onAppear {
            if !visibleAreas.contains(selectedArea), let firstVisibleArea = visibleAreas.first {
                selectedArea = firstVisibleArea
            }
        }
    }

    var visibleAreas: [DebugSwiftArea] {
        DebugSwiftArea.visible
    }
}
