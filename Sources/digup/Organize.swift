import DigUpKit
import Foundation

// `digup organize`: plan moves (photos by what they show, or a search's results), look at the plan, apply it, undo it.
// A plan is saved in the index folder (organize-plan.json) and `apply` moves exactly what was shown.

func organize(_ args: Arguments) throws {
    var rest = args
    guard !rest.positional.isEmpty else { throw CLIError("organize what? photos, search, apply, undo or history") }
    let action = rest.positional.removeFirst()
    let store = try args.store()
    switch action {
    case "photos":
        let folders = try rest.folders()
        let destination = rest.values["--to"].map { Arguments.folderURL($0).path }
            ?? folders[0].appendingPathComponent("Organised").path
        let labels = rest.values["--labels"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let kinds: Set<FileKind> = rest.flags.contains("--screenshots") ? [.image, .screenshot] : [.image]
        let searcher = try Searcher(store: store, loadVectors: false)
        let embedder = try makeEmbedder(textOnly: true, log: store.directory.appendingPathComponent("worker-query.log"))
        defer { embedder.close() }
        if let source = searcher.vectorSource, source != embedder.info.vectorSource {
            throw CLIError("index vectors come from \(source) but the text encoder is \(embedder.info.vectorSource)")
        }
        let plan = try Organizer.planPhotos(store, under: folders.map(\.path), destination: destination,
                                            embedder: embedder, labels: labels,
                                            groups: rest.values["--groups"].flatMap(Int.init), kinds: kinds)
        try show(plan, args: rest, store: store)
    case "search":
        let query = rest.positional.joined(separator: " ")
        guard !query.isEmpty else { throw CLIError("search for what? e.g. digup organize search receipts --to ~/Receipts") }
        guard let to = rest.values["--to"] else { throw CLIError("move the results where? add --to DIR") }
        let searcher = try Searcher(store: store)
        let vector = try queryVectors([query], store: store, searcher: searcher)?.first
        let hits = try searcher.search(query, queryVector: vector, kinds: try rest.kinds(),
                                       limit: rest.values["-n"].flatMap(Int.init) ?? 500, zGate: rest.zGate)
        let plan = Organizer.planSearch(hits, query: query, destination: Arguments.folderURL(to).path,
                                        everything: rest.flags.contains("--all"))
        try show(plan, args: rest, store: store)
    case "apply":
        let url = rest.positional.first.map { Arguments.folderURL($0) }
            ?? store.directory.appendingPathComponent(Organizer.planFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError("no plan to apply: run digup organize photos or search first")
        }
        let plan = try Organizer.loadPlan(url)
        let batch = try Organizer.apply(plan, store: store)
        if url.lastPathComponent == Organizer.planFile { try? FileManager.default.removeItem(at: url) }
        print("moved \(number(batch.moves.count)) files (\(plan.title)) · undo with: digup organize undo")
    case "undo":
        guard let (batch, skipped) = try Organizer.undo(store: store, id: rest.positional.first) else {
            print("nothing to undo")
            return
        }
        print("put back \(number(batch.moves.count - skipped.count)) files (\(batch.title))")
        for path in skipped { print("  left \(tilde(path)): moved again since, or its old place is taken") }
    case "history":
        let journal = Organizer.loadJournal(in: store.directory)
        if journal.isEmpty { print("nothing organised yet") }
        for batch in journal.reversed() {
            print("\(batch.date.formatted(date: .abbreviated, time: .shortened))  \(pad("\(batch.moves.count) files", 10)) "
                  + "\(batch.title)  [\(batch.id.prefix(8))]")
        }
    default:
        throw CLIError("unknown organize action \(action); use photos, search, apply, undo or history")
    }
}

/// Prints the plan (or its JSON) and saves it for `apply`.
private func show(_ plan: Organizer.Plan, args: Arguments, store: IndexStore) throws {
    try Organizer.save(plan, in: store.directory)
    if args.flags.contains("--json") {
        print(String(data: try planJSON(plan), encoding: .utf8) ?? "{}")
        return
    }
    guard !plan.moves.isEmpty else {
        print("nothing to move")
        return
    }
    print("\(plan.title) → \(tilde(plan.destination))\n")
    for group in plan.groups {
        let fit = group.fit.map { String(format: "  (fit %.1f)", $0) } ?? ""
        print("  \(pad(group.name + "/", 18)) \(lpad(number(group.moves.count), 5)) files\(fit)")
        for move in group.moves.prefix(3) { print("      \((move.from as NSString).lastPathComponent)") }
        if group.moves.count > 3 { print("      …") }
    }
    if !plan.leftInPlace.isEmpty {
        print("\n  \(number(plan.leftInPlace.count)) left where they are (too mixed or too few to name)")
    }
    print("\n\(number(plan.moves.count)) files would move. Nothing has moved yet: digup organize apply")
}

private func planJSON(_ plan: Organizer.Plan) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(plan)
}
