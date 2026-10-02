import Contacts
import Observation
import SwiftUI
import UIKit

struct TojAddressBookContact: Identifiable, Codable, Equatable, Sendable {
    private let identifier: String
    let givenName: String
    let familyName: String
    let phoneNumbers: [String]
    let thumbnailData: Data?

    nonisolated var id: String { identifier }

    nonisolated init(
        id: String,
        givenName: String,
        familyName: String,
        phoneNumbers: [String],
        thumbnailData: Data?
    ) {
        identifier = id
        self.givenName = givenName
        self.familyName = familyName
        self.phoneNumbers = phoneNumbers
        self.thumbnailData = thumbnailData
    }

    nonisolated var fullName: String {
        let name = [givenName, familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? (phoneNumbers.first ?? String(localized: "Contact")) : name
    }

    nonisolated var primaryPhone: String { phoneNumbers.first ?? "" }

    nonisolated static func sorted(_ contacts: [Self]) -> [Self] {
        contacts.sorted { lhs, rhs in
            lhs.fullName.localizedStandardCompare(rhs.fullName) == .orderedAscending
        }
    }
}

@MainActor
@Observable
final class TojContactsStore {
    private static let savedContactsKey = "toj.saved-contacts.v1"
    enum Access: Equatable { case notDetermined, denied, authorized }

    private(set) var access: Access = .notDetermined
    private(set) var contacts: [TojAddressBookContact] = []
    private(set) var identitiesByPhone: [String: CloudAppModel.ContactIdentity] = [:]
    private(set) var checkedPhones: Set<String> = []
    private(set) var isLoading = false
    private(set) var isDiscovering = false
    private(set) var discoveryPaused = false
    private(set) var errorMessage: String?
    private var appContacts: [TojAddressBookContact]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedContactsKey),
           let saved = try? JSONDecoder().decode([TojAddressBookContact].self, from: data) {
            appContacts = saved
        } else {
            appContacts = []
        }
        refreshAuthorizationStatus()
    }

    var registeredContacts: [TojAddressBookContact] {
        contacts.filter { contact in
            contact.phoneNumbers.contains { identitiesByPhone[Self.normalized($0)] != nil }
        }
    }

    /// Only confirmed non-users are offered for invitation. Unchecked numbers stay out of both lists.
    var inviteContacts: [TojAddressBookContact] {
        contacts.filter { contact in
            let phones = contact.phoneNumbers.map(Self.normalized)
            return !phones.isEmpty
                && phones.allSatisfy(checkedPhones.contains)
                && phones.allSatisfy { identitiesByPhone[$0] == nil }
        }
    }

    func identity(for contact: TojAddressBookContact) -> CloudAppModel.ContactIdentity? {
        contact.phoneNumbers.lazy.compactMap { self.identitiesByPhone[Self.normalized($0)] }.first
    }

    func registeredPhone(for contact: TojAddressBookContact) -> String {
        contact.phoneNumbers.first { identitiesByPhone[Self.normalized($0)] != nil } ?? contact.primaryPhone
    }

    func record(identity: CloudAppModel.ContactIdentity?, phone: String) {
        let key = Self.normalized(phone)
        guard !key.isEmpty else { return }
        checkedPhones.insert(key)
        if let identity { identitiesByPhone[key] = identity }
    }

    func requestAndLoad() async {
        refreshAuthorizationStatus()
        if access == .notDetermined {
            do {
                access = try await CNContactStore().requestAccess(for: .contacts) ? .authorized : .denied
            } catch {
                access = .denied
                errorMessage = error.localizedDescription
            }
        }
        guard access == .authorized else { return }
        await loadContacts()
    }

    func loadContacts() async {
        guard access == .authorized, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let deviceContacts = try await Task.detached(priority: .userInitiated) {
                try Self.fetchContacts()
            }.value
            #if DEBUG
            let previewContacts = ProcessInfo.processInfo.environment["TOJ_DEMO_CONTACTS"] == "1"
                ? Self.previewContacts
                : []
            #else
            let previewContacts: [TojAddressBookContact] = []
            #endif
            contacts = Self.merged(deviceContacts: deviceContacts, appContacts: appContacts + previewContacts)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discover(using lookup: @escaping (String) async throws -> CloudAppModel.ContactIdentity?) async {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryPaused = false
        defer { isDiscovering = false }

        for phone in contacts.flatMap(\.phoneNumbers) {
            let key = Self.normalized(phone)
            guard !key.isEmpty, !checkedPhones.contains(key) else { continue }
            do {
                if let identity = try await lookup(phone) { identitiesByPhone[key] = identity }
                checkedPhones.insert(key)
            } catch {
                discoveryPaused = true
                break
            }
            guard !Task.isCancelled else { return }
        }
    }

    func addContact(givenName: String, familyName: String, phone: String, syncToPhone: Bool) async throws {
        let number = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return }
        if syncToPhone {
            try await Task.detached(priority: .userInitiated) {
                let contact = CNMutableContact()
                contact.givenName = givenName.trimmingCharacters(in: .whitespacesAndNewlines)
                contact.familyName = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
                contact.phoneNumbers = [
                    CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: number))
                ]
                let request = CNSaveRequest()
                request.add(contact, toContainerWithIdentifier: nil)
                try CNContactStore().execute(request)
            }.value
        }
        appContacts.removeAll { saved in
            saved.phoneNumbers.contains { Self.normalized($0) == Self.normalized(number) }
        }
        appContacts.append(TojAddressBookContact(
            id: "toj-\(UUID().uuidString)",
            givenName: givenName,
            familyName: familyName,
            phoneNumbers: [number],
            thumbnailData: nil
        ))
        if let data = try? JSONEncoder().encode(appContacts) {
            UserDefaults.standard.set(data, forKey: Self.savedContactsKey)
        }
        await loadContacts()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshAuthorizationStatus() {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: access = .notDetermined
        case .authorized, .limited: access = .authorized
        case .denied, .restricted: access = .denied
        @unknown default: access = .denied
        }
    }

    nonisolated private static func fetchContacts() throws -> [TojAddressBookContact] {
        let request = CNContactFetchRequest(keysToFetch: [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ])
        request.unifyResults = true
        var contacts: [TojAddressBookContact] = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            let phones = contact.phoneNumbers
                .map { $0.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !phones.isEmpty else { return }
            contacts.append(TojAddressBookContact(
                id: contact.identifier,
                givenName: contact.givenName,
                familyName: contact.familyName,
                phoneNumbers: Array(Set(phones)).sorted(),
                thumbnailData: contact.thumbnailImageData
            ))
        }
        return TojAddressBookContact.sorted(contacts)
    }

    nonisolated static func normalized(_ phone: String) -> String {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = phone.filter(\.isNumber)
        return trimmed.hasPrefix("+") ? "+\(digits)" : digits
    }

    nonisolated private static func merged(
        deviceContacts: [TojAddressBookContact],
        appContacts: [TojAddressBookContact]
    ) -> [TojAddressBookContact] {
        var result = deviceContacts
        var knownPhones = Set(deviceContacts.flatMap(\.phoneNumbers).map(normalized))
        for contact in appContacts {
            let phones = contact.phoneNumbers.map(normalized)
            guard !phones.contains(where: knownPhones.contains) else { continue }
            result.append(contact)
            knownPhones.formUnion(phones)
        }
        return TojAddressBookContact.sorted(result)
    }

    #if DEBUG
    nonisolated private static let previewContacts: [TojAddressBookContact] = [
        .init(id: "preview-1", givenName: "Азиз", familyName: "Раҳмонов", phoneNumbers: ["+992900000010"], thumbnailData: nil),
        .init(id: "preview-2", givenName: "Дилноза", familyName: "Каримова", phoneNumbers: ["+992900000012"], thumbnailData: nil),
        .init(id: "preview-3", givenName: "Фирӯз", familyName: "Саидов", phoneNumbers: ["+992900000014"], thumbnailData: nil),
        .init(id: "preview-4", givenName: "Madina", familyName: "Nazarova", phoneNumbers: ["+992900000011"], thumbnailData: nil),
        .init(id: "preview-5", givenName: "Mansur", familyName: "Kholov", phoneNumbers: ["+992900000013"], thumbnailData: nil),
        .init(id: "preview-6", givenName: "Zarina", familyName: "Yusufzoda", phoneNumbers: ["+992900000015"], thumbnailData: nil)
    ]
    #endif
}

struct CloudContactsView: View {
    @Bindable var model: CloudAppModel
    @Bindable var store: TojContactsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var path: [String] = []
    @State private var showingNewContact = false
    @State private var showingInviteFriends = false
    @State private var openingContactID: String?

    private var filteredContacts: [TojAddressBookContact] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.registeredContacts }
        return store.registeredContacts.filter {
            $0.fullName.localizedCaseInsensitiveContains(term)
                || $0.phoneNumbers.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.access == .authorized {
                        TojContactSearchField(placeholder: "Search contacts", text: $query)
                            .padding(.bottom, TojSpacing.sm)
                        inviteFriendsRow
                        contactContent
                    } else {
                        permissionState.padding(.top, 84)
                    }
                }
                .padding(.horizontal, TojSpacing.lg)
                .padding(.bottom, TojSpacing.xxl)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.14) : TojTheme.stateAnimation,
                    value: store.registeredContacts.map(\.id)
                )
            }
            .scrollDismissesKeyboard(.interactively)
            .background(TojTheme.canvas)
            .navigationTitle("Contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Contacts")
                        .font(TojTheme.heading(.headline, weight: .semibold))
                        .foregroundStyle(TojTheme.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewContact = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Add contact")
                }
            }
            .toolbarBackground(TojTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: String.self) { dialogID in
                TojConversationExperience(model: model, dialogId: dialogID)
            }
        }
        .task {
            await loadAndDiscover()
            #if DEBUG
            switch ProcessInfo.processInfo.environment["TOJ_DEMO_CONTACTS_SCREEN"] {
            case "new": showingNewContact = true
            case "invite": showingInviteFriends = true
            default: break
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await loadAndDiscover() }
        }
        .sheet(isPresented: $showingNewContact) {
            NewContactSheet(model: model, store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(isPresented: $showingInviteFriends) {
            InviteFriendsView(store: store)
        }
    }

    private var inviteFriendsRow: some View {
        Button { showingInviteFriends = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(TojTheme.accent)
                    .frame(width: 52, height: 52)
                    .background(TojTheme.gold.opacity(0.12), in: Circle())
                Text("Invite Friends")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(TojTheme.accent)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(TojTheme.tertiaryText)
            }
            .padding(.vertical, TojSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tojPressable)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 66)
        }
    }

    @ViewBuilder private var contactContent: some View {
        if store.isLoading {
            ProgressView().tint(TojTheme.text).padding(.top, 72)
        } else if filteredContacts.isEmpty {
            VStack(spacing: 13) {
                TojMark(size: 62)
                Text(query.isEmpty ? "No Toj contacts yet" : "No contacts found")
                    .font(TojTheme.heading(.title3))
                Text(query.isEmpty
                     ? "People from your address book who use Toj will appear here."
                     : "Try searching another name or phone number.")
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 290)
                if store.isDiscovering {
                    ProgressView("Finding people on Toj…")
                        .font(.caption)
                        .tint(TojTheme.accent)
                        .foregroundStyle(TojTheme.secondaryText)
                        .padding(.top, TojSpacing.xs)
                }
            }
            .padding(.top, 64)
        } else {
            ForEach(filteredContacts) { contact in
                Button { open(contact) } label: {
                    ContactRow(
                        contact: contact,
                        subtitle: store.identity(for: contact)?.displayName,
                        loading: openingContactID == contact.id
                    )
                }
                .buttonStyle(.tojPressable)
                .disabled(openingContactID != nil)
            }
        }
    }

    private var permissionState: some View {
        VStack(spacing: TojSpacing.lg) {
            TojMark(size: 72)
            Text(store.access == .denied ? "Contacts access is off" : "Find your people")
                .font(TojTheme.heading(.title2, weight: .bold))
            Text(store.access == .denied
                 ? "Allow Contacts access in Settings to find friends who use Toj."
                 : "Toj can securely check your address book for people you already know.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button(store.access == .denied ? "Open Settings" : "Continue") {
                if store.access == .denied { store.openSettings() }
                else { Task { await loadAndDiscover() } }
            }
            .font(.headline)
            .foregroundStyle(TojTheme.onAccent)
            .padding(.horizontal, TojSpacing.xl)
            .frame(height: 50)
            .background(TojTheme.accent, in: Capsule())
            .buttonStyle(.tojPressable)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadAndDiscover() async {
        await store.requestAndLoad()
        guard store.access == .authorized else { return }
        await store.discover { phone in try await model.contactIdentity(phone: phone) }
    }

    private func open(_ contact: TojAddressBookContact) {
        openingContactID = contact.id
        Task {
            if let dialogID = await model.openPeer(phone: store.registeredPhone(for: contact)) {
                TojFeedback.selection()
                path.append(dialogID)
            }
            openingContactID = nil
        }
    }
}

private struct TojContactSearchField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(TojTheme.secondaryText)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(TojTheme.secondaryText)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .foregroundStyle(TojTheme.text)
        .padding(.horizontal, TojSpacing.lg)
        .frame(height: 46)
        .tojGlass(in: Capsule(), interactive: true)
    }
}

private struct ContactAvatar: View {
    let contact: TojAddressBookContact
    var size: CGFloat = 52

    private var initials: String {
        let value = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return value.isEmpty ? "T" : value.uppercased()
    }

    var body: some View {
        Group {
            if let data = contact.thumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(LinearGradient(
                        colors: [Color(hex: 0x30343B), TojTheme.raised],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    Text(initials)
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(TojTheme.text)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct ContactRow: View {
    let contact: TojAddressBookContact
    let subtitle: String?
    var loading = false

    var body: some View {
        HStack(spacing: 13) {
            ContactAvatar(contact: contact)
            VStack(alignment: .leading, spacing: TojSpacing.xs) {
                Text(contact.fullName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(TojTheme.text)
                    .lineLimit(1)
                Text(subtitle == contact.fullName ? contact.primaryPhone : (subtitle ?? contact.primaryPhone))
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small).tint(TojTheme.text) }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 65)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens a conversation")
    }
}

private enum ContactCountry: String, CaseIterable, Identifiable {
    case tajikistan, uzbekistan, kyrgyzstan, kazakhstan, russia, unitedStates
    var id: String { rawValue }
    var details: (String, String, String) {
        switch self {
        case .tajikistan: ("🇹🇯", "Tajikistan", "+992")
        case .uzbekistan: ("🇺🇿", "Uzbekistan", "+998")
        case .kyrgyzstan: ("🇰🇬", "Kyrgyzstan", "+996")
        case .kazakhstan: ("🇰🇿", "Kazakhstan", "+7")
        case .russia: ("🇷🇺", "Russia", "+7")
        case .unitedStates: ("🇺🇸", "United States", "+1")
        }
    }
    var flag: String { details.0 }
    var name: String { details.1 }
    var dialCode: String { details.2 }
}

private struct NewContactSheet: View {
    @Bindable var model: CloudAppModel
    let store: TojContactsStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var phone = ""
    @State private var country = ContactCountry.tajikistan
    @State private var syncToPhone = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private enum Field { case firstName, lastName, phone }
    private var completePhone: String {
        let value = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("+") ? value : country.dialCode + value.filter(\.isNumber)
    }
    private var canSave: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && completePhone.filter(\.isNumber).count >= 8 && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    sheetHeader
                    nameFields
                    phoneFields
                    Toggle("Sync Contact to Phone", isOn: $syncToPhone)
                        .font(.body.weight(.medium))
                        .tint(TojTheme.accent)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 62)
                        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))
                    Button { TojFeedback.selection() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "qrcode.viewfinder").font(.title3)
                            Text("Add via QR Code").font(.body.weight(.semibold))
                            Spacer()
                            Text("Soon").font(.caption.weight(.semibold)).foregroundStyle(TojTheme.secondaryText)
                        }
                        .foregroundStyle(TojTheme.accent)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 62)
                        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card, style: .continuous))
                    }
                    .buttonStyle(.tojPressable)
                    if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }
                .padding(.horizontal, TojSpacing.lg)
                .padding(.bottom, TojSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(TojTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { focusedField = .firstName }
    }

    private var sheetHeader: some View {
        ZStack {
            Text("New Contact").font(TojTheme.heading(.title3, weight: .bold))
            HStack {
                TojGlassIconButton(systemImage: "xmark", accessibilityLabel: "Close") { dismiss() }
                Spacer()
                Button(action: save) {
                    Group {
                        if isSaving { ProgressView().tint(TojTheme.text) }
                        else { Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)) }
                    }
                    .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.42)
                .accessibilityLabel("Save contact")
            }
        }
        .padding(.top, TojSpacing.md)
        .padding(.bottom, 26)
    }

    private var nameFields: some View {
        VStack(spacing: 0) {
            TextField("First Name", text: $firstName)
                .focused($focusedField, equals: .firstName)
                .textContentType(.givenName)
                .submitLabel(.next)
                .onSubmit { focusedField = .lastName }
                .padding(.horizontal, 18).frame(height: 58)
            Rectangle().fill(TojTheme.hairlineStrong).frame(height: 0.5).padding(.leading, 18)
            TextField("Last Name", text: $lastName)
                .focused($focusedField, equals: .lastName)
                .textContentType(.familyName)
                .submitLabel(.next)
                .onSubmit { focusedField = .phone }
                .padding(.horizontal, 18).frame(height: 58)
        }
        .font(.body.weight(.medium))
        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.cardLarge, style: .continuous))
    }

    private var phoneFields: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach(ContactCountry.allCases) { item in
                    Button { country = item } label: { Text("\(item.flag)  \(item.name)  \(item.dialCode)") }
                }
            } label: {
                HStack {
                    Text("\(country.flag)  \(country.name)").font(.body.weight(.medium)).foregroundStyle(TojTheme.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(TojTheme.secondaryText)
                }
                .padding(.horizontal, 18).frame(height: 58).contentShape(Rectangle())
            }
            Rectangle().fill(TojTheme.hairlineStrong).frame(height: 0.5).padding(.leading, 18)
            HStack(spacing: TojSpacing.md) {
                Text(country.dialCode)
                Rectangle().fill(TojTheme.hairlineStrong).frame(width: 0.5, height: 28)
                TextField("Phone number", text: $phone)
                    .focused($focusedField, equals: .phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 18).frame(height: 58)
        }
        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.cardLarge, style: .continuous))
    }

    private func save() {
        guard canSave else { return }
        focusedField = nil
        isSaving = true
        Task {
            do {
                try await store.addContact(
                    givenName: firstName,
                    familyName: lastName,
                    phone: completePhone,
                    syncToPhone: syncToPhone
                )
                let identity = try? await model.contactIdentity(phone: completePhone)
                store.record(identity: identity, phone: completePhone)
                TojFeedback.sent()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct InviteFriendsView: View {
    let store: TojContactsStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: Set<String> = []

    private var filteredContacts: [TojAddressBookContact] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.inviteContacts }
        return store.inviteContacts.filter {
            $0.fullName.localizedCaseInsensitiveContains(term)
                || $0.phoneNumbers.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
    private var allSelected: Bool {
        !filteredContacts.isEmpty && filteredContacts.allSatisfy { selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    TojContactSearchField(placeholder: "Search contacts", text: $query).padding(.bottom, TojSpacing.md)
                    shareToj
                    if filteredContacts.isEmpty {
                        emptyState.padding(.top, 70)
                    } else {
                        Text("CONTACTS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TojTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 18).padding(.bottom, TojSpacing.sm)
                        ForEach(filteredContacts) { selectionRow($0) }
                    }
                }
                .padding(.horizontal, TojSpacing.lg)
                .padding(.bottom, 42)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(TojTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        ZStack {
            Text("Invite Friends").font(TojTheme.heading(.title3, weight: .bold))
            HStack {
                TojGlassIconButton(systemImage: "xmark", accessibilityLabel: "Close") { dismiss() }
                Spacer()
                Button(allSelected ? "Deselect All" : "Select All") {
                    withAnimation(TojTheme.microAnimation) {
                        if allSelected { selected.subtract(filteredContacts.map(\.id)) }
                        else { selected.formUnion(filteredContacts.map(\.id)) }
                    }
                    TojFeedback.selection()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TojTheme.text)
                .padding(.horizontal, TojSpacing.lg)
                .frame(height: 46)
                .tojGlass(in: Capsule(), interactive: true)
                .buttonStyle(.tojPressable)
            }
        }
        .padding(.top, TojSpacing.md).padding(.bottom, 18)
    }

    private var shareToj: some View {
        Button { TojFeedback.selection() } label: {
            HStack(spacing: 14) {
                Image(systemName: "heart").font(.system(size: 22, weight: .semibold)).frame(width: 52, height: 52)
                Text("Share Toj").font(.body.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(TojTheme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tojPressable)
        .accessibilityHint("Sharing will be available soon")
    }

    private func selectionRow(_ contact: TojAddressBookContact) -> some View {
        let isSelected = selected.contains(contact.id)
        return Button {
            if isSelected { selected.remove(contact.id) } else { selected.insert(contact.id) }
            TojFeedback.selection()
        } label: {
            HStack(spacing: 13) {
                ContactAvatar(contact: contact)
                VStack(alignment: .leading, spacing: TojSpacing.xs) {
                    Text(contact.fullName).font(.body.weight(.semibold)).foregroundStyle(TojTheme.text)
                    Text(contact.primaryPhone).font(.subheadline).foregroundStyle(TojTheme.secondaryText)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isSelected ? TojTheme.accent : TojTheme.tertiaryText)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 9).contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 65)
            }
        }
        .buttonStyle(.tojPressable)
        .accessibilityLabel("\(contact.fullName), \(isSelected ? "selected" : "not selected")")
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "person.2")
                .font(.system(size: 36, weight: .medium)).foregroundStyle(TojTheme.secondaryText)
            Text(query.isEmpty ? "No invite contacts yet" : "No contacts found")
                .font(TojTheme.heading(.title3))
            Text(query.isEmpty
                 ? (store.discoveryPaused
                    ? "Contact discovery will continue automatically later."
                    : "Friends who are not on Toj will appear here after contact discovery.")
                 : "Try searching another name or phone number.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
        .frame(maxWidth: .infinity)
    }
}
