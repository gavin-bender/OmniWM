// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct AppearanceSettingsPage: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    @Bindable var windowCornerPreferences: GlobalWindowCornerPreferences
    @Environment(SettingsNavigationModel.self) private var navigation

    private var selection: Binding<String> {
        Binding(get: { navigation.route.tab ?? "app" }, set: { navigation.selectTab($0) })
    }

    var body: some View {
        SettingsTabs(selection: selection, tabs: [("App & Motion", "app"), ("Window Borders", "borders")]) { tab in
            if tab == "borders" {
                BorderSettingsTab(settings: settings, controller: controller)
            } else {
                appAppearance
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var appAppearance: some View {
        let animationsEnabled = Binding(
            get: { controller.motionPolicy.userAnimationsEnabled },
            set: { controller.setAnimationsEnabled($0) }
        )
        return Form {
            Section("Tabbed layout") {
                Picker("Tab bar position", selection: $settings.tabbedBar.position) {
                    Text("Top").tag(TabbedBarOptions.Position.top)
                    Text("Left").tag(TabbedBarOptions.Position.left)
                }
                .id("Tab bar position")
                Picker("Tab bar size", selection: $settings.tabbedBar.size) {
                    Text("Small").tag(TabbedBarOptions.Size.small)
                    Text("Medium").tag(TabbedBarOptions.Size.medium)
                    Text("Large").tag(TabbedBarOptions.Size.large)
                }
                .id("Tab bar size")
                Picker("Tab contents", selection: $settings.tabbedBar.content) {
                    Text("App icons and window titles").tag(TabbedBarOptions.Content.iconsAndTitles)
                    Text("App icons").tag(TabbedBarOptions.Content.icons)
                    Text("Window titles").tag(TabbedBarOptions.Content.titles)
                }
                .id("Tab contents")
            }
            .onChange(of: settings.tabbedBar) {
                controller.workspaceManager.invalidateAllLayouts()
                controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
                controller.surfaceReconciler.noteWorldChanged()
            }
            Section("Appearance") {
                Toggle("Show app icons in tab rails", isOn: Binding(
                    get: { settings.tabRailAppIcons },
                    set: { controller.setTabRailAppIcons($0) }
                ))
                .id("Show app icons in tab rails")
                SettingsCaption(localized: "Replaces compact markers with app icons. Applies to Niri and Dwindle.")

                Toggle("Enable Animations", isOn: animationsEnabled)
                    .id("Enable Animations")
                    .disabled(controller.motionPolicy.systemReducesMotion)
                SettingsCaption(
                    controller.motionPolicy.systemReducesMotion
                        ? String(localized: "Off while macOS Reduce Motion is on.")
                        : String(localized: "Turns OmniWM-authored animations on or off live without relaunching.")
                )

                Toggle("Capture-Free Workspace Swipes", isOn: $settings.captureFreeWorkspaceSwipes)
                    .id("Capture-Free Workspace Swipes")
                SettingsCaption(localized: "Drag to move live windows. Quick or repeated swipes switch on release. With a compatible yabai-sb Dock service, vertical swipes and horizontal column drags use the compositor.")

                Toggle("Slide Workspace Switches", isOn: $settings.slideWorkspaceSwitches)
                    .id("Slide Workspace Switches")
                    .disabled(!controller.motionPolicy.animationsEnabled)
                SettingsCaption(
                    localized: "Animate workspace shortcuts using the same transition as a swipe. Enable Capture-Free Workspace Swipes to move live windows without Screen Recording."
                )

                SettingsSliderRow(
                    label: String(localized: "Tiling Animation Speed"),
                    value: Binding(
                        get: { controller.motionPolicy.animationSpeed },
                        set: { controller.setAnimationSpeed($0) }
                    ),
                    range: AnimationSpeed.range,
                    step: 0.25,
                    valueText: String(
                        localized: "\(controller.motionPolicy.animationSpeed.formatted(.number.precision(.fractionLength(0 ... 2))))×"
                    ),
                    resetAction: { controller.setAnimationSpeed(SettingsExport.defaults().animationSpeed) }
                )
                .id("Tiling Animation Speed")
                .disabled(!controller.motionPolicy.animationsEnabled)
                SettingsCaption(
                    localized: "1× is the default. Higher values make window and workspace transitions faster."
                )

                AppWindowCornerSettings(preferences: windowCornerPreferences)
            }
            .id("Appearance")
        }
        .formStyle(.grouped)
    }
}
