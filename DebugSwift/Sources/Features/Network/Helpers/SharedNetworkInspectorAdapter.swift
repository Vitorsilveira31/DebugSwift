//
//  SharedNetworkInspectorAdapter.swift
//  DebugSwift
//
//  Platform adapter used by the Skip SwiftUI network inspector.
//

import DebugSwiftCore
import Foundation
import UIKit

public extension DebugSwift.Network {
    /// Encodes captured requests for the shared SwiftUI network inspector.
    @MainActor
    func sharedInspectorSnapshotJSON(featureID: String) -> String {
        let requests = sharedInspectorModels(featureID: featureID).map(sharedInspectorRequest)
        return NetworkInspectorRequest.snapshotJSON(requests)
    }

    /// Performs a platform action for one captured request or a whole feature.
    @MainActor
    func performSharedInspectorAction(featureID: String, actionID: String, requestID: String = "") -> String {
        let models = sharedInspectorModels(featureID: featureID)
        let model = models.first { $0.requestId == requestID }

        switch actionID {
        case "clear":
            let removedIDs = Set(models.compactMap(\.requestId))
            let datasource = HttpDatasource.shared
            datasource.httpModels.removeAll { removedIDs.contains($0.requestId ?? "") }
            for (index, request) in datasource.httpModels.enumerated() {
                request.index = index
            }
            NotificationCenter.default.post(name: NSNotification.Name("reloadHttp_DebugSwift"), object: nil)
            return "Request history cleared."
        case "delete":
            guard let model else { return "This request is no longer available." }
            HttpDatasource.shared.remove(model)
            NotificationCenter.default.post(name: NSNotification.Name("reloadHttp_DebugSwift"), object: nil)
            return "Request removed."
        case "copy_url":
            guard let model, let url = model.url?.absoluteString else { return "This request is no longer available." }
            UIPasteboard.general.string = url
            return "URL copied."
        case "copy_log":
            guard let model else { return "This request is no longer available." }
            UIPasteboard.general.string = sharedInspectorRequest(model).log
            return "Request log copied."
        case "share_log":
            guard let model else { return "This request is no longer available." }
            FileSharingManager.generateFileAndShare(text: sharedInspectorRequest(model).log, fileName: "debugswift-request")
            return "Sharing request log."
        case "copy_curl":
            guard let model else { return "This request is no longer available." }
            _ = HARExportAdapter.copyCURL(model)
            return "cURL copied."
        case "export_har":
            guard !models.isEmpty else { return "There are no requests to export." }
            HARExportAdapter.exportHAR(models)
            return "Sharing HAR export."
        case "replay":
            guard let model, let url = model.url else { return "This request is no longer available." }
            var request = URLRequest(url: url)
            request.httpMethod = model.method ?? "GET"
            model.requestHeaderFields?.forEach { key, value in
                if let stringValue = value as? String {
                    request.setValue(stringValue, forHTTPHeaderField: key)
                }
            }
            request.httpBody = model.requestData
            URLSession.shared.dataTask(with: request).resume()
            return "Request replay started. Its response will appear in the request list."
        default:
            return "Unknown network action: \(actionID)."
        }
    }

    // MARK: - Private helpers

    private func sharedInspectorModels(featureID: String) -> [HttpModel] {
        let allModels = HttpDatasource.shared.httpModels
        for model in allModels where model.requestId == nil {
            model.requestId = UUID().uuidString
        }
        switch featureID {
        case "webview_network":
            return allModels.filter(sharedInspectorIsWebView)
        case "graphql":
            return allModels.filter { !sharedInspectorIsWebView($0) && GraphQLInspectorAdapter.isGraphQL($0) }
        default:
            return allModels.filter { !sharedInspectorIsWebView($0) }
        }
    }

    private func sharedInspectorIsWebView(_ model: HttpModel) -> Bool {
        model.responseHeaderFields?.first { $0.key.caseInsensitiveCompare("X-DebugSwift-Source") == .orderedSame }?.value as? String == "WKWebView"
    }

    /// The inspector row for a captured request, built by DebugSwiftCore as on Android.
    private func sharedInspectorRequest(_ model: HttpModel) -> NetworkInspectorRequest {
        if model.requestId == nil {
            model.requestId = UUID().uuidString
        }
        let duration = Double((model.totalDuration ?? "0").replacingOccurrences(of: " (s)", with: "")) ?? 0
        return NetworkInspectorRequest(
            id: model.requestId ?? UUID().uuidString,
            url: model.url?.absoluteString ?? "",
            method: model.method ?? "GET",
            statusCode: model.statusCode ?? "0",
            startedAtMilliseconds: Self.sharedInspectorTimestamp(model.startTime),
            timestamp: model.startTime ?? "",
            durationMilliseconds: Int((duration * 1_000).rounded()),
            requestHeaders: Self.sharedInspectorHeaders(model.requestHeaderFields),
            responseHeaders: Self.sharedInspectorHeaders(model.responseHeaderFields),
            requestBody: model.requestData ?? Data(),
            responseBody: model.responseData ?? Data(),
            decryptedResponseBody: model.decryptedResponseData ?? Data(),
            mimeType: model.mineType,
            error: model.errorLocalizedDescription ?? model.errorDescription ?? "",
            source: sharedInspectorIsWebView(model) ? "webview" : "http"
        )
    }

    private static func sharedInspectorHeaders(_ headers: [String: Any]?) -> [String: String] {
        (headers ?? [:]).mapValues { String(describing: $0) }
    }

    private static func sharedInspectorTimestamp(_ value: String?) -> Int64 {
        guard let value else { return 0 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return Int64((formatter.date(from: value)?.timeIntervalSince1970 ?? 0) * 1_000)
    }
}
