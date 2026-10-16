import Foundation

/// Organising: plans that move files into folders, by what photos show or by a search, then applies or undoes them.
///
/// DigUp otherwise never touches files, so everything here goes through a plan the person sees first. Applying moves
/// each file (never overwriting: a clash gets " 2" on its name), points its index row at the new path so nothing is
/// embedded again (`IndexStore.move`; the watcher's sync then finds it unchanged), and records the batch in a journal
/// in the index folder, which `undo` walks backwards.
public enum Organizer {
    public static let planFile = "organize-plan.json"
    public static let journalFile = "organize-journal.json"

    // MARK: Plans

    public struct Move: Codable, Sendable, Hashable {
        public var fileID: Int64?
        public var from: String
        public var to: String
        public init(fileID: Int64?, from: String, to: String) {
            self.fileID = fileID
            self.from = from
            self.to = to
        }
    }

    public struct Group: Codable, Sendable {
        /// The folder's name.
        public var name: String
        /// How well the name fits the photos (mean z of the label over them); nil for a search's results.
        public var fit: Double?
        public var moves: [Move]
    }

    public struct Plan: Codable, Sendable {
        public var title: String
        public var destination: String
        public var groups: [Group]
        /// Files the plan leaves where they are (a group too small or too mixed to name), for showing.
        public var leftInPlace: [String]
        public var created: Date

        public var moves: [Move] { groups.flatMap(\.moves) }
    }

    public struct Batch: Codable, Sendable {
        public var id: String
        public var title: String
        public var date: Date
        public var moves: [Move]
    }

    public struct OrganizeError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    // MARK: Photos by what they show

    /// Folder names and what's said to the model to find them. Each is scored against every photo and standardized
    /// per label, so a phrase that's close to everything (hubness) doesn't win every group.
    public static let photoLabels: [(folder: String, phrase: String)] = [
        ("Beach", "a beach with sand and sea"), ("Mountains", "mountains and hiking"), ("Forest", "trees in a forest"),
        ("Snow", "snow and winter"), ("Sunsets", "a sunset or sunrise sky"), ("City", "city streets and buildings"),
        ("Night", "a city or sky at night"), ("Flowers", "flowers and plants"), ("Garden", "a garden or backyard"),
        ("Water", "a lake, river or waterfall"), ("Desert", "a desert landscape"), ("Sky", "clouds in the sky"),
        ("Dogs", "a dog"), ("Cats", "a cat"), ("Animals", "wild animals"), ("Birds", "birds"),
        ("People", "a group of people"), ("Selfies", "a selfie of a face"), ("Kids", "children playing"),
        ("Babies", "a baby"), ("Weddings", "a wedding"), ("Parties", "a party or celebration"),
        ("Concerts", "a concert with a stage and crowd"), ("Sports", "people playing sport"), ("Gym", "a gym and workout"),
        ("Food", "a plate of food"), ("Drinks", "coffee or drinks"), ("Restaurants", "a restaurant table"),
        ("Cooking", "cooking in a kitchen"), ("Cars", "cars"), ("Travel", "travel and landmarks"),
        ("Planes", "airplanes and airports"), ("Boats", "boats and ships"), ("Home", "the inside of a home"),
        ("Architecture", "buildings and architecture"), ("Art", "paintings and artwork"), ("Memes", "a meme with text"),
        ("Receipts", "a receipt or invoice"), ("Documents", "a photo of a paper document"),
        ("Whiteboards", "notes on a whiteboard"), ("Screenshots", "a screenshot of an app or website"),
        ("Charts", "a chart or graph"), ("Code", "code on a screen"), ("Cards", "an ID card or bank card"),
        ("Products", "a product photo"), ("Clothes", "clothes and fashion"), ("Shoes", "shoes"),
        ("Electronics", "computers, phones and gadgets"), ("Books", "books"), ("Music", "musical instruments"),
        ("Games", "video games"), ("Holidays", "christmas or holiday decorations"), ("Work", "an office or a meeting"),
        ("School", "a classroom or school"), ("Maps", "a map"), ("Tickets", "a ticket or boarding pass"),
        ("Logos", "a logo or icon"), ("Wallpapers", "an abstract wallpaper"),
        ("Graphics", "a social media post or marketing graphic with text"), ("Mascots", "a cartoon character or mascot"),
        ("Illustrations", "a 3D render or illustration"), ("Groceries", "groceries and fresh produce"),
        ("Posters", "a poster or flyer"), ("Packaging", "product packaging"), ("Furniture", "furniture"),
        ("Signs", "a sign or banner"), ("Mockups", "a website or app design mockup"),
    ]

    /// A photo's vector, with its index row.
    public struct PhotoVector {
        public let file: FileRecord
        public let vector: [Float]
    }

    /// The image vector of every picture under `roots` (one per picture: its `image` segment).
    public static func photoVectors(_ store: IndexStore, under roots: [String],
                                    kinds: Set<FileKind> = [.image]) throws -> [PhotoVector] {
        let files = try store.files(under: roots).filter { kinds.contains($0.kind) && $0.state == "done" }
        let byID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !byID.isEmpty else { return [] }
        var out: [PhotoVector] = []
        try store.db.query("SELECT file, vec FROM segments WHERE kind = 'image' AND vec IS NOT NULL") { row in
            guard let file = byID[row.int(0)], let blob = row.blob(1),
                  blob.count == Vectors.dimension * MemoryLayout<Float16>.stride else { return }
            var vector = [Float](repeating: 0, count: Vectors.dimension)
            blob.withUnsafeBytes { raw in
                vector.withUnsafeMutableBufferPointer {
                    Vectors.floats(fromHalf: raw.bindMemory(to: Float16.self).baseAddress!, count: Vectors.dimension,
                                   to: $0.baseAddress!)
                }
            }
            out.append(PhotoVector(file: file, vector: vector))
        }
        return out.sorted { $0.file.path < $1.file.path }
    }

    /// Groups the photos under `roots` by what they show and names each group, as a plan to move them into
    /// `destination/<name>/`. `labels`: folder names to sort into (each photo goes to the one it fits best, or stays
    /// put); nil finds groups itself and names them from `photoLabels`. `embedder` embeds the label phrases; without
    /// one, groups are numbered. `groups`: how many to look for (nil: about √(n/2)).
    public static func planPhotos(_ store: IndexStore, under roots: [String], destination: String,
                                  embedder: (any Embedder)?, labels: [String]? = nil, groups: Int? = nil,
                                  kinds: Set<FileKind> = [.image], minimumGroup: Int = 3) throws -> Plan {
        let photos = try photoVectors(store, under: roots, kinds: kinds)
        guard photos.count >= 2 else {
            throw OrganizeError("no indexed photos under \(roots.joined(separator: ", ")) yet")
        }
        let vocabulary: [(folder: String, phrase: String)] = labels.map { $0.map { ($0, $0) } } ?? photoLabels
        // Each photo's z against each label: its cosine, standardized over all the photos for that label.
        var z: [[Float]]? = nil
        if let embedder {
            let phrases = try embedder.embedTexts(vocabulary.map { Prompts.query("a photo of \($0.phrase)") })
            z = standardizedScores(photos.map(\.vector), against: phrases.map(normalized))
        }
        var assignment: [Int]   // the group of each photo, -1 for none
        var names: [String]
        var fits: [Double?]
        if labels != nil, let z {
            // Sorting into the folders asked for: the label that stands out most for each photo, if any does.
            assignment = z.map { row in
                let best = row.indices.max { row[$0] < row[$1] }!
                return row[best] >= 1.0 ? best : -1
            }
            names = vocabulary.map(\.folder)
            fits = vocabulary.indices.map { label in
                let members = assignment.indices.filter { assignment[$0] == label }
                return members.isEmpty ? nil : Double(members.map { z[$0][label] }.reduce(0, +)) / Double(members.count)
            }
        } else {
            let count = groups ?? min(40, max(2, Int((Double(photos.count) / 2).squareRoot().rounded())))
            assignment = kMeans(photos.map(\.vector), groups: min(count, photos.count))
            let groupCount = (assignment.max() ?? -1) + 1
            names = (0..<groupCount).map { "Group \($0 + 1)" }
            fits = Array(repeating: nil, count: groupCount)
            if let z {
                for group in 0..<groupCount {
                    let members = assignment.indices.filter { assignment[$0] == group }
                    guard !members.isEmpty else { continue }
                    let mean = vocabulary.indices.map { label in
                        members.map { z[$0][label] }.reduce(0, +) / Float(members.count)
                    }
                    let best = mean.indices.max { mean[$0] < mean[$1] }!
                    // A group no label stands out for is mixed: better left alone than misnamed.
                    if mean[best] >= 0.5 {
                        names[group] = vocabulary[best].folder
                        fits[group] = Double(mean[best])
                    } else {
                        names[group] = "Mixed"
                    }
                }
            }
        }
        // Groups that got the same name share its folder; small and mixed ones stay where they are.
        var byName: [String: (fit: Double?, members: [Int])] = [:]
        for (photo, group) in assignment.enumerated() where group >= 0 {
            var entry = byName[names[group]] ?? (fits[group], [])
            entry.members.append(photo)
            if let fit = fits[group] { entry.fit = max(entry.fit ?? fit, fit) }
            byName[names[group]] = entry
        }
        var planned: [Group] = []
        var placed = Set<Int>()
        for (name, entry) in byName where name != "Mixed" && entry.members.count >= minimumGroup {
            let folder = (destination as NSString).appendingPathComponent(safeName(name))
            let moves = entry.members.compactMap { photo -> Move? in
                let file = photos[photo].file
                placed.insert(photo)
                guard (file.path as NSString).deletingLastPathComponent != folder else { return nil }   // there already
                return Move(fileID: file.id, from: file.path,
                            to: (folder as NSString).appendingPathComponent((file.path as NSString).lastPathComponent))
            }
            if !moves.isEmpty { planned.append(Group(name: name, fit: entry.fit, moves: moves)) }
        }
        planned.sort { $0.moves.count > $1.moves.count || $0.moves.count == $1.moves.count && $0.name < $1.name }
        let left = photos.indices.filter { !placed.contains($0) }.map { photos[$0].file.path }
        return Plan(title: labels == nil ? "Photos by what they show" : "Photos into \(labels!.joined(separator: ", "))",
                    destination: destination, groups: planned, leftInPlace: left, created: Date())
    }

    // MARK: A search's results

    /// A plan to move a search's files into `destination`: the strong results (`Searcher.strongCount`), or all of
    /// them with `everything`.
    public static func planSearch(_ hits: [SearchHit], query: String, destination: String,
                                  everything: Bool = false) -> Plan {
        let chosen = everything ? hits : Array(hits.prefix(Searcher.strongCount(hits)))
        var seen = Set<String>()
        let moves = chosen.compactMap { hit -> Move? in
            guard seen.insert(hit.path).inserted,
                  (hit.path as NSString).deletingLastPathComponent != destination else { return nil }
            return Move(fileID: nil, from: hit.path,
                        to: (destination as NSString).appendingPathComponent((hit.path as NSString).lastPathComponent))
        }
        let name = (destination as NSString).lastPathComponent
        return Plan(title: "“\(query)” into \(name)", destination: destination,
                    groups: moves.isEmpty ? [] : [Group(name: name, fit: nil, moves: moves)],
                    leftInPlace: [], created: Date())
    }

    // MARK: Applying and undoing

    /// Moves the plan's files. A file that's gone or changed into a folder is skipped; a name already taken at the
    /// destination gets a number. Returns the batch as done (also appended to the journal, even if a move fails part
    /// way: what moved can always be undone).
    @discardableResult
    public static func apply(_ plan: Plan, store: IndexStore,
                             progress: ((Int, Int) -> Void)? = nil) throws -> Batch {
        let manager = FileManager.default
        var batch = Batch(id: UUID().uuidString, title: plan.title, date: Date(), moves: [])
        defer { if !batch.moves.isEmpty { try? appendToJournal(batch, in: store.directory) } }
        let moves = plan.moves
        for (done, move) in moves.enumerated() {
            progress?(done, moves.count)
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: move.from, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            let target = freePath(move.to)
            try manager.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
            try manager.moveItem(atPath: move.from, toPath: target)
            let id = move.fileID ?? store.fileID(at: move.from)
            batch.moves.append(Move(fileID: id, from: move.from, to: target))
            if let id { try? store.db.transaction { try store.move(id, to: target) } }
        }
        progress?(moves.count, moves.count)
        return batch
    }

    /// Puts back the last batch applied (or the one with `id`), and removes the folders it made if they're empty now.
    /// Files moved again since, or with something back at their old place, are left and listed.
    @discardableResult
    public static func undo(store: IndexStore, id: String? = nil) throws -> (batch: Batch, skipped: [String])? {
        var journal = loadJournal(in: store.directory)
        let found = id.map { id in journal.lastIndex { $0.id.hasPrefix(id) } } ?? journal.indices.last
        guard let at = found else { return nil }
        let batch = journal[at]
        let manager = FileManager.default
        var skipped: [String] = []
        var folders = Set<String>()
        for move in batch.moves.reversed() {
            guard manager.fileExists(atPath: move.to), !manager.fileExists(atPath: move.from) else {
                skipped.append(move.to)
                continue
            }
            try manager.createDirectory(atPath: (move.from as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
            try manager.moveItem(atPath: move.to, toPath: move.from)
            folders.insert((move.to as NSString).deletingLastPathComponent)
            if let id = store.fileID(at: move.to) { try? store.db.transaction { try store.move(id, to: move.from) } }
        }
        // The folders it made, and their parents it made (Organised/ above Beach/), up to where files came from.
        let homes = Set(batch.moves.map { ($0.from as NSString).deletingLastPathComponent })
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            var folder = folder
            while !homes.contains(folder), folder.count > 1, removeIfEmpty(folder) {
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        journal.remove(at: at)
        try saveJournal(journal, in: store.directory)
        return (batch, skipped)
    }

    public static func loadJournal(in directory: URL) -> [Batch] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(journalFile)) else { return [] }
        return (try? decoder.decode([Batch].self, from: data)) ?? []
    }

    public static func save(_ plan: Plan, in directory: URL) throws {
        try encoder.encode(plan).write(to: directory.appendingPathComponent(planFile), options: .atomic)
    }

    public static func loadPlan(_ url: URL) throws -> Plan { try decoder.decode(Plan.self, from: Data(contentsOf: url)) }

    static func appendToJournal(_ batch: Batch, in directory: URL) throws {
        try saveJournal(loadJournal(in: directory) + [batch], in: directory)
    }

    static func saveJournal(_ journal: [Batch], in directory: URL) throws {
        try encoder.encode(journal).write(to: directory.appendingPathComponent(journalFile), options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Pieces

    /// `path`, or "name 2.ext", "name 3.ext"… when it's taken.
    static func freePath(_ path: String) -> String {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return path }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = (folder as NSString).appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !manager.fileExists(atPath: candidate) { return candidate }
            number += 1
        }
    }

    /// A folder name without path separators or a leading dot.
    static func safeName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// True when the folder was empty (or held only .DS_Store) and is gone.
    @discardableResult
    static func removeIfEmpty(_ folder: String) -> Bool {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(atPath: folder),
              items.allSatisfy({ $0 == ".DS_Store" }) else { return false }
        return (try? manager.removeItem(atPath: folder)) != nil
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    /// `z[photo][label]`: each label's cosine with each photo, standardized over the photos.
    static func standardizedScores(_ photos: [[Float]], against labels: [[Float]]) -> [[Float]] {
        let matrix = photos.flatMap { $0 }
        var columns: [[Float]] = []
        matrix.withUnsafeBufferPointer { rows in
            for label in labels {
                var scores = [Float](repeating: 0, count: photos.count)
                label.withUnsafeBufferPointer { query in
                    scores.withUnsafeMutableBufferPointer {
                        Vectors.scores(of: rows.baseAddress!, count: photos.count, query: query.baseAddress!,
                                       into: $0.baseAddress!)
                    }
                }
                let mean = scores.reduce(0, +) / Float(scores.count)
                let spread = (scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(scores.count)).squareRoot()
                columns.append(scores.map { spread > 0 ? ($0 - mean) / spread : 0 })
            }
        }
        return photos.indices.map { photo in columns.map { $0[photo] } }
    }

    /// Spherical k-means (cosine), seeded k-means++ style from a fixed seed, so the same index gives the same groups.
    /// Returns each vector's group, numbered from 0 with no gaps.
    static func kMeans(_ vectors: [[Float]], groups: Int, iterations: Int = 25) -> [Int] {
        let count = vectors.count
        guard count > 0, groups > 1 else { return Array(repeating: 0, count: count) }
        let dimension = vectors[0].count
        let matrix = vectors.flatMap { $0 }
        var random = SeededRandom(seed: 0x5EED)
        func similarities(to centroid: [Float]) -> [Float] {
            var scores = [Float](repeating: 0, count: count)
            matrix.withUnsafeBufferPointer { rows in
                centroid.withUnsafeBufferPointer { query in
                    scores.withUnsafeMutableBufferPointer {
                        Vectors.scores(of: rows.baseAddress!, count: count, query: query.baseAddress!, into: $0.baseAddress!)
                    }
                }
            }
            return scores
        }
        // Seeds: each next one far (in cosine) from the ones picked, with probability by distance².
        var centroids = [vectors[Int(random.next() % UInt64(count))]]
        var nearest = similarities(to: centroids[0])
        while centroids.count < groups {
            let weights = nearest.map { max(0, 1 - $0) * max(0, 1 - $0) }
            let total = weights.reduce(0, +)
            guard total > 0 else { break }   // everything is the same picture
            var pick = Float(Double(random.next() % 1_000_000) / 1_000_000) * total
            var chosen = count - 1
            for (index, weight) in weights.enumerated() {
                pick -= weight
                if pick <= 0 { chosen = index; break }
            }
            centroids.append(vectors[chosen])
            let next = similarities(to: vectors[chosen])
            nearest = zip(nearest, next).map { max($0, $1) }
        }
        var assignment = [Int](repeating: 0, count: count)
        for _ in 0..<iterations {
            var best = [Float](repeating: -.infinity, count: count)
            var next = assignment
            for (group, centroid) in centroids.enumerated() {
                for (index, score) in similarities(to: centroid).enumerated() where score > best[index] {
                    best[index] = score
                    next[index] = group
                }
            }
            let changed = next != assignment
            assignment = next
            var sums = [Float](repeating: 0, count: centroids.count * dimension)
            var sizes = [Int](repeating: 0, count: centroids.count)
            sums.withUnsafeMutableBufferPointer { sums in
                matrix.withUnsafeBufferPointer { rows in
                    for (index, group) in assignment.enumerated() {
                        sizes[group] += 1
                        for d in 0..<dimension { sums[group * dimension + d] += rows[index * dimension + d] }
                    }
                }
            }
            centroids = centroids.indices.map { group in   // an emptied group keeps its seed
                sizes[group] == 0 ? centroids[group]
                    : normalized(Array(sums[(group * dimension)..<((group + 1) * dimension)]))
            }
            if !changed { break }
        }
        // Renumber the groups in use, biggest first.
        let sizes = Dictionary(grouping: assignment.indices, by: { assignment[$0] }).mapValues(\.count)
        let order = sizes.keys.sorted { sizes[$0]! > sizes[$1]! || sizes[$0]! == sizes[$1]! && $0 < $1 }
        let renumber = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return assignment.map { renumber[$0]! }
    }
}

/// xorshift64*: a few lines, no platform differences.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2685821657736338717
    }
}
