import ImageIO
import PhotosUI
import SwiftUI
import UIKit

struct ProfileEditView: View {
    @Bindable var model: CloudAppModel
    @Binding private var persistedPhotoData: Data?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?

    @State private var details: StoredProfileDetails
    @State private var photoData: Data?
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoWasEdited = false
    @State private var isPreparingPhoto = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showingBirthday = false
    @State private var showingColors = false
    @State private var showingPhoneInfo = false
    @State private var showingSignOut = false
    @State private var pendingLogoutItemCount = 0
    private let photoAccountId: String?

    private enum Field: Hashable {
        case username
        case firstName
        case lastName
        case bio
    }

    init(
        model: CloudAppModel,
        persistedPhotoData: Binding<Data?>,
        photoAccountId: String?
    ) {
        self.model = model
        self._persistedPhotoData = persistedPhotoData
        self.photoAccountId = photoAccountId
        self._details = State(initialValue: model.profileDetails)
        self._photoData = State(initialValue: persistedPhotoData.wrappedValue)
    }

    private var trimmedFirstName: String {
        details.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedFirstName.isEmpty && usernameIsValid && !isSaving && !isPreparingPhoto
    }

    private var usernameIsValid: Bool {
        guard let username = details.username, !username.isEmpty else { return true }
        return username.range(of: "^[a-z][a-z0-9_]{4,31}$", options: .regularExpression) != nil
    }

    private var displayName: String {
        details.displayName.isEmpty ? String(localized: "Toj") : details.displayName
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                photoEditor
                    .padding(.top, 84)

                nameFields

                profileTextField

                usernameField

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        focusedField = nil
                        showingBirthday = true
                    } label: {
                        ProfileValueRow(
                            title: "Birthday",
                            systemImage: "birthday.cake.fill",
                            colors: [Color(hex: 0x55B9FF), Color(hex: 0x247AF4)],
                            value: details.birthday?.formatted(date: .abbreviated, time: .omitted)
                                ?? String(localized: "Add Birthday")
                        )
                    }
                    .buttonStyle(.tojPressable(scale: 0.985))

                    Text(details.birthday == nil
                         ? "Add your birthday when you’re ready. People you chat with can see it."
                         : "People you chat with can see your birthday.")
                        .font(.footnote)
                        .foregroundStyle(TojTheme.secondaryText)
                        .padding(.horizontal, 18)
                }

                TojSectionCard {
                    Button {
                        focusedField = nil
                        showingPhoneInfo = true
                    } label: {
                        ProfileValueRow(
                            title: "Number",
                            systemImage: "phone.fill",
                            colors: [Color(hex: 0x58DF7D), Color(hex: 0x25B95A)],
                            value: model.storedSession?.phone ?? "",
                            showsDivider: true
                        )
                    }
                    .buttonStyle(.tojPressable(scale: 0.985))

                    Button {
                        focusedField = nil
                        showingColors = true
                    } label: {
                        ProfileColorRow(colorIndex: details.colorIndex)
                    }
                    .buttonStyle(.tojPressable(scale: 0.985))
                }

                Button {
                    focusedField = nil
                    Task {
                        pendingLogoutItemCount = await model.pendingDestructiveLogoutItemCount()
                        showingSignOut = true
                    }
                } label: {
                    Text("Log Out")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(TojTheme.danger)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous)
                                .stroke(TojTheme.danger.opacity(0.12), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.tojPressable(scale: 0.985))

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(TojTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TojTheme.canvas)
        .overlay(alignment: .top) { editorHeader }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, value: photoData)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, value: saveError)
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            Task { await preparePhoto(selection) }
        }
        .sheet(isPresented: $showingBirthday) {
            ProfileBirthdayPicker(birthday: $details.birthday)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingColors) {
            ProfileColorPicker(selection: $details.colorIndex, displayName: displayName)
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPhoneInfo) {
            ProfilePhoneInfoView(phone: model.storedSession?.phone ?? "")
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            pendingLogoutItemCount > 0
                ? "Discard pending work and log out?"
                : "Log out of Toj?",
            isPresented: $showingSignOut,
            titleVisibility: .visible
        ) {
            Button(
                pendingLogoutItemCount > 0
                    ? "Discard \(pendingLogoutItemCount) pending item\(pendingLogoutItemCount == 1 ? "" : "s")"
                    : "Log Out",
                role: .destructive
            ) {
                dismiss()
                Task { await model.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if pendingLogoutItemCount > 0 {
                Text("Pending messages, edits, chat settings, or uploads have not reached the cloud and will be permanently removed from this device.")
            } else {
                Text("Your encrypted local replica and downloaded media will be removed. You can sign back in with your phone number at any time.")
            }
        }
        .interactiveDismissDisabled(isSaving || isPreparingPhoto)
    }

    private var editorHeader: some View {
        HStack {
            editorPill(title: "Cancel", enabled: !isSaving && !isPreparingPhoto) {
                focusedField = nil
                dismiss()
            }
            Spacer()
            editorPill(title: "Done", enabled: canSave, showsProgress: isSaving) {
                focusedField = nil
                Task { await save() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [TojTheme.canvas, TojTheme.canvas.opacity(0.94), TojTheme.canvas.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private func editorPill(
        title: LocalizedStringKey,
        enabled: Bool,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TojTheme.text)
                }
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(TojTheme.text.opacity(enabled ? 1 : 0.42))
            .padding(.horizontal, 18)
            .frame(minWidth: 82, minHeight: 46)
            .contentShape(Capsule())
            .tojGlass(in: Capsule(), interactive: enabled)
        }
        .buttonStyle(.tojPressable)
        .disabled(!enabled)
    }

    private var photoEditor: some View {
        let currentDisplayName = displayName
        let currentPhotoData = photoData
        let currentColorIndex = details.colorIndex
        let preparingPhoto = isPreparingPhoto
        let photoActionTitle = currentPhotoData == nil
            ? String(localized: "Set Photo")
            : String(localized: "Change Photo")
        let photoAccent = TojTheme.accent

        return VStack(spacing: 12) {
            PhotosPicker(selection: $photoSelection, matching: .images) {
                ProfilePhotoPickerLabel(
                    displayName: currentDisplayName,
                    photoData: currentPhotoData,
                    colorIndex: currentColorIndex,
                    isPreparing: preparingPhoto
                )
            }
            .buttonStyle(.tojPressable(scale: 0.97))
            .disabled(isPreparingPhoto)

            PhotosPicker(selection: $photoSelection, matching: .images) {
                Text(photoActionTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(photoAccent)
            }
            .buttonStyle(.tojPressable)
            .disabled(isPreparingPhoto)

            if photoData != nil {
                Button("Remove Photo", role: .destructive) {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.stateAnimation) {
                        photoData = nil
                        photoWasEdited = true
                    }
                    TojFeedback.selection()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.tojPressable)
            }

            profilePhotoSyncStatus
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var profilePhotoSyncStatus: some View {
        switch model.profilePhotoSyncState {
        case .localOnly:
            if model.capabilities.contains(.profilePhotos) == false {
                Label("Saved on this device", systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
            }
        case .synced:
            Label("Synced", systemImage: "checkmark.icloud.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TojTheme.secure)
                .accessibilityIdentifier("profile-photo-status-synced")
        case .pending:
            Label("Waiting to sync", systemImage: "arrow.triangle.2.circlepath.icloud")
                .font(.caption.weight(.semibold))
                .foregroundStyle(TojTheme.secondaryText)
                .accessibilityIdentifier("profile-photo-status-pending")
        case let .failed(message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.icloud.fill")
                    .font(.caption)
                    .foregroundStyle(TojTheme.danger)
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Button("Retry") { Task { await model.retryProfilePhoto() } }
                    Button("Discard", role: .destructive) {
                        Task { await model.discardPendingProfilePhoto() }
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .accessibilityIdentifier("profile-photo-status-failed")
        case .conflict:
            VStack(spacing: 8) {
                Label("Photo changed on another device", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(TojTheme.accent)
                HStack(spacing: 16) {
                    Button("Use cloud photo") { Task { await model.useCloudProfilePhoto() } }
                    Button("Use mine") { Task { await model.retryProfilePhoto() } }
                }
                .font(.caption.weight(.semibold))
            }
            .accessibilityIdentifier("profile-photo-status-conflict")
        }
    }

    private var nameFields: some View {
        VStack(spacing: 0) {
            TextField("First Name", text: $details.firstName)
                .focused($focusedField, equals: .firstName)
                .textContentType(.givenName)
                .submitLabel(.next)
                .onSubmit { focusedField = .lastName }
                .profileFieldStyle()

            Rectangle()
                .fill(TojTheme.hairlineStrong)
                .frame(height: 0.5)
                .padding(.leading, 18)

            TextField("Last Name", text: $details.lastName)
                .focused($focusedField, equals: .lastName)
                .textContentType(.familyName)
                .submitLabel(.next)
                .onSubmit { focusedField = .bio }
                .profileFieldStyle()
        }
        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous).stroke(TojTheme.hairline, lineWidth: 0.5))
    }

    private var profileTextField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Bio", text: $details.bio, axis: .vertical)
                .focused($focusedField, equals: .bio)
                .textContentType(.none)
                .lineLimit(1...4)
                .profileFieldStyle(minHeight: 58)
                .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous).stroke(TojTheme.hairline, lineWidth: 0.5))
                .onChange(of: details.bio) { _, value in
                    if value.count > 120 { details.bio = String(value.prefix(120)) }
                }

            HStack {
                Text("A few words about you.")
                Spacer()
                Text("\(details.bio.count)/120")
                    .contentTransition(.numericText())
            }
            .font(.footnote)
            .foregroundStyle(TojTheme.secondaryText)
            .padding(.horizontal, 18)
        }
    }

    private var usernameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("@")
                    .foregroundStyle(TojTheme.secondaryText)
                TextField("username", text: Binding(
                    get: { details.username ?? "" },
                    set: { details.username = $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" } }
                ))
                .focused($focusedField, equals: .username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
            }
            .profileFieldStyle()
            .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))

            Text(usernameIsValid
                 ? "Your profile link works across Toj without exposing your phone number."
                 : "Use 5–32 letters, numbers, or underscores, starting with a letter.")
                .font(.footnote)
                .foregroundStyle(usernameIsValid ? TojTheme.secondaryText : TojTheme.danger)
                .padding(.horizontal, 18)

            if let username = details.username, usernameIsValid {
                let link = URL(string: "toj://user/\(username)")!
                HStack {
                    ShareLink(item: link) {
                        Label("Share Profile Link", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    TojQRCode(value: link.absoluteString, size: 82)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TojTheme.accent)
                .padding(.horizontal, 18)
            }
        }
    }

    @MainActor
    private func preparePhoto(_ selection: PhotosPickerItem) async {
        isPreparingPhoto = true
        defer { isPreparingPhoto = false }
        guard let source = try? await selection.loadTransferable(type: Data.self),
              let prepared = await Task.detached(priority: .userInitiated, operation: {
                  ProfilePhotoProcessor.preparedPhoto(from: source)
              }).value else {
            saveError = String(localized: "That photo could not be opened.")
            return
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.stateAnimation) {
            photoData = prepared
            photoWasEdited = true
            saveError = nil
        }
        TojFeedback.selection()
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let detailsSaved = await model.saveProfileDetails(details)
        var photoSaved = true
        if photoWasEdited, let photoAccountId {
            photoSaved = await model.saveProfilePhoto(photoData, accountId: photoAccountId)
            if photoSaved { persistedPhotoData = photoData }
        }
        guard detailsSaved, photoSaved else {
            saveError = if detailsSaved {
                String(localized: "Your details were saved, but the photo could not be stored.")
            } else if photoSaved && photoWasEdited {
                String(localized: "Your photo was saved, but your profile details still need attention.")
            } else {
                String(localized: "Your profile could not be saved. Please try again.")
            }
            return
        }
        TojFeedback.selection()
        dismiss()
    }
}

private struct ProfilePhotoPickerLabel: View {
    let displayName: String
    let photoData: Data?
    let colorIndex: Int
    let isPreparing: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ProfileEditorAvatar(
                displayName: displayName,
                photoData: photoData,
                colorIndex: colorIndex,
                size: 112
            )
            .shadow(color: TojProfilePalette.primary(colorIndex).opacity(0.24), radius: 24, y: 12)

            Image(systemName: isPreparing ? "ellipsis" : "camera.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(TojTheme.onAccent)
                .frame(width: 36, height: 36)
                .background(TojTheme.accent, in: Circle())
                .overlay(Circle().stroke(TojTheme.canvas, lineWidth: 3))
                .symbolEffect(.pulse, isActive: isPreparing)
        }
    }
}

private extension View {
    func profileFieldStyle(minHeight: CGFloat = 56) -> some View {
        self
            .font(.body.weight(.medium))
            .foregroundStyle(TojTheme.text)
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
    }
}

private struct ProfileValueRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let colors: [Color]
    let value: String
    var showsDivider = false

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemImage: systemImage, colors: colors)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(TojTheme.text)
            Spacer(minLength: 10)
            Text(value)
                .font(.body)
                .foregroundStyle(TojTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(TojTheme.tertiaryText)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 58)
        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: showsDivider ? 0 : TojRadius.card, style: .continuous))
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(TojTheme.hairlineStrong)
                    .frame(height: 0.5)
                    .padding(.leading, 63)
            }
        }
    }
}

private struct ProfileColorRow: View {
    let colorIndex: Int

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(
                systemImage: "paintbrush.fill",
                colors: [Color(hex: 0x54CCF5), Color(hex: 0x2499D7)]
            )
            Text("Your Color")
                .font(.body.weight(.medium))
                .foregroundStyle(TojTheme.text)
            Spacer()
            Circle()
                .fill(TojProfilePalette.gradient(colorIndex))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(TojTheme.tertiaryText)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

private struct ProfileEditorAvatar: View {
    let displayName: String
    let photoData: Data?
    let colorIndex: Int
    let size: CGFloat

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(TojProfilePalette.gradient(colorIndex))
                    Text(displayName.first.map { String($0).uppercased() } ?? "T")
                        .font(TojTheme.heading(.largeTitle, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .contentShape(Circle())
        .accessibilityLabel("Profile photo")
        .accessibilityHint("Choose a new photo")
    }
}

private struct ProfileBirthdayPicker: View {
    @Binding var birthday: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date

    init(birthday: Binding<Date?>) {
        self._birthday = birthday
        self._selection = State(
            initialValue: birthday.wrappedValue
                ?? Calendar.current.date(byAdding: .year, value: -18, to: .now)
                ?? .now
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                DatePicker(
                    "Birthday",
                    selection: $selection,
                    in: Calendar.current.date(byAdding: .year, value: -120, to: .now)! ... Date.now,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(TojTheme.accent)

                Text("Your birthday is shown to people you chat with.")
                    .font(.footnote)
                    .foregroundStyle(TojTheme.secondaryText)
                    .multilineTextAlignment(.center)

                if birthday != nil {
                    Button("Remove Birthday", role: .destructive) {
                        birthday = nil
                        dismiss()
                    }
                    .buttonStyle(.tojPressable)
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(TojTheme.canvas)
            .navigationTitle("Birthday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        birthday = selection
                        TojFeedback.selection()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct ProfileColorPicker: View {
    @Binding var selection: Int
    let displayName: String
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ProfileEditorAvatar(
                    displayName: displayName,
                    photoData: nil,
                    colorIndex: selection,
                    size: 92
                )
                .shadow(color: TojProfilePalette.primary(selection).opacity(0.24), radius: 22, y: 10)

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(0..<TojProfilePalette.count, id: \.self) { index in
                        Button {
                            withAnimation(TojTheme.microAnimation) { selection = index }
                            TojFeedback.selection()
                        } label: {
                            Circle()
                                .fill(TojProfilePalette.gradient(index))
                                .frame(width: 54, height: 54)
                                .overlay {
                                    if selection == index {
                                        Image(systemName: "checkmark")
                                            .font(.headline.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .overlay(Circle().stroke(Color.white.opacity(selection == index ? 0.7 : 0.12), lineWidth: selection == index ? 2 : 1))
                                .scaleEffect(selection == index ? 1.08 : 1)
                        }
                        .buttonStyle(.tojPressable(scale: 0.92))
                        .accessibilityLabel("Profile color \(index + 1)")
                        .accessibilityAddTraits(selection == index ? .isSelected : [])
                    }
                }
                Text("This color appears when you don’t have a profile photo.")
                    .font(.footnote)
                    .foregroundStyle(TojTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(TojTheme.canvas)
            .navigationTitle("Your Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private struct ProfilePhoneInfoView: View {
    let phone: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                SettingsIconTile(
                    systemImage: "phone.fill",
                    colors: [Color(hex: 0x58DF7D), Color(hex: 0x25B95A)],
                    size: 76
                )
                Text(phone)
                    .font(TojTheme.heading(.title2, weight: .bold))
                    .foregroundStyle(TojTheme.text)
                Text("Your phone number is your Toj identity. Changing it will require a verification code so your account stays protected.")
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Text("Number changes are coming in a future update.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TojTheme.accent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(TojTheme.canvas)
            .navigationTitle("Phone Number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

private enum ProfilePhotoProcessor {
    nonisolated static func preparedPhoto(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.84)
    }

}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
