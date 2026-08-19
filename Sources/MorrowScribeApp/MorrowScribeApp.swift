import AppKit
import MorrowScribeCore
import SwiftUI

@main
struct MorrowScribeDesktopApp: App {
    @StateObject private var model = ScribeViewModel()

    var body: some Scene {
        WindowGroup("Morrow Scribe") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        model.refreshLiveState()
                    }
                }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
final class ScribeViewModel: ObservableObject {
    @Published var meetings: [SavedMeeting] = []
    @Published var selectedMeetingID: String?
    @Published var meetingTitle = "Meeting"
    @Published var isTranscribing = false
    @Published var isStopping = false
    @Published var isSummarizing = false
    @Published var isTranslatingSummary = false
    @Published var summaryLanguage: SummaryLanguage = .english
    @Published var statusText = "Ready"
    @Published var errorText: String?
    @Published var detailTab: DetailTab = .transcript
    @Published var accessibilityTrusted = SlackAXSession().accessibilityTrusted
    @Published var llmConfiguration = SummaryConfigurationStore.load()

    private var collectorControl: CollectorControl?
    private var recordingStatus: RecordingStatus?
    private var activeMeetingDirectory: URL?
    private var summaryTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case summary = "Summary"
        var id: String { rawValue }
    }

    init() {
        refreshLibraryKeepingSelection()
    }

    var selectedMeeting: SavedMeeting? {
        guard let selectedMeetingID else { return nil }
        return meetings.first { $0.id == selectedMeetingID }
    }

    var llmConfigured: Bool { llmConfiguration.isConfigured }

    func refreshLibraryKeepingSelection() {
        let trusted = SlackAXSession().accessibilityTrusted
        if accessibilityTrusted != trusted { accessibilityTrusted = trusted }
        if isTranscribing, !isStopping, let recordingStatus {
            let currentStatus = recordingStatus.current
            if statusText != currentStatus { statusText = currentStatus }
        }
        let selected = selectedMeetingID
        let activePath = activeMeetingDirectory?.path
        do {
            let loaded = try MeetingLibrary.loadAll()
            if meetings != loaded { meetings = loaded }
            if let activePath, meetings.contains(where: { $0.id == activePath }) {
                selectedMeetingID = activePath
            } else if let selected, meetings.contains(where: { $0.id == selected }) {
                selectedMeetingID = selected
            } else {
                selectedMeetingID = meetings.first?.id
            }
        } catch {
            errorText = "Could not read meetings: \(error)"
        }
    }

    func refreshLiveState() {
        let trusted = SlackAXSession().accessibilityTrusted
        if accessibilityTrusted != trusted { accessibilityTrusted = trusted }

        if isTranscribing, !isStopping, let recordingStatus {
            let currentStatus = recordingStatus.current
            if statusText != currentStatus { statusText = currentStatus }
        }

        guard let directory = activeMeetingDirectory else { return }
        do {
            guard let refreshed = try MeetingLibrary.loadMeeting(at: directory) else {
                refreshLibraryKeepingSelection()
                return
            }
            if let index = meetings.firstIndex(where: { $0.id == refreshed.id }) {
                if meetings[index] != refreshed {
                    meetings[index] = refreshed
                }
            } else {
                refreshLibraryKeepingSelection()
            }
        } catch {
            errorText = "Could not refresh active meeting: \(error)"
        }
    }


    func requestAccessibility() {
        _ = SlackAXSession.requestAccessibilityAccess()
        accessibilityTrusted = SlackAXSession().accessibilityTrusted
        statusText = accessibilityTrusted ? "Accessibility enabled" : "Waiting for Accessibility permission"
    }

    func startTranscription() {
        guard !isTranscribing else { return }
        errorText = nil
        accessibilityTrusted = SlackAXSession().accessibilityTrusted
        guard accessibilityTrusted else {
            errorText = "Morrow Scribe needs macOS Accessibility access to read meeting captions. Use Request Access, then enable Morrow Scribe in System Settings → Privacy & Security → Accessibility."
            return
        }
        do {
            let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Meeting"
                : meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let store = try MeetingStore(title: title)
            let control = CollectorControl()
            let runtimeStatus = RecordingStatus("Listening for meetings: Slack")
            collectorControl = control
            recordingStatus = runtimeStatus
            activeMeetingDirectory = store.directory
            isTranscribing = true
            isStopping = false
            statusText = runtimeStatus.current
            refreshLibraryKeepingSelection()

            Task { [weak self] in
                let errorMessage = await Task.detached { () -> String? in
                    let recording = RecordingSession(
                        store: store,
                        providers: RecordingProviderCatalog.defaultProviders(),
                        control: control,
                        options: CollectorOptions(pollInterval: 0.25, learnMode: false, monitorInterval: 0.75)
                    )
                    do {
                        try recording.run { runtimeStatus.update($0) }
                        return nil
                    } catch {
                        return String(describing: error)
                    }
                }.value

                guard let self else { return }
                self.collectorControl = nil
                self.recordingStatus = nil
                self.activeMeetingDirectory = nil
                self.isTranscribing = false
                self.isStopping = false
                if let errorMessage {
                    self.statusText = "Recording stopped with an error"
                    self.errorText = errorMessage
                } else {
                    self.statusText = "Recording saved"
                }
                self.refreshLibraryKeepingSelection()
            }
        } catch {
            errorText = String(describing: error)
            statusText = "Could not start recording"
        }
    }

    func stopTranscription() {
        guard isTranscribing, !isStopping else { return }
        isStopping = true
        statusText = "Finishing recording…"
        collectorControl?.stop()
    }

    func revealSelectedMeeting() {
        guard let directory = selectedMeeting?.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func canModifyMeeting(_ meeting: SavedMeeting) -> Bool {
        meeting.directory.standardizedFileURL != activeMeetingDirectory?.standardizedFileURL
    }

    func renameMeeting(_ meeting: SavedMeeting, to title: String) {
        guard canModifyMeeting(meeting) else {
            errorText = "Stop the active transcription before renaming this meeting."
            return
        }
        do {
            let newDirectory = try MeetingLibrary.renameMeeting(at: meeting.directory, to: title)
            if selectedMeetingID == meeting.id {
                selectedMeetingID = newDirectory.path
            }
            statusText = "Meeting renamed"
            refreshLibraryKeepingSelection()
            selectedMeetingID = newDirectory.path
        } catch {
            errorText = "Could not rename meeting: \(error)"
        }
    }

    func deleteMeeting(_ meeting: SavedMeeting) {
        guard canModifyMeeting(meeting) else {
            errorText = "Stop the active transcription before deleting this meeting."
            return
        }
        do {
            let wasSelected = selectedMeetingID == meeting.id
            try MeetingLibrary.deleteMeeting(at: meeting.directory)
            if wasSelected { selectedMeetingID = nil }
            statusText = "Meeting deleted"
            refreshLibraryKeepingSelection()
        } catch {
            errorText = "Could not delete meeting: \(error)"
        }
    }

    func summarize(_ meeting: SavedMeeting) {
        startSummary(directory: meeting.directory)
    }

    func translateSummaryToChinese(_ meeting: SavedMeeting) {
        guard let summary = meeting.structuredSummary,
              translationTask == nil,
              summaryTask == nil else { return }
        isTranslatingSummary = true
        errorText = nil
        statusText = meeting.chineseSummary == nil ? "Translating summary…" : "Retranslating summary…"
        let configuration = llmConfiguration
        let directory = meeting.directory
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let translated = try await SummaryTranslator.translateToSimplifiedChinese(
                    summary,
                    configuration: configuration
                )
                try Task.checkCancellation()
                try MeetingExport.writeChineseSummary(translated, to: directory)
                self.statusText = "Chinese summary saved"
                self.refreshLibraryKeepingSelection()
                self.selectedMeetingID = directory.path
                self.detailTab = .summary
                self.summaryLanguage = .simplifiedChinese
            } catch is CancellationError {
                self.errorText = nil
                self.statusText = "Summary translation stopped"
            } catch {
                self.errorText = String(describing: error)
                self.statusText = "Summary translation failed"
            }
            self.translationTask = nil
            self.isTranslatingSummary = false
        }
    }

    func cancelSummary() {
        guard let summaryTask else { return }
        statusText = "Stopping summary…"
        summaryTask.cancel()
    }

    func cancelSummaryTranslation() {
        guard let translationTask else { return }
        statusText = "Stopping translation…"
        translationTask.cancel()
    }

    func saveLLMConfiguration(_ configuration: SummaryConfiguration) -> Bool {
        do {
            try SummaryConfigurationStore.save(configuration)
            llmConfiguration = SummaryConfigurationStore.load()
            statusText = llmConfigured ? "Summary settings saved" : "Summary provider is not configured"
            return true
        } catch {
            errorText = "Could not save summary settings: \(error)"
            return false
        }
    }

    private func startSummary(directory: URL) {
        guard summaryTask == nil, translationTask == nil else { return }
        isSummarizing = true
        errorText = nil
        statusText = "Generating summary…"
        let configuration = llmConfiguration
        summaryTask = Task { [weak self] in
            guard let self else { return }
            await self.runSummary(directory: directory, configuration: configuration)
            self.summaryTask = nil
            self.isSummarizing = false
        }
    }

    private func runSummary(directory: URL, configuration: SummaryConfiguration) async {
        do {
            try Task.checkCancellation()
            let entries = try MeetingExport.transcriptEntries(in: directory)
            guard !entries.isEmpty else {
                errorText = "This meeting has no transcript yet."
                statusText = "No transcript to summarize"
                return
            }
            let summary = try await SummaryClient.summarize(entries: entries, configuration: configuration)
            try Task.checkCancellation()
            try MeetingExport.writeSummary(summary, to: directory)
            statusText = "Summary saved"
            summaryLanguage = .english
            refreshLibraryKeepingSelection()
            selectedMeetingID = directory.path
            detailTab = .summary
        } catch is CancellationError {
            errorText = nil
            statusText = "Summary stopped"
        } catch {
            errorText = String(describing: error)
            statusText = "Summary failed"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: ScribeViewModel
    @State private var renameMeetingID: String?
    @State private var renameTitle = ""
    @State private var deleteMeetingID: String?
    @State private var showRenameSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showRegenerateSummaryConfirmation = false
    @State private var regenerateMeetingID: String?
    @State private var showLLMSettings = false
    @State private var markdownPreviewEnabled = false
    @State private var summaryPresentationMode: SummaryPresentationMode = .concise

    var body: some View {
        NavigationSplitView {
            meetingSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
        .alert("Morrow Scribe", isPresented: Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } }
        )) {
            Button("OK") { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(isPresented: $showLLMSettings) {
            LLMSettingsView(
                initialConfiguration: model.llmConfiguration,
                onSave: { configuration in
                    if model.saveLLMConfiguration(configuration) {
                        showLLMSettings = false
                    }
                },
                onCancel: { showLLMSettings = false }
            )
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                if let meeting = meeting(withID: deleteMeetingID) {
                    model.deleteMeeting(meeting)
                }
                deleteMeetingID = nil
            }
            Button("Cancel", role: .cancel) {
                deleteMeetingID = nil
            }
        } message: {
            Text("This permanently removes the meeting directory, transcript, summary, and diagnostic files.")
        }
        .confirmationDialog(
            "Replace existing summary?",
            isPresented: $showRegenerateSummaryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Regenerate Summary", role: .destructive) {
                if let meeting = meeting(withID: regenerateMeetingID) {
                    model.summarize(meeting)
                }
                regenerateMeetingID = nil
            }
            Button("Cancel", role: .cancel) {
                regenerateMeetingID = nil
            }
        } message: {
            Text("This meeting already has a summary. Regenerating will replace the existing summary files.")
        }
    }

    private var meetingSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Meetings")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshLibraryKeepingSelection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh meetings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            List(model.meetings, selection: $model.selectedMeetingID) { meeting in
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.metadata.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(meeting.metadata.startedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !meeting.metadata.participants.isEmpty {
                        Text(meeting.metadata.participants.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
                .tag(meeting.id)
                .contextMenu {
                    Button {
                        renameMeetingID = meeting.id
                        renameTitle = meeting.metadata.title
                        showRenameSheet = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .disabled(!model.canModifyMeeting(meeting))

                    Divider()

                    Button(role: .destructive) {
                        deleteMeetingID = meeting.id
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!model.canModifyMeeting(meeting))
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let meeting = model.selectedMeeting {
            VStack(spacing: 0) {
                meetingHeader(meeting)
                Divider()
                HStack(spacing: 12) {
                    Picker("Content", selection: $model.detailTab) {
                        ForEach(ScribeViewModel.DetailTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    .layoutPriority(2)

                    Spacer(minLength: 8)

                    if model.detailTab == .summary, meeting.structuredSummary != nil {
                        Picker("Summary detail", selection: $summaryPresentationMode) {
                            ForEach(SummaryPresentationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 160)
                        .layoutPriority(1)
                        .help("Concise shows outcomes, decisions, actions, and unresolved questions. Detailed adds risks, next steps, technical sections, and source warnings.")
                    }

                    if model.detailTab == .summary, meeting.structuredSummary != nil {
                        Picker("Summary language", selection: summaryLanguageBinding(for: meeting)) {
                            Text(SummaryLanguage.english.rawValue).tag(SummaryLanguage.english)
                            Text(meeting.chineseSummary == nil ? "Translate" : SummaryLanguage.simplifiedChinese.rawValue)
                                .tag(SummaryLanguage.simplifiedChinese)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 138)
                        .layoutPriority(1)
                        .help(meeting.chineseSummary == nil
                              ? "Translate this summary to Simplified Chinese."
                              : "Switch between the English summary and the saved Simplified Chinese translation.")
                    }

                    Toggle(isOn: $markdownPreviewEnabled) {
                        Label("Markdown", systemImage: "doc.richtext")
                    }
                    .toggleStyle(.button)
                    .fixedSize()
                    .help(markdownPreviewEnabled ? "Show standard view" : "Render Markdown preview")
                }
                .padding(12)

                Divider()
                ZStack {
                    MarkdownDocumentView(
                        markdown: meeting.transcript.isEmpty ? "No transcript content yet." : meeting.transcript,
                        preview: markdownPreviewEnabled
                    )
                        .opacity(model.detailTab == .transcript ? 1 : 0)
                        .allowsHitTesting(model.detailTab == .transcript)
                        .accessibilityHidden(model.detailTab != .transcript)
                        .zIndex(model.detailTab == .transcript ? 1 : 0)

                    Group {
                        if markdownPreviewEnabled,
                           let summaryMarkdown = exportableSummaryMarkdown(for: meeting),
                           !summaryMarkdown.isEmpty {
                            MarkdownDocumentView(markdown: summaryMarkdown, preview: true)
                        } else {
                            SummaryDetailView(
                                structuredSummary: displayedStructuredSummary(for: meeting),
                                legacySummary: meeting.summary,
                                presentationMode: summaryPresentationMode,
                                language: effectiveSummaryLanguage(for: meeting)
                            )
                            .equatable()
                        }
                    }
                    .opacity(model.detailTab == .summary ? 1 : 0)
                    .allowsHitTesting(model.detailTab == .summary)
                    .accessibilityHidden(model.detailTab != .summary)
                    .zIndex(model.detailTab == .summary ? 1 : 0)
                }
            }
        } else {
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "text.bubble",
                description: Text("Start a transcription or select a saved meeting.")
            )
        }
    }

    private func meeting(withID id: String?) -> SavedMeeting? {
        guard let id else { return nil }
        return model.meetings.first { $0.id == id }
    }

    private func requestSummaryGeneration(for meeting: SavedMeeting) {
        let hasSummary = meeting.structuredSummary != nil || !(meeting.summary ?? "").isEmpty
        if hasSummary {
            regenerateMeetingID = meeting.id
            showRegenerateSummaryConfirmation = true
        } else {
            model.summarize(meeting)
        }
    }

    private func summaryLanguageBinding(for meeting: SavedMeeting) -> Binding<SummaryLanguage> {
        Binding(
            get: {
                meeting.chineseSummary == nil ? .english : model.summaryLanguage
            },
            set: { language in
                if language == .simplifiedChinese, meeting.chineseSummary == nil {
                    model.translateSummaryToChinese(meeting)
                } else {
                    model.summaryLanguage = language
                }
            }
        )
    }

    private func effectiveSummaryLanguage(for meeting: SavedMeeting) -> SummaryLanguage {
        model.summaryLanguage == .simplifiedChinese && meeting.chineseSummary != nil
            ? .simplifiedChinese
            : .english
    }

    private func displayedStructuredSummary(for meeting: SavedMeeting) -> MeetingSummary? {
        switch effectiveSummaryLanguage(for: meeting) {
        case .english:
            return meeting.structuredSummary
        case .simplifiedChinese:
            return meeting.chineseSummary
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Meeting")
                .font(.headline)
            TextField("Meeting name", text: $renameTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit { confirmRename() }

            HStack {
                Spacer()
                Button("Cancel") {
                    showRenameSheet = false
                    renameMeetingID = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    confirmRename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 410)
    }

    private func confirmRename() {
        guard let meeting = meeting(withID: renameMeetingID) else {
            showRenameSheet = false
            renameMeetingID = nil
            return
        }
        model.renameMeeting(meeting, to: renameTitle)
        showRenameSheet = false
        renameMeetingID = nil
    }

    private func meetingHeader(_ meeting: SavedMeeting) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.metadata.title)
                    .font(.title2.weight(.semibold))
                Text(meeting.directory.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if model.isSummarizing {
                Button(role: .destructive) {
                    model.cancelSummary()
                } label: {
                    Label("Stop Summary", systemImage: "stop.fill")
                }
                .help("Stop the summary generation currently in progress.")
            } else if model.isTranslatingSummary {
                Button(role: .destructive) {
                    model.cancelSummaryTranslation()
                } label: {
                    Label("Stop Translation", systemImage: "stop.fill")
                }
                .help("Stop the summary translation currently in progress.")
            } else if model.llmConfigured {
                Button {
                    requestSummaryGeneration(for: meeting)
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
                }
                .disabled(meeting.transcript.isEmpty)
            } else {
                Button {
                    showLLMSettings = true
                } label: {
                    Label("Set Up Summary", systemImage: "sparkles")
                }
                .help("Choose Codex CLI or an OpenAI-compatible API for meeting summaries.")
            }
            if hasExportableSummary(meeting) {
                Menu {
                    Button {
                        copySummary(meeting)
                    } label: {
                        Label("Copy Summary", systemImage: "doc.on.doc")
                    }

                    Divider()

                    Button {
                        exportSummary(meeting, format: .markdown)
                    } label: {
                        Label("Export Markdown…", systemImage: "doc.plaintext")
                    }

                    Button {
                        exportSummary(meeting, format: .pdf)
                    } label: {
                        Label("Export PDF…", systemImage: "doc.richtext")
                    }
                } label: {
                    Label("Export Summary", systemImage: "square.and.arrow.up")
                }
                .help("Copy or export the currently selected \(summaryPresentationMode.rawValue.lowercased()) summary.")
            }
            Button {
                showLLMSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Summary settings")
            Button {
                model.revealSelectedMeeting()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
        .padding(16)
    }

    private func exportableSummaryMarkdown(for meeting: SavedMeeting) -> String? {
        let language = effectiveSummaryLanguage(for: meeting)
        let markdown = displayedStructuredSummary(for: meeting)?.markdown(
            mode: summaryPresentationMode,
            language: language
        ) ?? meeting.summary
        guard let markdown else { return nil }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : markdown
    }

    private func hasExportableSummary(_ meeting: SavedMeeting) -> Bool {
        if meeting.structuredSummary != nil { return true }
        guard let summary = meeting.summary else { return false }
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func copySummary(_ meeting: SavedMeeting) {
        guard let markdown = exportableSummaryMarkdown(for: meeting) else { return }
        SummaryExporter.copy(markdown: markdown)
        model.statusText = "Summary copied"
    }

    private func exportSummary(_ meeting: SavedMeeting, format: SummaryExportFormat) {
        guard let markdown = exportableSummaryMarkdown(for: meeting) else { return }
        do {
            let exported = try SummaryExporter.export(
                markdown: markdown,
                suggestedBaseName: meeting.metadata.title,
                format: format
            )
            if exported {
                model.statusText = "Summary exported"
            }
        } catch {
            model.errorText = "Could not export summary: \(error.localizedDescription)"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.accessibilityTrusted {
                Button {
                    model.requestAccessibility()
                } label: {
                    Label("Request Access", systemImage: "lock.open")
                }
                .help("Morrow Scribe needs Accessibility access to read Slack captions.")
            }

            TextField("Meeting title", text: $model.meetingTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
                .disabled(model.isTranscribing)

            if model.isTranscribing {
                Button(role: .destructive) {
                    model.stopTranscription()
                } label: {
                    Label(model.isStopping ? "Finishing…" : "Stop", systemImage: "stop.fill")
                }
                .disabled(model.isStopping)
            } else {
                Button {
                    model.startTranscription()
                } label: {
                    Label("Start", systemImage: "record.circle")
                }
            }

        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if model.isTranscribing || model.isStopping || model.isSummarizing || model.isTranslatingSummary {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(.bar)
        }
    }
}

private struct LLMSettingsView: View {
    @State private var provider: SummaryProvider
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey: String
    @State private var codexPath: String
    @State private var codexModel: String
    @State private var codexReasoningEffort: String
    @State private var isTesting = false
    @State private var testResult: TestResult?

    let onSave: (SummaryConfiguration) -> Void
    let onCancel: () -> Void

    init(
        initialConfiguration: SummaryConfiguration,
        onSave: @escaping (SummaryConfiguration) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _provider = State(initialValue: initialConfiguration.provider)
        _baseURL = State(initialValue: initialConfiguration.baseURL)
        _model = State(initialValue: initialConfiguration.model)
        _apiKey = State(initialValue: initialConfiguration.apiKey)
        _codexPath = State(initialValue: initialConfiguration.codexPath)
        _codexModel = State(initialValue: initialConfiguration.codexModel)
        _codexReasoningEffort = State(initialValue: initialConfiguration.codexReasoningEffort)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var configuration: SummaryConfiguration {
        SummaryConfiguration(
            provider: provider,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            codexPath: codexPath,
            codexModel: codexModel,
            codexReasoningEffort: codexReasoningEffort
        )
    }

    private enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Summary Provider")
                    .font(.title2.weight(.semibold))
                Text(providerDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Provider", selection: $provider) {
                ForEach(SummaryProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: provider) { _, _ in testResult = nil }

            if provider == .openAICompatible {
                Form {
                    TextField("Base URL", text: $baseURL, prompt: Text("https://…/v1"))
                        .textContentType(.URL)
                    TextField("Model", text: $model, prompt: Text("model name"))
                    SecureField("API Key", text: $apiKey, prompt: Text("optional for local endpoints"))
                }
                .formStyle(.grouped)

                HStack(spacing: 8) {
                    Button("Use Ollama") {
                        baseURL = "http://127.0.0.1:11434/v1"
                        testResult = nil
                    }
                    .buttonStyle(.bordered)

                    Text("Only the endpoint is filled; choose the local model you installed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                Form {
                    TextField("Codex executable", text: $codexPath, prompt: Text("Auto-detect codex"))
                    TextField("Model", text: $codexModel, prompt: Text(SummaryDefaults.codexModel))
                    Picker("Reasoning effort", selection: $codexReasoningEffort) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("xHigh (Default)").tag("xhigh")
                    }
                }
                .formStyle(.grouped)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: configuration.isConfigured ? "checkmark.circle" : "exclamationmark.triangle")
                    Text(codexDetectionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Button(isTesting ? "Testing…" : "Test Connection") {
                    testConnection()
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || !configuration.isConfigured)

                if let testResult {
                    switch testResult {
                    case .success:
                        Label("Connection works", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case let .failure(message):
                        Label(message, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(configuration)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!configuration.isConfigured)
            }
        }
        .padding(24)
        .frame(width: 580)
    }

    private var providerDescription: String {
        switch provider {
        case .openAICompatible:
            return "Use any OpenAI-compatible chat-completions endpoint. The API key is stored in macOS Keychain."
        case .codexCLI:
            return "Use your existing Codex CLI login instead of an API key. Scribe runs an isolated, non-interactive codex exec session for each summary pass."
        }
    }

    private var codexDetectionText: String {
        if let path = CodexCLI.resolveExecutable(configuredPath: codexPath) {
            return "Codex detected at \(path). User config, plugins, project rules, and session persistence are disabled for summaries."
        }
        return "Codex CLI was not found. Enter its executable path or install Codex first."
    }

    private func testConnection() {
        guard !isTesting, configuration.isConfigured else { return }
        isTesting = true
        testResult = nil
        let configuration = configuration
        Task {
            do {
                try await SummaryClient.test(configuration: configuration)
                testResult = .success
            } catch {
                testResult = .failure(String(describing: error))
            }
            isTesting = false
        }
    }
}

private struct SummaryDetailView: View, Equatable {
    let structuredSummary: MeetingSummary?
    let legacySummary: String?
    let presentationMode: SummaryPresentationMode
    let language: SummaryLanguage

    nonisolated static func == (lhs: SummaryDetailView, rhs: SummaryDetailView) -> Bool {
        lhs.structuredSummary == rhs.structuredSummary &&
            lhs.legacySummary == rhs.legacySummary &&
            lhs.presentationMode == rhs.presentationMode &&
            lhs.language == rhs.language
    }

    var body: some View {
        if let summary = structuredSummary {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !summary.tldr.isEmpty {
                        summaryCard(title: localized("At a Glance", "概览"), systemImage: "sparkles") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(summary.tldr) { point in
                                    SummaryPointView(point: point, prominent: true, language: language)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        if !summary.decisions.isEmpty {
                            pointCard(title: localized("Decisions", "决策"), systemImage: "checkmark.seal", points: summary.decisions)
                        }
                        if !summary.actionItems.isEmpty {
                            summaryCard(title: localized("Action Items", "行动项"), systemImage: "checklist") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(summary.actionItems) { item in
                                        SummaryActionItemView(item: item, language: language)
                                    }
                                }
                            }
                        }
                        if !summary.openQuestions.isEmpty {
                            pointCard(title: localized("Open Questions", "未决问题"), systemImage: "questionmark.circle", points: summary.openQuestions)
                        }
                        if presentationMode == .detailed {
                            if !summary.nextSteps.isEmpty {
                                pointCard(title: localized("Next Steps", "下一步"), systemImage: "arrow.right.circle", points: summary.nextSteps)
                            }
                            if !summary.risks.isEmpty {
                                pointCard(title: localized("Risks / Blockers", "风险 / 阻碍"), systemImage: "exclamationmark.triangle", points: summary.risks)
                            }
                        }
                    }

                    if presentationMode == .detailed {
                        ForEach(summary.sections) { section in
                            pointCard(title: section.title, systemImage: "text.alignleft", points: section.bullets)
                        }

                        if !summary.sourceWarnings.isEmpty {
                            summaryCard(title: localized("Source Quality", "来源质量"), systemImage: "waveform.badge.exclamationmark") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(summary.sourceWarnings, id: \.self) { warning in
                                        Label(warning, systemImage: "info.circle")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 920, alignment: .topLeading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .id("\(presentationMode.rawValue)-\(language.rawValue)")
        } else if let legacySummary, !legacySummary.isEmpty {
            MarkdownDocumentView(markdown: legacySummary, preview: false)
        } else {
            ContentUnavailableView(
                "No summary yet",
                systemImage: "sparkles",
                description: Text("Configure Codex CLI or an API provider and generate a grounded summary from this transcript.")
            )
        }
    }

    private func pointCard(title: String, systemImage: String, points: [SummaryPoint]) -> some View {
        summaryCard(title: title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(points) { point in
                    SummaryPointView(point: point, language: language)
                }
            }
        }
    }

    private func localized(_ english: String, _ chinese: String) -> String {
        language == .simplifiedChinese ? chinese : english
    }

    private func summaryCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 0.5)
        }
    }
}

private struct SummaryPointView: View {
    let point: SummaryPoint
    var prominent = false
    let language: SummaryLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: prominent ? "diamond.fill" : "circle.fill")
                    .font(.system(size: prominent ? 7 : 5))
                    .foregroundStyle(.secondary)
                Text(point.text)
                    .font(prominent ? .body.weight(.medium) : .body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SummaryEvidenceView(evidence: point.evidence, confidence: point.confidence, language: language)
                .padding(.leading, 15)
        }
    }
}

private struct SummaryActionItemView: View {
    let item: SummaryActionItem
    let language: SummaryLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text(item.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.owner != nil || item.deadline != nil || item.explicitness == .inferred {
                HStack(spacing: 10) {
                    if let owner = item.owner {
                        Label(owner, systemImage: "person")
                    }
                    if let deadline = item.deadline {
                        Label(deadline, systemImage: "calendar")
                    }
                    if item.explicitness == .inferred {
                        Label(language == .simplifiedChinese ? "推断" : "Inferred", systemImage: "wand.and.stars")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
            }
            SummaryEvidenceView(evidence: item.evidence, confidence: item.confidence, language: language)
                .padding(.leading, 28)
        }
    }
}

private struct SummaryEvidenceView: View {
    let evidence: [SummaryEvidence]
    let confidence: SummaryConfidence
    let language: SummaryLanguage
    @State private var isExpanded = false

    private func metadata(for evidence: SummaryEvidence) -> String {
        var parts: [String] = []
        if let timestamp = evidence.timestamp { parts.append(timestamp) }
        if let speaker = evidence.speaker { parts.append(speaker) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if !evidence.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            let meta = metadata(for: item)
                            if !meta.isEmpty {
                                Text(meta)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let quote = item.quote {
                                Text("“\(quote)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Text(sourceLabel)
                    if confidence != .high {
                        Text("· \(confidenceLabel)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .controlSize(.small)
        } else if confidence != .high {
            Text(language == .simplifiedChinese
                 ? "\(confidenceLabel) · 无已验证的来源引用"
                 : "\(confidenceLabel) · no verified source quote")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var sourceLabel: String {
        if language == .simplifiedChinese {
            return "\(evidence.count) 条来源"
        }
        return "\(evidence.count) source\(evidence.count == 1 ? "" : "s")"
    }

    private var confidenceLabel: String {
        if language == .english {
            return "\(confidence.rawValue.capitalized) confidence"
        }
        switch confidence {
        case .high: return "高置信度"
        case .medium: return "中等置信度"
        case .low: return "低置信度"
        }
    }
}
