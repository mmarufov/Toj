import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(TojAppearancePreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        ScrollView {
            VStack(spacing: 20) {
                wallpaperPreview

                TojSectionCard("Accent") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(TojAccentPreset.allCases) { preset in
                            Button {
                                preferences.accent = preset
                                TojFeedback.selection()
                            } label: {
                                VStack(spacing: 8) {
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 34, height: 34)
                                        .overlay {
                                            if preferences.accent == preset {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.bold())
                                                    .foregroundStyle(Color.black)
                                            }
                                        }
                                    Text(preset.title)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(TojTheme.text)
                                }
                                .frame(maxWidth: .infinity, minHeight: 70)
                            }
                            .buttonStyle(.tojPressable)
                            .accessibilityAddTraits(preferences.accent == preset ? .isSelected : [])
                        }
                    }
                    .padding(14)
                }

                TojSectionCard("Chat Background") {
                    Picker("Chat Background", selection: $preferences.wallpaper) {
                        ForEach(TojChatWallpaperPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.inline)
                    .tint(TojTheme.accent)
                    .padding(.horizontal, 4)
                }

                TojSectionCard("Message Text Size") {
                    Picker("Message Text Size", selection: $preferences.textSize) {
                        ForEach(TojChatTextSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(14)

                    Text("The quick brown fox — Салом — Привет")
                        .font(.body)
                        .foregroundStyle(TojTheme.text)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(TojTheme.bubbleMine, in: RoundedRectangle(cornerRadius: TojRadius.bubble))
                        .padding([.horizontal, .bottom], 14)
                }
            }
            .padding(16)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var wallpaperPreview: some View {
        ZStack {
            TojChatWallpaper()
            VStack(spacing: 9) {
                Text("Messages adapt instantly")
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(TojTheme.raised.opacity(0.95), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Your choice stays on this device")
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(TojTheme.bubbleMine.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(18)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: TojRadius.cardLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TojRadius.cardLarge, style: .continuous)
                .stroke(TojTheme.hairlineStrong, lineWidth: 0.5)
        }
    }
}

struct LanguageSettingsView: View {
    @Environment(TojAppearancePreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        List {
            Section {
                ForEach(TojAppLanguage.allCases) { language in
                    Button {
                        preferences.language = language
                        TojFeedback.selection()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(language.title)
                                    .foregroundStyle(TojTheme.text)
                                if language == .tajik {
                                    Text("Забони тоҷикӣ")
                                } else if language == .russian {
                                    Text("Русский язык")
                                } else if language == .english {
                                    Text("English language")
                                } else {
                                    Text(Locale.autoupdatingCurrent.localizedString(forIdentifier: Locale.autoupdatingCurrent.identifier) ?? Locale.autoupdatingCurrent.identifier)
                                }
                            }
                            .font(.body)
                            Spacer()
                            if preferences.language == language {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(TojTheme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(preferences.language == language ? .isSelected : [])
                }
            } footer: {
                Text("Toj applies the selected language immediately and keeps it independent from your iPhone language.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(TojTheme.canvas)
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }
}
