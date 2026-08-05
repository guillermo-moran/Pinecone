public enum RuntimeDirection {
    public static let activeTrack = "native-linux-postmarketos"
    public static let javascriptMobileOSIsEnabled = false
    public static let javascriptMobileOSDisabledReason = "JavaScript MobileOS is disabled; native Linux/postmarketOS bring-up is the active track"

    public static func requireJavaScriptMobileOSEnabled(operation: String) throws {
        guard javascriptMobileOSIsEnabled else {
            throw VMError.unsupportedGuest("\(operation): \(javascriptMobileOSDisabledReason)")
        }
    }
}
