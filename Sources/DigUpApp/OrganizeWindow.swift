import AppKit
import DigUpKit
import Observation
import SwiftUI

/// Organise: folders for photos by what they show, or a search's files moved into one folder. Nothing moves until the
/// plan has been shown and confirmed; every batch can be put back (`Organizer`'s journal).
final class OrganizeWindowController: NSObject, NSWindowDelegate {
    let state: OrganizeState
    private unowned let app: AppController
    private var window: NSWindow?

    init(app: AppController) {
        self.app = app
        state = OrganizeState(engine: app.engine)
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    /// Opens it; with `query`, on "From a search" with that search filled in.
    func show(query: String? = nil) {
        if let query {
            state.mode = .search
            state.query = query
            state.plan = nil
        }
        let window = self.window ?? makeWindow()
        state.refreshHistory()
        app.present(window)
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: OrganizeView(state: state, app: app))
        let window = NSWindow(contentViewController: controller)
        window.title = "Organise"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 760, height: 600))
        window.contentMinSize = NSSize(width: 620, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        app.windowClosed()
    }
}

@Observable
final class OrganizeState {
    enum Mode: String, CaseIterable { case photos, search }

    let engine: Engine
    var mode: Mode = .photos
    /// Photos: where to look (empty: every folder searched) and the folder names to sort into (empty: DigUp names them).
    var folders: [URL] = []
    var labels = ""
    var includeScreenshots = false
    /// Search: what to look for, and whether weaker results go too.
    var query = ""
    var everything = false
    /// Where the folders go; nil: "Organised" in the first folder (photos), or a folder you pick (search).
    var destination: URL?

    var plan: Organizer.Plan?
    /// Per group (by index in the plan): left out, or a new name.
    var skipped: Set<Int> = []
    var renamed: [Int: String] = [:]
    var busy: String?
    var message: String?
    var history: [Organizer.Batch] = []

    init(engine: Engine) { self.engine = engine }

    var lookIn: [URL] { folders.isEmpty ? engine.searchedFolders : folders }

    var resolvedDestination: URL? {
        if let destination { return destination }
        guard mode == .photos, let first = lookIn.first else { return nil }
        return first.appendingPathComponent("Organised")
    }

    /// The plan as edited: groups left out are dropped, renamed ones point at their new folder.
    var editedPlan: Organizer.Plan? {
        guard var plan else { return nil }
        plan.groups = plan.groups.enumerated().compactMap { index, group in
            guard !skipped.contains(index) else { return nil }
            var group = group
            if let name = renamed[index]?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name != group.name {
                let folder = mode == .photos ? (plan.destination as NSString).appendingPathComponent(
                    name.replacingOccurrences(of: "/", with: "-")) : plan.destination
                group.name = name
                group.moves = group.moves.map {
                    .init(fileID: $0.fileID, from: $0.from,
                          to: (folder as NSString).appendingPathComponent(($0.from as NSString).lastPathComponent))
                }
            }
            return group
        }
        return plan
    }

    var movingCount: Int { editedPlan?.moves.count ?? 0 }

    func preview() async {
        message = nil
        plan = nil
        skipped = []
        renamed = [:]
        let result: Result<Organizer.Plan, Error>
        switch mode {
        case .photos:
            guard let destination = resolvedDestination else { return message = "Choose folders to search first." }
            busy = "Looking at your photos…"
            let names = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            result = await engine.planPhotos(under: folders.isEmpty ? nil : folders, destination: destination,
                                             labels: names.isEmpty ? nil : names, groups: nil,
                                             screenshots: includeScreenshots)
        case .search:
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return message = "Type what to look for." }
            guard let destination else { return message = "Choose the folder to move them to." }
            busy = "Searching…"
            result = await engine.planSearch(text, destination: destination, everything: everything)
        }
        busy = nil
        switch result {
        case .success(let plan):
            self.plan = plan
            if plan.moves.isEmpty { message = "Nothing to move: everything is where it would go, or nothing matched." }
        case .failure(let error):
            message = "\(error)"
        }
    }

    func apply() async {
        guard let plan = editedPlan, !plan.moves.isEmpty else { return }
        busy = "Moving \(plan.moves.count) files…"
        let result = await engine.apply(plan)
        busy = nil
        switch result {
        case .success(let batch):
            message = "Moved \(batch.moves.count) files. Undo puts them back."
            self.plan = nil
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plan.destination)])
        case .failure(let error):
            message = "Stopped: \(error.localizedDescription). What moved can be undone."
        }
        refreshHistory()
    }

    func undo() async {
        busy = "Putting files back…"
        let result = await engine.undoOrganize()
        busy = nil
        switch result {
        case .success(let undone?):
            let back = undone.batch.moves.count - undone.skipped.count
            message = "Put back \(back) files." + (undone.skipped.isEmpty ? ""
                : " \(undone.skipped.count) were moved again since, or their old place is taken, so they stay.")
        case .success(nil): message = "Nothing to undo."
        case .failure(let error): message = "Couldn't undo: \(error.localizedDescription)"
        }
        refreshHistory()
    }

    func refreshHistory() { history = engine.organizeHistory() }
}

struct OrganizeView: View {
    @Bindable var state: OrganizeState
    let app: AppController
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(16)
            Divider()
            planList
            Divider()
            bottomBar.padding(.horizontal, 16).frame(height: 52)
        }
        .confirmationDialog("Move \(state.movingCount) files?", isPresented: $confirming) {
            Button("Move Files") { Task { await state.apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They go into folders in \(state.editedPlan.map { tilde($0.destination) } ?? "the destination"). "
                 + "Nothing is deleted or overwritten, and Undo puts them back.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $state.mode) {
                Text("Photos by what they show").tag(OrganizeState.Mode.photos)
                Text("From a search").tag(OrganizeState.Mode.search)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: state.mode) { state.plan = nil; state.message = nil }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                if state.mode == .photos {
                    GridRow {
                        Text("Look in").foregroundStyle(.secondary)
                        HStack {
                            Text(state.folders.isEmpty ? "Every folder DigUp searches"
                                 : state.folders.map { tilde($0.path) }.joined(separator: ", "))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if !state.folders.isEmpty { Button("All Folders") { state.folders = [] } }
                            Button("Choose…") {
                                app.pickFolders(for: NSApp.keyWindow, prompt: "Choose") { if !$0.isEmpty { state.folders = $0 } }
                            }
                        }
                    }
                    GridRow {
                        Text("Sort into").foregroundStyle(.secondary)
                        TextField("Leave empty and DigUp names the groups, or type: Beach, Food, Receipts", text: $state.labels)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle("Include screenshots", isOn: $state.includeScreenshots)
                    }
                } else {
                    GridRow {
                        Text("Find").foregroundStyle(.secondary)
                        TextField("Describe the files: “receipts”, “boarding passes”, “dog photos”", text: $state.query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await state.preview() } }
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle("Include weaker matches", isOn: $state.everything)
                    }
                }
                GridRow {
                    Text("Move to").foregroundStyle(.secondary)
                    HStack {
                        Text(state.resolvedDestination.map { tilde($0.path) } ?? "Choose a folder")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(state.resolvedDestination == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { chooseDestination() }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Preview") { Task { await state.preview() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.busy != nil)
            }
        }
    }

    @ViewBuilder private var planList: some View {
        if let busy = state.busy {
            VStack(spacing: 10) { ProgressView(); Text(busy).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan = state.plan, !plan.groups.isEmpty {
            List {
                ForEach(Array(plan.groups.enumerated()), id: \.offset) { index, group in
                    GroupRow(group: group, index: index, state: state)
                }
                if !plan.leftInPlace.isEmpty {
                    Text("\(plan.leftInPlace.count) photos stay where they are: too mixed, or too few to make a folder.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.square").font(.system(size: 36)).foregroundStyle(Brand.gradient)
                Text(state.message ?? (state.mode == .photos
                    ? "Preview shows the folders DigUp would make. Nothing moves until you say so."
                    : "Preview shows what the search would move. Nothing moves until you say so."))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var bottomBar: some View {
        HStack {
            if let last = state.history.last {
                Button("Undo “\(last.title)”") { Task { await state.undo() } }
                    .disabled(state.busy != nil)
                    .help("Puts the \(last.moves.count) files moved \(last.date.formatted(.relative(presentation: .named))) back")
            }
            Spacer()
            if state.plan != nil, let message = state.message { Text(message).foregroundStyle(.secondary).lineLimit(1) }
            Button("Move \(state.movingCount) Files…") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(state.movingCount == 0 || state.busy != nil)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where the folders go."
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { state.destination = url; state.plan = nil }
        }
    }
}

/// A folder the plan would make: on or off, its name (editable), and a strip of its pictures.
private struct GroupRow: View {
    let group: Organizer.Group
    let index: Int
    @Bindable var state: OrganizeState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: Binding(get: { !state.skipped.contains(index) },
                                         set: { if $0 { state.skipped.remove(index) } else { state.skipped.insert(index) } }))
                    .labelsHidden()
                Image(systemName: "folder.fill").foregroundStyle(Brand.ember)
                TextField("Folder name", text: Binding(get: { state.renamed[index] ?? group.name },
                                                       set: { state.renamed[index] = $0 }))
                    .textFieldStyle(.plain).font(.headline).frame(maxWidth: 220)
                Text("\(group.moves.count) files").foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(group.moves.prefix(40), id: \.from) { move in
                        Thumbnail(url: URL(fileURLWithPath: move.from))
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: move.from)) }
                            .help((move.from as NSString).lastPathComponent)
                    }
                }
            }
            .frame(height: 72)
        }
        .padding(.vertical, 4)
        .opacity(state.skipped.contains(index) ? 0.4 : 1)
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) { image = await Thumbnails.shared.load(url, side: 72, scale: scale) }
    }
}

private let homePath = FileManager.default.homeDirectoryForCurrentUser.path
private func tilde(_ path: String) -> String { path.hasPrefix(homePath) ? "~" + path.dropFirst(homePath.count) : path }
