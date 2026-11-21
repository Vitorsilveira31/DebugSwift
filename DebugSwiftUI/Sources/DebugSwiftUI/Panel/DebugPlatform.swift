/// Which platform the shared screens run on, for the few words that differ (Activity or view
/// controller, StrictMode or the thread checker).
enum DebugPlatform {
    static var isAndroid: Bool {
        #if os(Android)
        true
        #else
        false
        #endif
    }
}
