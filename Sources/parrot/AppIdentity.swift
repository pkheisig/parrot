enum AppIdentity {
    /// Version 0.2 uses a clean bundle identity so macOS does not reuse the
    /// corrupt Control Center ownership record created for the old build.
    static let bundleIdentifier = "com.pkheisig.parrot"
    static let legacyBundleIdentifier = "com.digimata.parrot"
    static let preferencesSuite = legacyBundleIdentifier
    static let statusItemAutosaveName = "\(bundleIdentifier).primary-status-item"
}
