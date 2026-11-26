// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWM
import SwiftUI

@main
struct OmniWMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var bootstrap: AppBootstrapState

    init() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--setup-power-helper"]) {
            do {
                try PowerModeHelperSetup.run()
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data(("Power mode helper: " + String(describing: error) + "\n").utf8))
                exit(EXIT_FAILURE)
            }
        }
        AppRelaunch.awaitPredecessor()
        AppLanguagePreference.applyConfiguredLanguage()
        let bootstrap = AppBootstrapState()
        _bootstrap = State(wrappedValue: bootstrap)
        AppDelegate.sharedBootstrap = bootstrap
    }

    var body: some Scene {
        Settings {
            SettingsSceneRedirectView(bootstrap: bootstrap)
        }
    }
}
