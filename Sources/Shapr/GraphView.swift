import AppKit
import SwiftUI

// MARK: - The map of a pack: what's in it, and what belongs together

/// A pack as a graph: a dot for each capture, a ring for each topic two or more captures share, and
/// a line from each capture to its topics. Very similar captures are also joined directly.
/// Worked out on this Mac from the words in the captures; nothing is sent anywhere.
struct PackGraph: Equatable {
    struct Node: Identifiable, Equatable {
        enum Kind: Equatable { case capture(UUID), topic }
        let id: String
        let kind: Kind
        var label: String
        var degree = 0
        var isTopic: Bool { kind == .topic }
    }

    struct Edge: Equatable {
        let a: Int
        let b: Int
        /// Capture to capture (they read alike), rather than capture to topic.
        let direct: Bool
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    /// Captures left off the map (only the newest ones are drawn in a very large pack).
    var hidden = 0

    var captureCount: Int { nodes.count { !$0.isTopic } }
    var topicCount: Int { nodes.count { $0.isTopic } }

    /// Who each node is joined to.
    var neighbors: [Set<Int>] {
        var out = [Set<Int>](repeating: [], count: nodes.count)
        for e in edges {
            out[e.a].insert(e.b)
            out[e.b].insert(e.a)
        }
        return out
    }

    /// Words that say nothing about what a capture is about.
    private static let noise: Set<String> = ["http", "https", "www", "com", "html", "page", "pages", "click", "here", "also", "will",
        "want", "need", "make", "made", "take", "used", "many", "much", "well", "even", "still", "back", "said", "says", "going",
        "really", "thing", "things", "something", "because", "while", "after", "before", "first", "second", "third", "next",
        "last", "note", "notes", "untitled", "screenshot", "capture", "today", "tomorrow", "yesterday", "every", "true", "false"]

    static func build(_ pack: Pack, limit: Int = 250) -> PackGraph {
        let captures = Array(pack.captures.suffix(limit))
        let n = captures.count
        var g = PackGraph()
        g.hidden = pack.captures.count - n
        guard n > 0 else { return g }

        // Words per capture (the title counts double), by stem, remembering how each stem is usually written.
        var stems: [String: String?] = [:]
        var written: [String: [String: Int]] = [:]
        var tf: [[String: Double]] = []
        for c in captures {
            var counts: [String: Double] = [:]
            func add(_ text: String, weight: Double) {
                for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
                    let w = String(raw)
                    guard w.count >= 4, !noise.contains(w), !w.contains(where: \.isNumber) else { continue }
                    let stem: String?
                    if let known = stems[w] { stem = known } else {
                        stem = PackAssist.tokens(w).first
                        stems[w] = stem
                    }
                    guard let stem else { continue }
                    counts[stem, default: 0] += weight
                    written[stem, default: [:]][w, default: 0] += 1
                }
            }
            add(c.displayTitle, weight: 2)
            add(String(c.text.prefix(8000)), weight: 1)
            tf.append(counts)
        }
        var df: [String: Int] = [:]
        for counts in tf { for k in counts.keys { df[k, default: 0] += 1 } }
        func idf(_ term: String) -> Double { log(1 + Double(n) / Double(df[term] ?? 1)) }

        // Topics: words two or more captures share, but not ones nearly every capture has.
        let most = n < 6 ? n : Int((Double(n) * 0.8).rounded(.down))
        var scored: [(term: String, score: Double, members: Set<Int>)] = []
        for (term, count) in df where count >= 2 && count <= most {
            var score = 0.0
            var members = Set<Int>()
            for (i, counts) in tf.enumerated() {
                guard let v = counts[term] else { continue }
                score += min(v, 4) * idf(term)
                members.insert(i)
            }
            scored.append((term, score, members))
        }
        scored.sort { ($0.score, $1.term) > ($1.score, $0.term) }
        var topics: [(term: String, members: Set<Int>)] = []
        let wanted = min(10, max(1, (n + 1) / 2 + 1))
        for s in scored {
            guard topics.count < wanted else { break }
            // Two words that mark out the same captures are one topic.
            let twin = topics.contains { t in
                Double(t.members.intersection(s.members).count) / Double(t.members.union(s.members).count) >= 0.9
            }
            if !twin { topics.append((s.term, s.members)) }
        }

        // Each capture joins its three strongest topics; a topic left with one capture isn't one.
        var links: [Int: [Int]] = [:]
        for i in 0..<n {
            let mine = topics.indices.filter { topics[$0].members.contains(i) }
                .sorted { (tf[i][topics[$0].term] ?? 0, $1) > (tf[i][topics[$1].term] ?? 0, $0) }
                .prefix(3)
            for t in mine { links[t, default: []].append(i) }
        }

        g.nodes = captures.map { Node(id: $0.id.uuidString, kind: .capture($0.id), label: $0.displayTitle.singleLine.truncated(32)) }
        var shareTopic = Set<[Int]>()
        for t in topics.indices {
            guard let members = links[t], members.count >= 2 else { continue }
            let term = topics[t].term
            let label = written[term]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? term
            let index = g.nodes.count
            g.nodes.append(Node(id: "#" + term, kind: .topic, label: label))
            for m in members { g.edges.append(Edge(a: m, b: index, direct: false)) }
            for a in members { for b in members where a < b { shareTopic.insert([a, b]) } }
        }

        // Captures that read alike are joined directly: always when very alike, and when they'd
        // otherwise have nothing between them.
        var vectors: [[String: Double]] = []
        var norms: [Double] = []
        for counts in tf {
            var v: [String: Double] = [:]
            var sum = 0.0
            for (term, count) in counts {
                let w = (1 + log(count)) * idf(term)
                v[term] = w
                sum += w * w
            }
            vectors.append(v)
            norms.append(sum.squareRoot())
        }
        var direct = Set<[Int]>()
        for i in 0..<n where norms[i] > 0 {
            var best: [(j: Int, cos: Double)] = []
            for j in 0..<n where j != i && norms[j] > 0 {
                let (small, large) = vectors[i].count < vectors[j].count ? (vectors[i], vectors[j]) : (vectors[j], vectors[i])
                var dot = 0.0
                for (term, w) in small { if let o = large[term] { dot += w * o } }
                let cos = dot / (norms[i] * norms[j])
                let pair = [min(i, j), max(i, j)]
                if cos >= 0.5 || (cos >= 0.3 && !shareTopic.contains(pair)) { best.append((j, cos)) }
            }
            for b in best.sorted(by: { ($0.cos, $1.j) > ($1.cos, $0.j) }).prefix(2) { direct.insert([min(i, b.j), max(i, b.j)]) }
        }
        for pair in direct.sorted(by: { ($0[0], $0[1]) < ($1[0], $1[1]) }) { g.edges.append(Edge(a: pair[0], b: pair[1], direct: true)) }

        for e in g.edges {
            g.nodes[e.a].degree += 1
            g.nodes[e.b].degree += 1
        }
        return g
    }
}

// MARK: - Layout: springs and repulsion, settled before it's shown

/// Places the nodes: joined ones pull together, all of them push apart, and everything leans toward
/// the middle. It settles before the map is first drawn, and only moves again while you drag.
@MainActor
final class GraphSim: ObservableObject {
    private(set) var graph = PackGraph()
    private(set) var neighbors: [Set<Int>] = []
    var pos: [CGPoint] = []
    var dragging: Int?
    private var vel: [CGVector] = []
    private var alpha: CGFloat = 0
    private var timer: Timer?

    deinit { timer?.invalidate() }

    func load(_ g: PackGraph) {
        guard g != graph || pos.count != g.nodes.count else { return }
        // Nodes that were already on the map stay where they are, so adding a capture doesn't reshuffle it.
        let old = Dictionary(zip(graph.nodes.map(\.id), pos), uniquingKeysWith: { a, _ in a })
        graph = g
        neighbors = g.neighbors
        let count = g.nodes.count
        pos = g.nodes.indices.map { i in
            if let p = old[g.nodes[i].id] { return p }
            // A sunflower spiral: spread out, and the same every time.
            let r = 26 * CGFloat(Double(i + 1).squareRoot()), a = Double(i) * 2.399963
            return CGPoint(x: r * cos(a), y: r * sin(a))
        }
        vel = Array(repeating: .zero, count: count)
        alpha = 1
        for _ in 0..<(count > 160 ? 140 : 320) { tick() }
        alpha = 0
        objectWillChange.send()
    }

    /// Lets the map move again for a moment (while a node is dragged).
    func reheat() {
        alpha = max(alpha, 0.35)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
    }

    private func frame() {
        tick()
        objectWillChange.send()
        if alpha < 0.02, dragging == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    func tick() {
        let n = pos.count
        guard n > 0, vel.count == n else { return }
        var force = [CGVector](repeating: .zero, count: n)
        let k: CGFloat = 22
        for i in 0..<n {
            for j in (i + 1)..<n {
                var dx = pos[i].x - pos[j].x, dy = pos[i].y - pos[j].y
                var d2 = dx * dx + dy * dy
                if d2 < 0.01 {
                    dx = 0.1 + CGFloat(j - i) * 0.01
                    dy = 0.1
                    d2 = dx * dx + dy * dy
                }
                guard d2 < 250_000 else { continue }
                let f = k * k / d2
                force[i].dx += dx * f
                force[i].dy += dy * f
                force[j].dx -= dx * f
                force[j].dy -= dy * f
            }
        }
        for e in graph.edges {
            let dx = pos[e.b].x - pos[e.a].x, dy = pos[e.b].y - pos[e.a].y
            let d = max((dx * dx + dy * dy).squareRoot(), 0.1)
            let f = (d - (e.direct ? 90 : 64)) * 0.12 / d
            force[e.a].dx += dx * f
            force[e.a].dy += dy * f
            force[e.b].dx -= dx * f
            force[e.b].dy -= dy * f
        }
        for i in 0..<n {
            guard i != dragging else { vel[i] = .zero; continue }
            vel[i].dx = (vel[i].dx + (force[i].dx - pos[i].x * 0.024) * alpha) * 0.76
            vel[i].dy = (vel[i].dy + (force[i].dy - pos[i].y * 0.024) * alpha) * 0.76
            pos[i].x += min(max(vel[i].dx, -28), 28)
            pos[i].y += min(max(vel[i].dy, -28), 28)
        }
        alpha *= 0.986
    }

    var bounds: CGRect {
        guard let first = pos.first else { return .zero }
        return pos.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
}

// MARK: - The view

/// The pack's map in the library. Hover a dot to see what it's joined to, click it to open the
/// capture beside the map, drag to move, scroll or pinch to zoom.
struct PackGraphView: View {
    let pack: Pack
    @EnvironmentObject var state: LibraryState
    @StateObject private var sim = GraphSim()
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var hovered: Int?
    /// A topic you clicked: its captures stay lit.
    @State private var pinned: Int?
    @State private var pointer: CGPoint?
    @State private var dragFrom: (pan: CGSize, node: Int?)?
    @State private var pinchFrom: CGFloat?
    @State private var size: CGSize = .zero
    @State private var wheel: Any?
    /// You've zoomed or dragged, so resizing the window no longer refits the map.
    @State private var moved = false

    /// Rebuilds when captures are added, removed or edited.
    private var key: [String] { pack.captures.map { $0.id.uuidString + String($0.text.count) } }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2 + pan.width, y: geo.size.height / 2 + pan.height)
            Canvas { ctx, _ in draw(&ctx, center: center) }
                .contentShape(Rectangle())
                .gesture(drag(center: center))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        if pinchFrom == nil { pinchFrom = zoom }
                        setZoom((pinchFrom ?? zoom) * v.magnification, around: pointer ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
                    }
                    .onEnded { _ in pinchFrom = nil })
                .onTapGesture { location in tap(at: location, center: center) }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        pointer = p
                        hovered = node(at: p, center: center)
                    case .ended:
                        pointer = nil
                        hovered = nil
                    }
                }
                .onAppear {
                    size = geo.size
                    sim.load(PackGraph.build(pack))
                    fit(in: geo.size)
                    listenForScroll()
                }
                .onDisappear { if let wheel { NSEvent.removeMonitor(wheel) }; wheel = nil }
                .onChange(of: geo.size) { _, new in
                    size = new
                    if !moved { fit(in: new) }
                }
                .onChange(of: key) { _, _ in
                    sim.load(PackGraph.build(pack))
                    fit(in: geo.size)
                }
        }
        .overlay(alignment: .bottomLeading) {
            Text(caption)
                .font(.dsMeta)
                .foregroundStyle(DS.text3)
                .padding(DS.S.l)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit the whole map") { withAnimation(.easeOut(duration: 0.2)) { fit(in: size) } }
                .padding(DS.S.m)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map of \(pack.name): \(sim.graph.captureCount) captures and \(sim.graph.topicCount) topics they share")
        .accessibilityChildren {
            ForEach(sim.graph.nodes) { n in
                if case .capture(let id) = n.kind {
                    Button(n.label) { state.selectedCapture = id }
                }
            }
        }
    }

    private var caption: String {
        let g = sim.graph
        var parts = [g.topicCount == 0 ? "Dots are captures. Lines appear when captures share a topic."
                                       : "Dots are captures, rings are topics they share."]
        parts.append("Click a dot to open it · scroll to zoom")
        if g.hidden > 0 { parts.append("showing the newest \(g.captureCount)") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Drawing

    private func radius(_ n: PackGraph.Node) -> CGFloat { n.isTopic ? 4.5 : 5.5 + CGFloat(min(n.degree, 6)) * 0.7 }

    private func point(_ i: Int, _ center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + sim.pos[i].x * zoom, y: center.y + sim.pos[i].y * zoom)
    }

    private var selectedIndex: Int? {
        state.selectedCapture.flatMap { id in sim.graph.nodes.firstIndex { $0.kind == .capture(id) } }
    }

    private func draw(_ ctx: inout GraphicsContext, center: CGPoint) {
        let g = sim.graph
        guard sim.pos.count == g.nodes.count, !g.nodes.isEmpty else { return }
        // Pointing at something (or pinning a topic) lights what it's joined to; the open capture only gets a ring.
        let focus = hovered ?? pinned
        let lit: Set<Int>? = focus.map { sim.neighbors[$0].union([$0]) }
        let tint = PackStyle.deep(pack.id)
        let showAll = g.captureCount <= 14 || zoom >= 1.6

        for e in g.edges {
            let on = focus.map { e.a == $0 || e.b == $0 } ?? false
            var path = Path()
            path.move(to: point(e.a, center))
            path.addLine(to: point(e.b, center))
            ctx.stroke(path, with: .color(on ? DS.accent.opacity(0.8) : DS.text3.opacity(focus == nil ? 0.32 : 0.12)),
                       lineWidth: on ? 1.4 : 1)
        }
        var labels: [(rank: Int, text: GraphicsContext.ResolvedText, at: CGPoint)] = []
        for (i, n) in g.nodes.enumerated() {
            let p = point(i, center)
            let r = radius(n) * min(max(zoom, 0.7), 1.25)
            let dim = lit.map { !$0.contains(i) } ?? false
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            if n.isTopic {
                ctx.fill(circle, with: .color(DS.canvas))
                ctx.stroke(circle, with: .color(DS.text2.opacity(dim ? 0.25 : 0.9)), lineWidth: 1.5)
            } else {
                ctx.fill(circle, with: .color(tint.opacity(dim ? 0.25 : 1)))
                if i == selectedIndex || i == hovered {
                    let ring = Path(ellipseIn: CGRect(x: p.x - r - 3.5, y: p.y - r - 3.5, width: r * 2 + 7, height: r * 2 + 7))
                    ctx.stroke(ring, with: .color(DS.accent), lineWidth: 1.5)
                }
            }
            let emphasized = i == focus || i == selectedIndex
            guard n.isTopic || showAll || emphasized || (lit?.contains(i) ?? false) else { continue }
            let text = Text(n.label)
                .font(.system(size: n.isTopic ? 11.5 : 10.5, weight: n.isTopic || emphasized ? .semibold : .regular))
                .foregroundStyle((n.isTopic || emphasized ? DS.text : DS.text2).opacity(dim ? 0.3 : 1))
            labels.append((emphasized ? 0 : n.isTopic ? 1 : (lit?.contains(i) ?? false) ? 2 : 3, ctx.resolve(text), CGPoint(x: p.x, y: p.y + r + 4)))
        }
        // Names never sit on top of each other: what you point at wins, then topics, then the rest.
        var taken: [CGRect] = []
        for label in labels.sorted(by: { $0.rank < $1.rank }) {
            let size = label.text.measure(in: CGSize(width: 240, height: 40))
            let box = CGRect(x: label.at.x - size.width / 2, y: label.at.y, width: size.width, height: size.height).insetBy(dx: -3, dy: -1)
            if label.rank > 0, taken.contains(where: { $0.intersects(box) }) { continue }
            taken.append(box)
            ctx.draw(label.text, at: label.at, anchor: .top)
        }
    }

    // MARK: Pointing, dragging, zooming

    private func node(at location: CGPoint, center: CGPoint) -> Int? {
        guard sim.pos.count == sim.graph.nodes.count else { return nil }
        var best: (i: Int, d: CGFloat)?
        for (i, n) in sim.graph.nodes.enumerated() {
            let p = point(i, center)
            let d = hypot(p.x - location.x, p.y - location.y)
            if d <= radius(n) * zoom + 7, d < (best?.d ?? .infinity) { best = (i, d) }
        }
        return best?.i
    }

    private func tap(at location: CGPoint, center: CGPoint) {
        guard let i = node(at: location, center: center) else {
            pinned = nil
            state.selectedCapture = nil
            return
        }
        switch sim.graph.nodes[i].kind {
        case .capture(let id):
            pinned = nil
            state.selectedCapture = id
        case .topic:
            pinned = pinned == i ? nil : i
        }
    }

    private func drag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragFrom == nil { dragFrom = (pan, node(at: v.startLocation, center: center)) }
                guard let from = dragFrom else { return }
                if let i = from.node {
                    sim.dragging = i
                    let origin = CGPoint(x: size.width / 2 + from.pan.width, y: size.height / 2 + from.pan.height)
                    sim.pos[i] = CGPoint(x: (v.location.x - origin.x) / zoom, y: (v.location.y - origin.y) / zoom)
                    sim.reheat()
                } else {
                    moved = true
                    pan = CGSize(width: from.pan.width + v.translation.width, height: from.pan.height + v.translation.height)
                }
            }
            .onEnded { _ in
                sim.dragging = nil
                dragFrom = nil
            }
    }

    /// Zooms while keeping what's under `anchor` where it is.
    private func setZoom(_ new: CGFloat, around anchor: CGPoint) {
        moved = true
        let z = min(max(new, 0.3), 4)
        let center = CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
        let world = CGPoint(x: (anchor.x - center.x) / zoom, y: (anchor.y - center.y) / zoom)
        zoom = z
        pan = CGSize(width: anchor.x - world.x * z - size.width / 2, height: anchor.y - world.y * z - size.height / 2)
    }

    private func fit(in size: CGSize) {
        guard size.width > 0, !sim.pos.isEmpty else { return }
        moved = false
        let b = sim.bounds
        let z = min((size.width - 220) / max(b.width, 1), (size.height - 150) / max(b.height, 1))
        zoom = min(max(z, 0.35), 2.4)
        pan = CGSize(width: -b.midX * zoom, height: -b.midY * zoom)
    }

    /// The scroll wheel (or two fingers) zooms while the pointer is over the map.
    private func listenForScroll() {
        guard wheel == nil else { return }
        wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let p = pointer else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.006 : event.scrollingDeltaY * 0.06
            guard delta != 0 else { return nil }
            setZoom(zoom * (1 + delta), around: p)
            return nil
        }
    }
}
