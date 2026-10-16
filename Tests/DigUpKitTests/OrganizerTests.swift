import Foundation
import Testing
@testable import DigUpKit

@Suite struct OrganizerTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpOrganize-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A unit vector near `center`: `center` plus a little of another text's vector.
    func near(_ center: [Float], _ seed: String, by amount: Float = 0.25) -> [Float] {
        Organizer.normalized(zip(center, FakeEmbedder.vector(for: seed)).map { $0 + amount * $1 })
    }

    func labelVector(_ phrase: String) -> [Float] { FakeEmbedder.vector(for: Prompts.query("a photo of \(phrase)")) }

    /// A real file under `pictures/`, indexed as a done photo with `vector`.
    @discardableResult
    func photo(_ name: String, _ vector: [Float], store: IndexStore, inode: UInt64) throws -> String {
        let path = folder.appendingPathComponent("pictures/\(name)").path
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(name.utf8).write(to: URL(fileURLWithPath: path))
        let id = try store.insert(Candidate(path: path, kind: .image, size: 1, mtime: 1, inode: inode, device: 1))
        try store.addSegment(file: id, kind: .image, modality: .image, vector: vector)
        try store.finish(id, state: "done")
        return path
    }

    @Test func kMeansFindsSeparateGroups() {
        let a = FakeEmbedder.vector(for: "a"), b = FakeEmbedder.vector(for: "b")
        let vectors = (0..<6).map { near(a, "a\($0)") } + (0..<6).map { near(b, "b\($0)") }
        let groups = Organizer.kMeans(vectors, groups: 2)
        #expect(Set(groups[0..<6]).count == 1)
        #expect(Set(groups[6..<12]).count == 1)
        #expect(groups[0] != groups[6])
    }

    @Test func photosGoToTheFolderTheyFit() throws {
        let store = try IndexStore(directory: folder)
        var inode: UInt64 = 1
        for index in 0..<4 {
            try photo("beach\(index).jpg", near(labelVector("Beach"), "s\(index)"), store: store, inode: inode); inode += 1
            try photo("food\(index).jpg", near(labelVector("Food"), "f\(index)"), store: store, inode: inode); inode += 1
            try photo("other\(index).jpg", FakeEmbedder.vector(for: "other\(index)"), store: store, inode: inode); inode += 1
        }
        let destination = folder.appendingPathComponent("Organised").path
        let plan = try Organizer.planPhotos(store, under: [folder.path], destination: destination,
                                            embedder: FakeEmbedder(), labels: ["Beach", "Food", "Cars"])
        let byName = Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.name, $0.moves) })
        #expect(Set(byName.keys) == ["Beach", "Food"])
        #expect(byName["Beach"]?.allSatisfy { ($0.from as NSString).lastPathComponent.hasPrefix("beach") } == true)
        #expect(byName["Beach"]?.count == 4)
        #expect(byName["Food"]?.allSatisfy { $0.to.hasPrefix(destination + "/Food/") } == true)
        #expect(plan.leftInPlace.count == 4)
    }

    @Test func applyMovesAndUndoPutsBack() throws {
        let store = try IndexStore(directory: folder)
        let path = try photo("dog.jpg", FakeEmbedder.vector(for: "dog"), store: store, inode: 1)
        // Something is already called dog.jpg where it's going: the move must not overwrite it.
        let target = folder.appendingPathComponent("Organised/Dogs/dog.jpg").path
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("already here".utf8).write(to: URL(fileURLWithPath: target))
        let plan = Organizer.Plan(title: "test", destination: folder.appendingPathComponent("Organised").path,
                                  groups: [.init(name: "Dogs", fit: nil, moves: [.init(fileID: nil, from: path, to: target)])],
                                  leftInPlace: [], created: Date())
        let batch = try Organizer.apply(plan, store: store)
        let moved = folder.appendingPathComponent("Organised/Dogs/dog 2.jpg").path
        #expect(batch.moves.map(\.to) == [moved])
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "already here")
        #expect(store.fileID(at: moved) != nil && store.fileID(at: path) == nil)   // the index followed, no re-embedding
        #expect(Organizer.loadJournal(in: folder).count == 1)

        let undone = try Organizer.undo(store: store)
        #expect(undone?.skipped.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(store.fileID(at: path) != nil)
        #expect(FileManager.default.fileExists(atPath: target))   // the folder had something else in it, so it stays
        #expect(Organizer.loadJournal(in: folder).isEmpty)
        #expect(try Organizer.undo(store: store) == nil)
    }

    @Test func searchPlanTakesStrongResultsOnly() {
        func hit(_ path: String, _ score: Double) -> SearchHit {
            SearchHit(path: path, kind: .pdf, score: score, z: nil, cosine: nil, keywordRank: nil, segment: .page,
                      segmentID: 0, loc: nil, locEnd: nil, excerpt: nil, modified: 0, size: 0, info: [:], focus: nil)
        }
        let hits = [hit("/a/receipt1.pdf", 1.0), hit("/b/receipt2.pdf", 0.8), hit("/c/note.pdf", 0.2)]
        let plan = Organizer.planSearch(hits, query: "receipts", destination: "/Finance/Receipts")
        #expect(plan.moves.map(\.to) == ["/Finance/Receipts/receipt1.pdf", "/Finance/Receipts/receipt2.pdf"])
        #expect(Organizer.planSearch(hits, query: "receipts", destination: "/x", everything: true).moves.count == 3)
    }
}
