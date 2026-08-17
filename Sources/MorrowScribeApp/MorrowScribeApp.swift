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
                        model.refreshLibraryKeepingSelection()
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
    @Published var autoSummarize = false
    @Published var statusText = "Ready"
    @Published var errorText: String?
    @Published var detailTab: DetailTab = .transcript
    @Published var accessibilityTrusted = SlackAXSession().accessibilityTrusted

    private var collectorControl: CollectorControl?
    private var recordingStatus: RecordingStatus?
    private var activeMeetingDirectory: URL?

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

    var llmConfigured: Bool { SummaryClient.isConfigured }

    func refreshLibraryKeepingSelection() {
        accessibilityTrusted = SlackAXSession().accessibilityTrusted
        if isTranscribing, !isStopping, let recordingStatus {
            statusText = recordingStatus.current
        }
        let selected = selectedMeetingID
        let activePath = activeMeetingDirectory?.path
        do {
            meetings = try MeetingLibrary.loadAll()
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

            let autoSummary = autoSummarize
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
                let finishedDirectory = self.activeMeetingDirectory
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
                if autoSummary, self.llmConfigured, let finishedDirectory {
                    await self.summarize(directory: finishedDirectory)
                }
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

    func summarizeSelected() {
        guard let directory = selectedMeeting?.directory else { return }
        Task { await summarize(directory: directory) }
    }

    private func summarize(directory: URL) async {
        guard !isSummarizing else { return }
        isSummarizing = true
        errorText = nil
        statusText = "Generating summary…"
        defer { isSummarizing = false }
        do {
            let entries = try MeetingExport.transcriptEntries(in: directory)
            guard !entries.isEmpty else {
                errorText = "This meeting has no transcript yet."
                statusText = "No transcript to summarize"
                return
            }
            let summary = try await SummaryClient.summarize(prompt: MeetingExport.summaryPrompt(entries: entries))
            try summary.write(
                to: directory.appendingPathComponent("summary.md"),
                atomically: true,
                encoding: .utf8
            )
            statusText = "Summary saved"
            refreshLibraryKeepingSelection()
            selectedMeetingID = directory.path
            detailTab = .summary
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

    var body: some View {
        NavigationSplitView {
            meetingSidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .toolbar { toolbar }
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
                Picker("Content", selection: $model.detailTab) {
                    ForEach(ScribeViewModel.DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .padding(12)

                Divider()
                ScrollView {
                    Text(detailText(for: meeting))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(20)
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
            if model.llmConfigured {
                Button {
                    model.summarizeSelected()
                } label: {
                    Label(model.isSummarizing ? "Summarizing…" : "Generate Summary", systemImage: "sparkles")
                }
                .disabled(model.isSummarizing || meeting.transcript.isEmpty)
            } else {
                Label("LLM not configured", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Set MORROW_SCRIBE_LLM_BASE_URL and MORROW_SCRIBE_LLM_MODEL to enable summaries.")
            }
            Button {
                model.revealSelectedMeeting()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
        .padding(16)
    }

    private func detailText(for meeting: SavedMeeting) -> String {
        switch model.detailTab {
        case .transcript:
            return meeting.transcript.isEmpty ? "No transcript content yet." : meeting.transcript
        case .summary:
            return meeting.summary ?? "No summary yet. Configure an LLM provider and generate one when ready."
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

            Toggle("Auto summary", isOn: $model.autoSummarize)
                .disabled(!model.llmConfigured || model.isTranscribing)
                .help(model.llmConfigured
                      ? "Generate summary.md automatically after transcription stops."
                      : "Configure the LLM environment variables to enable automatic summaries.")

            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 180, alignment: .trailing)
        }
    }
}
