import AppKit
import SwiftUI

@main
struct KansolendarApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .appTheme()
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            AppearanceSettingsView()
                .appTheme()
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "appAppearance"

    case system
    case light
    case dark

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .system: "Sistema"
        case .light: "Claro"
        case .dark: "Oscuro"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon.stars"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    static let storageKey = "appAccent"

    case cyan
    case blue
    case indigo
    case purple
    case pink
    case orange
    case green

    var id: Self { self }

    var localizedName: String {
        switch self {
        case .cyan: "Cian"
        case .blue: "Azul"
        case .indigo: "Índigo"
        case .purple: "Morado"
        case .pink: "Rosa"
        case .orange: "Naranja"
        case .green: "Verde"
        }
    }

    var color: Color {
        switch self {
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        }
    }
}

private struct AppThemeModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppAccent.storageKey) private var accent = AppAccent.cyan.rawValue

    func body(content: Content) -> some View {
        content
            .tint(selectedAccent.color)
            .environment(\.appAccentColor, selectedAccent.color)
            .onAppear(perform: applyAppearance)
            .onChange(of: appearance) { _, _ in applyAppearance() }
    }

    private var selectedAccent: AppAccent {
        AppAccent(rawValue: accent) ?? .cyan
    }

    private func applyAppearance() {
        NSApp.appearance = (AppAppearance(rawValue: appearance) ?? .system).appKitAppearance
    }
}

private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue = Color.cyan
}

extension EnvironmentValues {
    var appAccentColor: Color {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }
}

extension View {
    fileprivate func appTheme() -> some View {
        modifier(AppThemeModifier())
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppAccent.storageKey) private var accent = AppAccent.cyan.rawValue

    var body: some View {
        Form {
            Section("Apariencia") {
                Picker("Tema", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Label(option.localizedName, systemImage: option.systemImage)
                            .tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Sistema adapta Kansolendar automáticamente a la apariencia configurada en macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Color de acento") {
                    HStack(spacing: 12) {
                        ForEach(AppAccent.allCases) { option in
                            Button {
                                accent = option.rawValue
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 22, height: 22)
                                    if accent == option.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.localizedName)
                            .accessibilityAddTraits(accent == option.rawValue ? .isSelected : [])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 470, height: 230)
        .navigationTitle("Ajustes")
    }
}
