import SwiftUI

struct AbuseReportSheet: View {
    enum SubjectKind: Equatable, Sendable {
        case account
        case message
    }

    @Environment(\.dismiss) private var dismiss
    @State private var draft = AbuseReportDraft()
    @State private var clientReportId = UUID()
    @State private var isSubmitting = false
    @State private var isSubmitted = false
    @State private var isBlocking = false
    @State private var showingBlockConfirmation = false
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var blockTask: Task<Void, Never>?

    let subjectKind: SubjectKind
    let submit: (AbuseReportReason, String?, UUID) async -> AbuseReportSubmissionResult
    var blockAccount: (() async -> Bool)?

    var body: some View {
        NavigationStack {
            Group {
                if isSubmitted {
                    submittedContent
                } else {
                    reportForm
                }
            }
            .navigationTitle(
                isSubmitted ? String(localized: "Report received") : String(localized: "Report")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        isSubmitted ? String(localized: "Done") : String(localized: "Cancel")
                    ) { dismiss() }
                        .disabled(isSubmitting)
                }
                if !isSubmitted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { startSubmission() }
                            .fontWeight(.semibold)
                            .disabled(isSubmitting || draft.validationMessage != nil)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
            blockTask?.cancel()
            blockTask = nil
        }
        .confirmationDialog(
            "Block this account after submitting the report?",
            isPresented: $showingBlockConfirmation,
            titleVisibility: .visible
        ) {
            Button("Block account", role: .destructive) { startBlocking() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Blocking is a separate action. Your submitted report will remain received even if blocking fails.")
        }
    }

    private var reportForm: some View {
        Form {
            Section("Reason") {
                Picker("Reason", selection: $draft.reason) {
                    ForEach(AbuseReportReason.allCases) { reason in
                        Text(reason.title).tag(reason)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                TextEditor(text: $draft.details)
                    .frame(minHeight: 110)
                    .accessibilityLabel("Additional details")
                HStack {
                    if let validation = draft.validationMessage {
                        Text(validation).foregroundStyle(.red)
                    }
                    Spacer()
                    Text("\(draft.details.unicodeScalars.count)/500")
                        .monospacedDigit()
                        .foregroundStyle(
                            draft.details.unicodeScalars.count > 500 ? .red : TojTheme.secondaryText
                        )
                }
                .font(.caption)
            } header: {
                Text("Additional details")
            } footer: {
                Text("Toj will securely include a bounded snapshot of recent conversation context. Full media files are never attached to a report.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("report-error")
                    Button("Try Again") { startSubmission() }
                        .disabled(isSubmitting || draft.validationMessage != nil)
                }
            }

            if isSubmitting {
                Section {
                    HStack {
                        ProgressView()
                        Text("Sending report…")
                    }
                    .accessibilityIdentifier("report-submitting")
                }
            }
        }
    }

    private var submittedContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(TojTheme.secure)
            Text("Your report was submitted")
                .font(TojTheme.heading(.title2, weight: .bold))
            Text("A safety reviewer can now examine the encrypted evidence snapshot.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)

            if subjectKind == .account, blockAccount != nil {
                Button("Block account", role: .destructive) {
                    showingBlockConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBlocking)
                .accessibilityHint("Blocking is confirmed separately and does not change the submitted report.")

                if isBlocking {
                    ProgressView("Blocking account…")
                        .accessibilityIdentifier("report-blocking")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
        .accessibilityIdentifier("report-submitted")
    }

    private func startSubmission() {
        guard !isSubmitting, draft.validationMessage == nil else { return }
        isSubmitting = true
        errorMessage = nil
        let reason = draft.reason
        let details = draft.normalizedDetails
        let reportId = clientReportId
        submissionTask = Task {
            let result = await submit(reason, details, reportId)
            guard !Task.isCancelled else { return }
            isSubmitting = false
            switch result {
            case .submitted:
                isSubmitted = true
            case let .failed(message):
                errorMessage = message
            case .cancelled:
                break
            }
        }
    }

    private func startBlocking() {
        guard !isBlocking, let blockAccount else { return }
        isBlocking = true
        errorMessage = nil
        blockTask = Task {
            let blocked = await blockAccount()
            guard !Task.isCancelled else { return }
            isBlocking = false
            if blocked {
                dismiss()
            } else {
                errorMessage = String(
                    localized: "The report was submitted, but the account could not be blocked."
                )
            }
        }
    }
}
