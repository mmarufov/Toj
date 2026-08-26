import PhotosUI
import SwiftUI

struct GroupCreationView: View {
    @Bindable var model: CloudAppModel
    @Bindable var store: TojContactsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccountIds: Set<String> = []
    @State private var query = ""
    @State private var title = ""
    @State private var step = 0
    @State private var creating = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?

    let onCreated: (String) -> Void

    private var contacts: [TojAddressBookContact] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return store.registeredContacts }
        return store.registeredContacts.filter {
            $0.fullName.localizedCaseInsensitiveContains(term)
                || $0.phoneNumbers.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 { memberSelection } else { groupDetails }
            }
            .background(TojTheme.canvas)
            .navigationTitle(step == 0 ? "New group" : "Group details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step == 0 ? "Next" : "Create") {
                        if step == 0 {
                            step = 1
                        } else {
                            create()
                        }
                    }
                    .disabled(
                        creating
                            || (step == 0
                                ? selectedAccountIds.isEmpty
                                : title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
        }
        .task {
            await store.requestAndLoad()
            guard store.access == .authorized else { return }
            await store.discover { phone in try await model.contactIdentity(phone: phone) }
        }
    }

    private var memberSelection: some View {
        VStack(spacing: 0) {
            TextField("Search contacts", text: $query)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(TojTheme.raised, in: Capsule())
                .padding()

            if store.access == .denied {
                ContentUnavailableView(
                    "Contacts access is off",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Enable Contacts access in Settings to choose group members.")
                )
            } else if store.isLoading || store.isDiscovering {
                ProgressView("Finding Toj contacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if contacts.isEmpty {
                ContentUnavailableView(
                    "No Toj contacts",
                    systemImage: "person.3",
                    description: Text("Registered contacts will appear here.")
                )
            } else {
                List(contacts) { contact in
                    if let identity = store.identity(for: contact) {
                        Button {
                            if selectedAccountIds.contains(identity.accountId) {
                                selectedAccountIds.remove(identity.accountId)
                            } else if selectedAccountIds.count < 199 {
                                selectedAccountIds.insert(identity.accountId)
                            }
                            TojFeedback.selection()
                        } label: {
                            HStack(spacing: 12) {
                                TojAvatar(title: contact.fullName, size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contact.fullName)
                                        .foregroundStyle(TojTheme.text)
                                    Text(store.registeredPhone(for: contact))
                                        .font(.caption)
                                        .foregroundStyle(TojTheme.secondaryText)
                                }
                                Spacer()
                                Image(
                                    systemName: selectedAccountIds.contains(identity.accountId)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .font(.title3)
                                .foregroundStyle(
                                    selectedAccountIds.contains(identity.accountId)
                                        ? TojTheme.accent : TojTheme.secondaryText
                                )
                            }
                        }
                        .listRowBackground(TojTheme.raised)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var groupDetails: some View {
        let hasPhoto = photoData != nil
        return VStack(spacing: 22) {
            GroupPhotoPreview(
                data: photoData,
                title: title.isEmpty ? String(localized: "Group") : title,
                size: 88
            )
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(hasPhoto ? "Change group photo" : "Add group photo", systemImage: "photo")
            }
            .onChange(of: photoItem) { _, item in
                Task { photoData = try? await item?.loadTransferable(type: Data.self) }
            }
            TextField("Group name", text: $title)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(TojTheme.raised, in: Capsule())
                .onChange(of: title) { _, newValue in
                    if newValue.count > 128 { title = String(newValue.prefix(128)) }
                }
            Text("\(selectedAccountIds.count) members selected")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
            if creating {
                ProgressView("Creating group…")
            }
            Spacer()
        }
        .padding(22)
    }

    private func create() {
        guard !creating else { return }
        creating = true
        Task {
            if let dialogId = await model.createGroup(
                title: title,
                memberIds: Array(selectedAccountIds),
                photoData: photoData
            ) {
                TojFeedback.sent()
                onCreated(dialogId)
            } else {
                creating = false
            }
        }
    }
}

struct GroupProfileView: View {
    @Bindable var model: CloudAppModel
    let dialogId: String
    @Environment(\.dismiss) private var dismiss
    @State private var editingTitle = false
    @State private var title = ""
    @State private var confirmingLeave = false
    @State private var showingAddMembers = false
    @State private var showingPermissions = false
    @State private var photoItem: PhotosPickerItem?
    @State private var selectedPhotoData: Data?

    private var dialog: CloudAppModel.Dialog? {
        model.dialogs.first { $0.id == dialogId }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    GroupPhotoView(
                        model: model,
                        media: dialog?.photo,
                        optimisticData: selectedPhotoData,
                        title: dialog?.title ?? String(localized: "Group"),
                        size: 84
                    )
                    Text(dialog?.title ?? String(localized: "Group"))
                        .font(TojTheme.heading(.title2, weight: .bold))
                    Text("\(dialog?.memberCount ?? 0) members")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(TojTheme.canvas)
            }

            if dialog?.accessState == "pending" {
                Section {
                    Label("Waiting to create", systemImage: "arrow.triangle.2.circlepath")
                    Button("Retry creation") {
                        Task { await model.retryGroupCreation(dialogId: dialogId) }
                    }
                }
            }

            Section("Message privacy") {
                Label(
                    CloudChatPrivacyPresentation.detail,
                    systemImage: CloudChatPrivacyPresentation.systemImage
                )
                    .foregroundStyle(TojTheme.secondaryText)
                Text(CloudChatPrivacyPresentation.disclosure)
                    .font(.footnote)
                    .foregroundStyle(TojTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(CloudChatPrivacyPresentation.accessibilityLabel)

            Section("Members") {
                if dialog?.selfRole == "owner" || dialog?.selfRole == "admin" {
                    Button {
                        showingAddMembers = true
                    } label: {
                        Label("Add members", systemImage: "person.badge.plus")
                    }
                }
                ForEach(model.groupMembersByDialog[dialogId] ?? []) { member in
                    HStack(spacing: 12) {
                        CloudProfileAvatar(
                            model: model,
                            title: member.displayName,
                            media: member.photo,
                            size: 40
                        )
                        Text(member.displayName)
                        Spacer()
                        if member.role != "member" {
                            Text(member.role.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                    }
                    .contextMenu {
                        memberActions(member)
                    }
                }
            }

            Section {
                Toggle(
                    "Mute notifications",
                    isOn: Binding(
                        get: { dialog?.isMuted == true },
                        set: { muted in
                            model.setGroupMuted(dialogId: dialogId, muted: muted)
                        }
                    )
                )
                .disabled(
                    !model.capabilities.contains(.chatOrganization)
                        && !model.capabilities.contains(.groups)
                )
                if dialog?.selfRole == "owner" || dialog?.selfRole == "admin" {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Change group photo", systemImage: "photo")
                    }
                    Button("Edit group name") {
                        title = dialog?.title ?? ""
                        editingTitle = true
                    }
                    Button("Group permissions") {
                        showingPermissions = true
                    }
                }
            }

            Section {
                Button("Leave group", role: .destructive) {
                    confirmingLeave = true
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TojTheme.canvas)
        .navigationTitle("Group info")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadGroupProfile(dialogId: dialogId) }
        .onChange(of: photoItem) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                selectedPhotoData = data
                _ = await model.updateGroupPhoto(dialogId: dialogId, data: data)
            }
        }
        .alert("Edit group name", isPresented: $editingTitle) {
            TextField("Group name", text: $title)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { _ = await model.updateGroupTitle(dialogId: dialogId, title: title) }
            }
        }
        .confirmationDialog("Leave this group?", isPresented: $confirmingLeave) {
            Button("Leave group", role: .destructive) {
                Task {
                    if await model.leaveGroup(dialogId: dialogId) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingAddMembers) {
            GroupMemberPickerView(
                model: model,
                dialogId: dialogId,
                excludedAccountIds: Set(
                    (model.groupMembersByDialog[dialogId] ?? []).map(\.accountId)
                )
            ) {
                showingAddMembers = false
            }
        }
        .sheet(isPresented: $showingPermissions) {
            GroupPermissionsView(
                model: model,
                dialogId: dialogId,
                initial: model.groupPermissionsByDialog[dialogId] ?? .init()
            )
        }
    }

    @ViewBuilder
    private func memberActions(_ member: CloudAppModel.GroupMember) -> some View {
        let selfAccountId = model.storedSession?.session.accountId
        if member.accountId != selfAccountId, dialog?.selfRole == "owner" {
            Button(member.role == "admin" ? "Make member" : "Make admin") {
                Task {
                    _ = await model.changeGroupMemberRole(
                        dialogId: dialogId,
                        accountId: member.accountId,
                        role: member.role == "admin" ? "member" : "admin"
                    )
                }
            }
            Button("Transfer ownership") {
                Task {
                    _ = await model.transferGroupOwnership(
                        dialogId: dialogId,
                        accountId: member.accountId
                    )
                }
            }
        }
        if member.accountId != selfAccountId,
           dialog?.selfRole == "owner"
            || (dialog?.selfRole == "admin" && member.role == "member") {
            Button("Remove member", role: .destructive) {
                Task {
                    _ = await model.removeGroupMember(
                        dialogId: dialogId,
                        accountId: member.accountId
                    )
                }
            }
        }
    }
}

private struct GroupPermissionsView: View {
    @Bindable var model: CloudAppModel
    let dialogId: String
    @State var initial: CloudAppModel.GroupPermissions
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Members can") {
                    Toggle("Send messages", isOn: $initial.membersCanSend)
                    Toggle("Add members", isOn: $initial.membersCanAddMembers)
                    Toggle("Change group info", isOn: $initial.membersCanEditInfo)
                }
                Section {
                    Text("Owners and administrators always keep these permissions. Changes are enforced by the server on every device.")
                        .font(.footnote)
                        .foregroundStyle(TojTheme.secondaryText)
                }
            }
            .scrollContentBackground(.hidden)
            .background(TojTheme.canvas)
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            if await model.updateGroupPermissions(dialogId: dialogId, permissions: initial) {
                                dismiss()
                            }
                            saving = false
                        }
                    }
                    .disabled(saving)
                }
            }
        }
    }
}

private struct GroupPhotoPreview: View {
    let data: Data?
    let title: String
    let size: CGFloat

    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityLabel("Selected group photo")
        } else {
            TojAvatar(title: title, size: size)
        }
    }
}

private struct GroupPhotoView: View {
    @Bindable var model: CloudAppModel
    let media: CloudMedia?
    let optimisticData: Data?
    let title: String
    let size: CGFloat
    @State private var remoteData: Data?

    var body: some View {
        GroupPhotoPreview(
            data: optimisticData ?? remoteData,
            title: title,
            size: size
        )
        .task(id: media?.id) {
            guard optimisticData == nil, let media else {
                remoteData = nil
                return
            }
            remoteData = await model.thumbnailData(for: media)
        }
    }
}

private struct GroupMemberPickerView: View {
    @Bindable var model: CloudAppModel
    let dialogId: String
    let excludedAccountIds: Set<String>
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = TojContactsStore()
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var adding = false

    private var contacts: [(TojAddressBookContact, CloudAppModel.ContactIdentity)] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.registeredContacts.compactMap { contact in
            guard let identity = store.identity(for: contact),
                  !excludedAccountIds.contains(identity.accountId),
                  term.isEmpty
                    || contact.fullName.localizedCaseInsensitiveContains(term)
                    || contact.primaryPhone.localizedCaseInsensitiveContains(term)
            else { return nil }
            return (contact, identity)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                TextField("Search contacts", text: $query)
                ForEach(contacts, id: \.0.id) { contact, identity in
                    Button {
                        if selected.contains(identity.accountId) {
                            selected.remove(identity.accountId)
                        } else {
                            selected.insert(identity.accountId)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            TojAvatar(title: contact.fullName, size: 42)
                            Text(contact.fullName)
                            Spacer()
                            Image(
                                systemName: selected.contains(identity.accountId)
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(
                                selected.contains(identity.accountId)
                                    ? TojTheme.accent : TojTheme.secondaryText
                            )
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(TojTheme.canvas)
            .navigationTitle("Add members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        adding = true
                        Task {
                            if await model.addGroupMembers(
                                dialogId: dialogId,
                                accountIds: Array(selected)
                            ) {
                                onDone()
                                dismiss()
                            } else {
                                adding = false
                            }
                        }
                    }
                    .disabled(selected.isEmpty || adding)
                }
            }
        }
        .task {
            await store.requestAndLoad()
            guard store.access == .authorized else { return }
            await store.discover { phone in try await model.contactIdentity(phone: phone) }
        }
    }
}
