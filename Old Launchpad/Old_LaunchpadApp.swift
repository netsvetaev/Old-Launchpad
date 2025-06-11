//
//  Old_LaunchpadApp.swift
//
//  Complete version with swap-or-group logic (3-second hover),
//  pop-over folders, and page swipe threshold = ¼ window width.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: — App Entry
@main
struct OldLaunchpadApp: App {
    @State private var showAbout = false

    var body: some Scene {
        WindowGroup {
            LaunchpadView()
                .frame(minWidth: 800, minHeight: 600)
                .sheet(isPresented: $showAbout) { AboutView() }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Old Launchpad…") { showAbout = true }
            }
        }
        .windowStyle(.hiddenTitleBar)        // macOS 13+ hides title bar
    }
}

// MARK: — Models
struct AppInfo: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let path: String
    let icon: NSImage

    enum CodingKeys: String, CodingKey {
        case id, name, path
    }

    init(id: UUID = UUID(), name: String, path: String, icon: NSImage) {
        self.id = id
        self.name = name
        self.path = path
        self.icon = icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        // icon will be loaded later
        icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        // icon is not encoded
    }
}

struct AppFolder: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var items: [AppInfo]

    init(id: UUID = UUID(), name: String, items: [AppInfo]) {
        self.id = id
        self.name = name
        self.items = items
    }
}

enum LaunchpadElement: Identifiable, Equatable, Codable {
    case app(AppInfo)
    case folder(AppFolder)
    case empty(UUID)           // placeholder for page-padding

    var id: UUID {
        switch self {
        case .app(let a):        return a.id
        case .folder(let f):     return f.id
        case .empty(let id):     return id
        }
    }

    enum CodingKeys: String, CodingKey { case type, app, folder, id }
    enum Kind: String, Codable { case app, folder, empty }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .app:
            self = .app(try c.decode(AppInfo.self, forKey: .app))
        case .folder:
            self = .folder(try c.decode(AppFolder.self, forKey: .folder))
        case .empty:
            let id = try c.decode(UUID.self, forKey: .id)
            self = .empty(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let a):
            try c.encode(Kind.app, forKey: .type)
            try c.encode(a, forKey: .app)
        case .folder(let f):
            try c.encode(Kind.folder, forKey: .type)
            try c.encode(f, forKey: .folder)
        case .empty(let id):
            try c.encode(Kind.empty, forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }
}

// MARK: — Blur Background
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: — ViewModel
class LaunchpadViewModel: ObservableObject {
    @Published var items: [LaunchpadElement] = [] {
        didSet { saveLayout() }
    }
    @Published var searchQuery = ""
    @Published var draggingID: UUID? = nil
    @Published var activeFolderID: UUID? = nil          // pop-over

    private var hoverTimer: Timer? = nil                // 1.5-sec timer
    fileprivate var pendingPair: (UUID, UUID)? = nil        // (drag, over)

    private let iconsPerPage = 35
    
    private var appFolderSources: [DispatchSourceFileSystemObject] = []

    // Autoupdate icons
    func startWatchingFolders() {
        let paths = ["/Applications", "\(NSHomeDirectory())/Applications"]
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd != -1 else { continue }

            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib],
                queue: DispatchQueue.main)

            src.setEventHandler { [weak self] in
                self?.debounceRefresh()
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            appFolderSources.append(src)
        }
    }

    private var refreshWorkItem: DispatchWorkItem?
    private func debounceRefresh() {
        refreshWorkItem?.cancel()
        refreshWorkItem = DispatchWorkItem { [weak self] in self?.refreshApps() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: refreshWorkItem!)
    }

    // MARK: - Persistence
    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("launchpad_layout.json")
    }

    private func loadSavedLayout() -> [LaunchpadElement]? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONDecoder().decode([LaunchpadElement].self, from: data)
    }

    private func saveLayout() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: storeURL)
        }
    }

    init() {
        if let saved = loadSavedLayout() {
            items = saved
        } else {
            loadApps()
        }
        // begin live monitoring of /Applications and ~/Applications
        startWatchingFolders()
    }

    // load applications from /Applications and ~/Applications
    private func loadApps() {
        let dirs = ["/Applications", "\(NSHomeDirectory())/Applications"]
        var found: [AppInfo] = []

        for dir in dirs {
            if let topItems = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for entry in topItems where entry.hasSuffix(".app") {
                    let fullPath = (dir as NSString).appendingPathComponent(entry)
                    let name = (entry as NSString).deletingPathExtension
                    let icon = NSWorkspace.shared.icon(forFile: fullPath)
                    icon.size = NSSize(width: 64, height: 64)
                    found.append(AppInfo(name: name, path: fullPath, icon: icon))
                }
            }
        }

        items = found
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .map { .app($0) }

        // pad to full pages with placeholders
        let remainder = items.count % iconsPerPage
        if remainder != 0 {
            let pad = iconsPerPage - remainder
            items.append(contentsOf: (0..<pad).map { _ in .empty(UUID()) })
        }
    }

    // Scan /Applications and ~/Applications again and append any NEW apps
    // to the end of the grid (before padding).
    func refreshApps() {
        let dirs = ["/Applications", "\(NSHomeDirectory())/Applications"]

        // 1. Scan
        var validPaths: Set<String> = []
        for dir in dirs {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for entry in entries where entry.hasSuffix(".app") {
                    let full = (dir as NSString).appendingPathComponent(entry)
                    validPaths.insert(full)
                }
            }
        }

        // 2. Erase deleted
        items.removeAll { element in
            if case .app(let a) = element { return !validPaths.contains(a.path) }
            return false
        }

        let existing = Set(items.compactMap {
            if case .app(let a) = $0 { return a.path } else { return nil }
        })

        var newly: [AppInfo] = []
        for path in validPaths.subtracting(existing) {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let icon = NSWorkspace.shared.icon(forFile: path);  icon.size = NSSize(width: 64, height: 64)
            newly.append(AppInfo(name: name, path: path, icon: icon))
        }
        guard !newly.isEmpty else { return }

        items.removeAll { if case .empty = $0 { return true } else { return false } }

        newly.sort { $0.name.lowercased() < $1.name.lowercased() }
        items.append(contentsOf: newly.map { .app($0) })

        let rem = items.count % iconsPerPage
        if rem != 0 {
            items.append(contentsOf: (0..<(iconsPerPage - rem)).map { _ in .empty(UUID()) })
        }
    }

    func hideApp() {
        NSApp.hide(nil)
    }

    // Search filter
    var filtered: [LaunchpadElement] {
        guard !searchQuery.isEmpty else { return items }
        return items.filter {
            switch $0 {
            case .app(let a):
                return a.name.lowercased().contains(searchQuery.lowercased())
            case .folder(let f):
                return f.items.contains { $0.name.lowercased().contains(searchQuery.lowercased()) }
            case .empty:
                return false
            }
        }
    }

    // Pages (35 icons each)
    var pages: [[LaunchpadElement]] {
        stride(from: 0, to: filtered.count, by: iconsPerPage).map {
            Array(filtered[$0..<min($0 + iconsPerPage, filtered.count)])
        }
    }

    // Swap icons
    func move(from: Int, to: Int, page: Int) {
        let gFrom = page * iconsPerPage + from
        let gTo   = page * iconsPerPage + to
        guard gFrom != gTo,
              items.indices.contains(gFrom),
              items.indices.contains(gTo) else { return }

        withAnimation {
            items.swapAt(gFrom, gTo)
        }
    }

    // Called by drop-delegate
    func handleDrop(dragID: UUID, overID: UUID, longHover: Bool) {
        guard let src = items.firstIndex(where: { $0.id == dragID }),
              let dst = items.firstIndex(where: { $0.id == overID }) else { return }

        // Drop icon from a folder
        let srcRootIdx = items.firstIndex(where: { $0.id == dragID })
        if srcRootIdx == nil && !longHover {
            // Add icon to the right
            var insertPos = dst + 1

            let pageStart = (insertPos / iconsPerPage) * iconsPerPage
            let pageEnd   = pageStart + iconsPerPage - 1

            // Place icon to the same screen
            if insertPos > pageEnd { insertPos = pageEnd }

            withAnimation {
                var app: AppInfo? = nil
                for element in items {
                    if case .folder(let folder) = element {
                        if let found = folder.items.first(where: { $0.id == dragID }) {
                            app = found
                            break
                        }
                    }
                }
                guard let app = app else { return }

                // Erase icon from folder after drop
                if let folderIdx = items.firstIndex(where: {
                    if case .folder(let f) = $0 {
                        return f.items.contains(where: { $0.id == app.id })
                    }
                    return false
                }), case .folder(var srcFolder) = items[folderIdx] {

                    if let idxInFolder = srcFolder.items.firstIndex(where: { $0.id == app.id }) {
                        srcFolder.items.remove(at: idxInFolder)
                        // If folder is empty, erase the folder
                        items[folderIdx] = srcFolder.items.isEmpty
                            ? .empty(UUID())
                            : .folder(srcFolder)
                    }
                }
                if case .empty = items[insertPos] {
                    items[insertPos] = .app(app)
                } else {

                    if let emptyIdx = (insertPos...pageEnd).first(where: {
                        if case .empty = items[$0] { return true } else { return false }
                    }) {
                        for i in stride(from: emptyIdx, to: insertPos, by: -1) {
                            items[i] = items[i - 1]
                        }
                        items[insertPos] = .app(app)
                    }
                }
                normalizePage(fromIndex: insertPos)
            }
            return
        }

        if longHover {
            switch (items[src], items[dst]) {

            // ➜ Drop APP onto FOLDER → append
            case (.app(let appToAdd), .folder(var folder)):
                // avoid duplicates
                if !folder.items.contains(where: { $0.id == appToAdd.id }) {
                    folder.items.append(appToAdd)
                }
                withAnimation {
                    items[src] = .empty(UUID())
                    items[dst] = .folder(folder)
                    normalizeAllPages()
                }

            // ➜ Drop APP onto APP → create new folder
            case (.app(let a1), .app(let a2)):
                let folder = AppFolder(name: a2.name, items: [a2, a1])
                withAnimation {
                    items[dst] = .folder(folder)
                    items[src] = .empty(UUID())

                    normalizeAllPages()
                }

            default:
                // fall back to simple swap
                withAnimation { items.swapAt(src, dst) }
            }
        } else {
            // simple swap when not hovering long
            withAnimation { items.swapAt(src, dst) }
        }
    }

    // pop-over toggler
    func toggleFolder(_ id: UUID) {
        activeFolderID = (activeFolderID == id) ? nil : id
    }

    // Launch app
    func launch(_ app: AppInfo) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
    }

    // Helpers for timer
    func startHoverTimer(dragID: UUID, overID: UUID) {
        guard pendingPair == nil else { return }
        pendingPair = (dragID, overID)
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.handleDrop(dragID: dragID, overID: overID, longHover: true)
            self?.pendingPair = nil
            self?.hoverTimer = nil
        }
    }
    func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        pendingPair = nil
    }
    // Delete app from grid or folder
    func deleteApp(id: UUID) {
        // Try root level first
        if let idx = items.firstIndex(where: { $0.id == id }) {
            // page bounds
            let pageStart = (idx / iconsPerPage) * iconsPerPage
            let pageEnd   = pageStart + iconsPerPage - 1

            withAnimation {
                // shift left inside page
                for i in idx..<pageEnd {
                    items[i] = items[i + 1]
                }
                // place placeholder at pageEnd
                items[pageEnd] = .empty(UUID())
            }
            normalizePage(fromIndex: idx)
            return
        }
        // Find inside a folder
        if let fIdx = items.firstIndex(where: {
            if case .folder(let f) = $0 { return f.items.contains { $0.id == id } }
            return false
        }), case .folder(var folder) = items[fIdx] {
            folder.items.removeAll { $0.id == id }
            withAnimation {
                if folder.items.isEmpty {
                    items[fIdx] = .empty(UUID())
                    normalizeAllPages()
                } else {
                    items[fIdx] = .folder(folder)
                }
            }
        }
    }

    // Re-order icons inside a folder
    func reorderInFolder(folderID: UUID, from: Int, to: Int) {
        guard let idx = items.firstIndex(where: { $0.id == folderID }),
              case .folder(var folder) = items[idx],
              folder.items.indices.contains(from),
              folder.items.indices.contains(to) else { return }

        let a = folder.items.remove(at: from)
        folder.items.insert(a, at: to)
        items[idx] = .folder(folder)
        normalizePage(fromIndex: idx)
    }
    func returnApp(appID: UUID, fromFolder folderID: UUID) {
        guard let folderIndex = items.firstIndex(where: { $0.id == folderID }),
              case .folder(var folder) = items[folderIndex],
              let insideIdx = folder.items.firstIndex(where: { $0.id == appID }) else { return }

        let app = folder.items.remove(at: insideIdx)

        // 1. If folder is empty, swap it with the last icon
        if folder.items.isEmpty {
            items[folderIndex] = .app(app)
            normalizeAllPages()
            return
        }

        // 2. If not, update
        items[folderIndex] = .folder(folder)

        // 3. Add to the same screen
        let insertPos = min(folderIndex + 1, items.count - 1)
        let pageEnd = ((insertPos / iconsPerPage) + 1) * iconsPerPage - 1

        if case .empty = items[insertPos] {
            items[insertPos] = .app(app)
        } else {
            if let emptyIdx = (insertPos...pageEnd).first(where: {
                if case .empty = items[$0] { return true } else { return false }
            }) {
                for i in stride(from: emptyIdx, to: insertPos, by: -1) {
                    items[i] = items[i - 1]
                }
                items[insertPos] = .app(app)
            }
        }
        normalizePage(fromIndex: insertPos)
    }

    private func normalizeAllPages() {
        guard !items.isEmpty else { return }
        let pageCount = (items.count + iconsPerPage - 1) / iconsPerPage
        for page in 0..<pageCount {
            let start = page * iconsPerPage
            let end   = min(start + iconsPerPage, items.count) - 1
            var writePtr = start
            for readPtr in start...end {
                if case .empty = items[readPtr] { continue }
                items[writePtr] = items[readPtr]
                writePtr += 1
            }
            while writePtr <= end {
                items[writePtr] = .empty(UUID())
                writePtr += 1
            }
        }
    }
    
    private func normalizePage(fromIndex idx: Int) {
        let pageStart = (idx / iconsPerPage) * iconsPerPage
        let pageEnd   = pageStart + iconsPerPage - 1

        // Arrange icons to the left
        var writePtr = pageStart
        for readPtr in pageStart...pageEnd {
            if case .empty = items[readPtr] { continue }
            items[writePtr] = items[readPtr]
            writePtr += 1
        }
        // Add placeholders after that
        while writePtr <= pageEnd {
            items[writePtr] = .empty(UUID())
            writePtr += 1
        }
    }
}



// MARK: — Drop-Delegate
struct IconDropDelegate: DropDelegate {
    let dragID: UUID
    let overID: UUID
    @ObservedObject var vm: LaunchpadViewModel

    func dropEntered(info: DropInfo) {
        vm.startHoverTimer(dragID: dragID, overID: overID)
    }

    func dropExited(info: DropInfo) { vm.cancelHoverTimer() }

    func performDrop(info: DropInfo) -> Bool {
        // Ignore drop if over a placeholder
        if case .empty = vm.items.first(where: { $0.id == overID }) {
            return false
        }
        // If timer fired, pendingPair == nil ⇒ longHover = true handled already
        let longHover = vm.pendingPair == nil
        vm.handleDrop(dragID: dragID, overID: overID, longHover: longHover)
        vm.cancelHoverTimer()
        return true
    }
}

struct FolderReorderDropDelegate: DropDelegate {
    let folderID: UUID
    let from: Int
    let to: Int
    @ObservedObject var vm: LaunchpadViewModel

    func performDrop(info: DropInfo) -> Bool {
        vm.reorderInFolder(folderID: folderID, from: from, to: to)
        return true
    }
}

// MARK: — Icon, Folder, SearchBar
struct IconView: View {
    let app: AppInfo
    let size: CGFloat
    @ObservedObject var vm: LaunchpadViewModel

    @State private var pressed = false
    var body: some View {
        VStack {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: size, height: size)
            Text(app.name)
                .font(.system(size: 16, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .scaleEffect(pressed ? 0.8 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: pressed)
        .onTapGesture {
            pressed = true                       // start shrink
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pressed = false                  // bounce back
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                vm.launch(app)            // launch after bounce
            }
        }
        .onDrag {
            vm.draggingID = app.id
            return NSItemProvider(object: app.id.uuidString as NSString)
        }
        .contextMenu {
            Button("Delete Icon") { vm.deleteApp(id: app.id) }
        }
    }
}

struct FolderView: View {
    let folder: AppFolder
    let size: CGFloat
    @ObservedObject var vm: LaunchpadViewModel

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // light‑gray rounded background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.systemGray))

                let cols = Array(repeating: GridItem(.flexible()), count: 3)
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(folder.items.prefix(9), id: \.id) { app in
                        Image(nsImage: app.icon)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .padding(4)
            }
            .frame(width: size, height: size)

            Text(folder.name)
                .font(.system(size: 16, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .onTapGesture { vm.toggleFolder(folder.id) }
        .onDrag {
            vm.draggingID = folder.id
            return NSItemProvider(object: folder.id.uuidString as NSString)
        }
    }
}

struct SearchBar: View {
    @Binding var text: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
            TextField("Search…", text: $text)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
        }
        .padding(.horizontal, 24)
    }
}

// MARK: — Folder Pop-over
struct FolderPopover: View {
    let folder: AppFolder
    @ObservedObject var vm: LaunchpadViewModel

    var body: some View {
        GeometryReader { geo in
            // подгоняем размер как в PageView: до 160-px
            let rows = max(ceil(Double(folder.items.count) / 3.0), 3)
            let cellH = geo.size.height / CGFloat(rows)
            let iconSize = min(cellH * 0.8, 160)

            let cols = [GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())]

            VStack(spacing: 20) {
                LazyVGrid(columns: cols, spacing: 20) {
                    ForEach(Array(folder.items.enumerated()), id: \.1.id) { idx, app in
                        IconView(app: app, size: iconSize, vm: vm)
                            .onDrag {
                                vm.draggingID = app.id
                                return NSItemProvider(object: app.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: FolderReorderDropDelegate(
                                    folderID: folder.id,
                                    from: folder.items.firstIndex(where: { $0.id == vm.draggingID ?? app.id }) ?? idx,
                                    to: idx,
                                    vm: vm
                                )
                            )
                            .contextMenu {
                                Button("Delete Icon") {
                                    vm.deleteApp(id: app.id)
                                }
                            }
                    }
                }
            }
            .padding(20)
            .background(Color(NSColor.systemGray),
                        in: RoundedRectangle(cornerRadius: 12))
            // centered
            .frame(maxWidth: 500, maxHeight: 500)
            .position(x: geo.size.width / 2,
                      y: geo.size.height / 2)
        }
    }
}

private struct PageOffsetKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int : CGFloat], nextValue: () -> [Int : CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: — PageView (fills height evenly)
struct PageView: View {
    let index: Int
    let items: [LaunchpadElement]
    let width: CGFloat
    @ObservedObject var vm: LaunchpadViewModel

    private let columns = Array(repeating: GridItem(.flexible()), count: 7)
    private let rows = 5

    var body: some View {
        GeometryReader { geo in
            let cellH = geo.size.height / CGFloat(rows)
            let iconSize = min(cellH * 0.8, 160)   // 64‑px base, up to x2.5

            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(items) { element in
                    Group {
                        switch element {
                        case .app(let app):
                            IconView(app: app, size: iconSize, vm: vm)
                        case .folder(let folder):
                            FolderView(folder: folder, size: iconSize, vm: vm)
                        case .empty:
                            Color.clear.frame(width: iconSize, height: iconSize)
                        }
                    }
                    .frame(maxWidth: .infinity,
                           minHeight: cellH,
                           maxHeight: cellH)
                    .onDrop(
                        of: [UTType.text],
                        delegate: IconDropDelegate(
                            dragID: vm.draggingID ?? element.id,
                            overID: element.id,
                            vm: vm
                        )
                    )
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
        }
        .background(
            GeometryReader { g in
                Color.clear
                    .preference(key: PageOffsetKey.self,
                                value: [index: g.frame(in: .named("scroll")).minX])
            }
        )
    }
}

// Overlay that shows the blurred backdrop + popover when a folder is open
private struct FolderOverlayView: View {
    @ObservedObject var vm: LaunchpadViewModel

    var body: some View {
        Group {
            if let fid = vm.activeFolderID,
               case .folder(let folder) = vm.items.first(where: { $0.id == fid }) {

                // transparent layer to capture taps & drops
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { vm.activeFolderID = nil }
                    .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                        if let dragID = vm.draggingID {
                            vm.returnApp(appID: dragID, fromFolder: fid)
                            vm.draggingID = nil
                            return true
                        }
                        return false
                    }

                FolderPopover(folder: folder, vm: vm)
                    .transition(.scale)
            }
        }
    }
}

// MARK: — LaunchpadView
struct LaunchpadView: View {
    @StateObject private var vm = LaunchpadViewModel()
    @State private var currentPage = 0
    private func clampPage() {
        if currentPage >= vm.pages.count { currentPage = max(vm.pages.count - 1, 0) }
    }

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground,
                             blendingMode: .behindWindow)
            .ignoresSafeArea()

            VStack(spacing: 12) {
                SearchBar(text: $vm.searchQuery)
                    .frame(width: 300)                     // fixed width
                    .frame(maxWidth: .infinity)            // centered
                    .padding(.top, 20)

                GeometryReader { geo in
                    let pageW = geo.size.width
                    let pageH = geo.size.height - 60

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false)    // pages
                        {
                            HStack(spacing: 0) {
                                ForEach(vm.pages.indices, id: \.self) { idx in
                                    PageView(index: idx,
                                             items: vm.pages[idx],
                                             width: pageW,
                                             vm: vm)
                                    .frame(width: pageW, height: pageH, alignment: .topLeading)
                                    .id(idx)
                                    .onAppear { currentPage = idx }
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if vm.activeFolderID != nil {
                                    vm.activeFolderID = nil      // close folder
                                } else {
                                    vm.hideApp()                 // hide Launchpad
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .coordinateSpace(name: "scroll")   // <— modifier after the content
                        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))   // Removed as per instructions
                        .blur(radius: vm.activeFolderID == nil ? 0 : 8)
                        .onChange(of: currentPage) { new in
                            withAnimation(.interactiveSpring(response: 0.35,
                                                             dampingFraction: 0.85,
                                                             blendDuration: 0)) {
                                proxy.scrollTo(new, anchor: .leading)
                            }
                        }
                        .gesture(
                            DragGesture().onEnded { val in
                                let delta = val.translation.width
                                var next = currentPage
                                if delta < -pageW / 8,  next < vm.pages.count - 1 { next += 1 }
                                if delta >  pageW / 8,  next > 0                  { next -= 1 }
                                // same settings
                                withAnimation(.interactiveSpring(response: 0.35,
                                                                 dampingFraction: 0.85,
                                                                 blendDuration: 0)) {
                                    currentPage = next
                                }
                            }
                        )
                        .onPreferenceChange(PageOffsetKey.self) { offsets in
                            // pick the page with the smallest |offset| (closest to leading edge)
                            if let nearest = offsets.min(by: { abs($0.value) < abs($1.value) })?.key {
                                currentPage = nearest
                            }
                        }
                        // Folder pop-over overlay
                        .overlay(FolderOverlayView(vm: vm))
                    }
                }
                .frame(maxHeight: .infinity)
                .onChange(of: vm.pages.count) { _ in clampPage() }

                // Page indicator
                HStack(spacing: 8) {
                    ForEach(vm.pages.indices, id: \.self) { i in
                        Circle()
                            .fill(i == currentPage ? Color.white : Color.gray)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.bottom, 8)
            }
            .onAppear {
                if let win = NSApp.windows.first,
                   let screen = NSScreen.main {

                    // Resize window to fill the *visible* area of the main screen
                    win.setFrame(screen.visibleFrame, display: true)

                    // Hide close / minimize / zoom buttons
                    win.standardWindowButton(.closeButton)?.isHidden = true
                    win.standardWindowButton(.miniaturizeButton)?.isHidden = true
                    win.standardWindowButton(.zoomButton)?.isHidden = true

                    // Hide title completely
                    win.titleVisibility = .hidden
                    win.titlebarAppearsTransparent = true
                }
                // refresh grid with any new apps just installed
                vm.refreshApps()
            }
        }
    }
}


struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appIcon: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .cornerRadius(16)
            } else {
                Image(systemName: "app")
                    .font(.system(size: 64))
            }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            appIcon
            Text("Old Launchpad")
                .font(.title2).bold()
            Text("Version 1.0\n© 2025 Artur Netsvetaev")
                .multilineTextAlignment(.center)

            Link("netsvetaev.com", destination: URL(string: "https://netsvetaev.com")!)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
                .underline()

            Button("Close") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
        }
        .padding(80)
        .frame(width: 400)
    }
}
