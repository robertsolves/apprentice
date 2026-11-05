import SwiftUI

/// One step as the canvas draws it.
struct CanvasCard: Identifiable {
    let id: String
    let title: String
    let agent: String
    let prompt: String
    let screen: Bool
    let first: Bool
}

/// A pipeline as cards on a canvas. Drag a card or a node to place it, and drag from a card's right-hand dot to another
/// card to wire them. Drag a wire's end to another card to move it, or off into space to disconnect it. A step with
/// several wires goes through a node: OR runs one of them, chosen by its criteria, and AND runs them all at once; choose
/// a node to set which it is and how it decides. Everything here reads and writes the pipeline's `next:` lines (`PipelineWires`), so this
/// is always what the file says.
struct PipelineCanvas: View {
    let cards: [CanvasCard]
    let graph: PipelineGraph
    @Binding var positions: [String: CGPoint]
    @Binding var selected: String?
    /// The node chosen, by the step it follows.
    @Binding var selectedGate: String?
    /// What is typed for the next run only, shown at the corner of the canvas with a way to it.
    let firstThisRun: String
    let lastThisRun: String
    let openThisRun: () -> Void
    let wire: (String, String) -> Void
    let unwire: (String, String) -> Void
    let rewire: (String, String, String) -> Void
    let moved: () -> Void

    @State private var wiring: (from: String, at: CGPoint)?
    /// A wire's end being dragged: its step, where it went, and where the pointer is.
    @State private var moving: (from: String, to: String, at: CGPoint)?
    @State private var dragStart: CGPoint?

    private static let cardSize = CGSize(width: 196, height: 78)
    private static let gateGap: CGFloat = 46
    private let space = "pipeline-canvas"

    private func at(_ id: String) -> CGPoint { positions[id] ?? CGPoint(x: 110, y: 70) }
    private func outPort(_ id: String) -> CGPoint { CGPoint(x: at(id).x + Self.cardSize.width / 2, y: at(id).y) }
    private func inPort(_ id: String) -> CGPoint { CGPoint(x: at(id).x - Self.cardSize.width / 2, y: at(id).y) }
    private func gate(_ id: String) -> CGPoint { positions["gate:\(id)"] ?? CGPoint(x: outPort(id).x + Self.gateGap, y: at(id).y) }

    private func card(at point: CGPoint, except: String) -> String? {
        cards.first { c in
            c.id != except && CGRect(x: at(c.id).x - Self.cardSize.width / 2, y: at(c.id).y - Self.cardSize.height / 2,
                                     width: Self.cardSize.width, height: Self.cardSize.height).contains(point)
        }?.id
    }

    private var contentSize: CGSize {
        let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
        return CGSize(width: max((xs.max() ?? 0) + Self.cardSize.width + 90, 640), height: max((ys.max() ?? 0) + Self.cardSize.height + 40, 300))
    }

    private func curve(_ from: CGPoint, _ to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        let bend = max(abs(to.x - from.x) / 2, 36)
        path.addCurve(to: to, control1: CGPoint(x: from.x + bend, y: from.y), control2: CGPoint(x: to.x - bend, y: to.y))
        return path
    }

    /// The midpoint of a wire, for its remove button.
    private func middle(_ from: CGPoint, _ to: CGPoint) -> CGPoint { CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }

    /// A point along a wire, as `curve` draws it.
    private func along(_ from: CGPoint, _ to: CGPoint, _ t: CGFloat) -> CGPoint {
        let bend = max(abs(to.x - from.x) / 2, 36)
        let c1 = CGPoint(x: from.x + bend, y: from.y), c2 = CGPoint(x: to.x - bend, y: to.y), u = 1 - t
        func mix(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat { u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d }
        return CGPoint(x: mix(from.x, c1.x, c2.x, to.x), y: mix(from.y, c1.y, c2.y, to.y))
    }

    private func wireStart(_ id: String) -> CGPoint {
        if case .one = graph.next(id) { return outPort(id) }
        return gate(id)
    }

    var body: some View {
        GeometryReader { room in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    wires
                    ForEach(cards) { c in cardView(c).position(at(c.id)) }
                    ForEach(cards) { c in gateNode(c.id) }
                    ForEach(cards) { c in port(c) }
                    ForEach(cards) { c in ForEach(PipelineWires.targets(graph.next(c.id)), id: \.self) { target in wireEnd(c, target) } }
                }
                .frame(width: max(contentSize.width, room.size.width), height: max(contentSize.height, room.size.height), alignment: .topLeading)
                .coordinateSpace(name: space)
                .contentShape(Rectangle())
                .onTapGesture { selected = nil; selectedGate = nil }
            }
        }
        .background(Theme.canvas)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: Theme.s2) {
                thisRun("First, this run only", firstThisRun)
                thisRun("Last, this run only", lastThisRun)
            }
            .padding(Theme.s3)
        }
    }

    /// A reminder that the next run can have its own first and last step, and what they say.
    private func thisRun(_ title: String, _ text: String) -> some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: openThisRun) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.caption).foregroundStyle(.secondary)
                Text(empty ? "Nothing yet" : text).font(Theme.caption).foregroundStyle(empty ? .tertiary : .primary).lineLimit(1)
            }
            .padding(.horizontal, Theme.s2).padding(.vertical, Theme.s1)
            .frame(width: 190, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(.plain)
    }

    private var wires: some View {
        Canvas { context, _ in
            for c in cards {
                let next = graph.next(c.id)
                switch next {
                case .stop: break
                case .one(let to):
                    if !(moving?.from == c.id && moving?.to == to) { context.stroke(curve(outPort(c.id), inPort(to)), with: .color(.secondary), lineWidth: 1.5) }
                case .choice(let list), .all(let list):
                    var stem = Path()
                    stem.move(to: outPort(c.id))
                    stem.addLine(to: gate(c.id))
                    context.stroke(stem, with: .color(.secondary), lineWidth: 1.5)
                    for to in list where !(moving?.from == c.id && moving?.to == to) { context.stroke(curve(gate(c.id), inPort(to)), with: .color(.secondary), lineWidth: 1.5) }
                }
            }
            if let wiring { context.stroke(curve(outPort(wiring.from), wiring.at), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, dash: [5, 4])) }
            if let moving { context.stroke(curve(wireStart(moving.from), moving.at), with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, dash: [5, 4])) }
        }
        .allowsHitTesting(false)
    }

    private func cardView(_ c: CanvasCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.s1) {
                if c.first { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(Theme.accent).help("It starts here") }
                Text(c.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if c.screen { Image(systemName: "display").font(.system(size: 10)).foregroundStyle(.secondary).help("It uses the screen") }
            }
            Text(c.agent).font(Theme.caption).foregroundStyle(Theme.accent).lineLimit(1)
            Text(c.prompt).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s2).padding(.vertical, 6)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(selected == c.id ? Theme.accent : Theme.hairline, lineWidth: selected == c.id ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selected = c.id; selectedGate = nil }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .onChanged { drag in
                if dragStart == nil { dragStart = at(c.id); selected = c.id; selectedGate = nil }
                let start = dragStart ?? at(c.id)
                positions[c.id] = CGPoint(x: max(start.x + drag.translation.width, Self.cardSize.width / 2 + 8),
                                          y: max(start.y + drag.translation.height, Self.cardSize.height / 2 + 8))
            }
            .onEnded { _ in dragStart = nil; moved() })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(c.title)
    }

    /// The dot a wire is dragged from.
    private func port(_ c: CanvasCard) -> some View {
        Circle().fill(Theme.accent).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
            .contentShape(Rectangle().size(width: 24, height: 24).offset(x: -6, y: -6))
            .help("Drag to another card to wire them")
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                .onChanged { drag in wiring = (c.id, drag.location) }
                .onEnded { drag in
                    wiring = nil
                    if let target = card(at: drag.location, except: c.id) { wire(c.id, target) }
                })
            .accessibilityLabel("Wire from \(c.title)")
            .accessibilityAddTraits(.isButton)
            .position(outPort(c.id))
    }

    /// The end of a wire, which can be picked up: onto another card it moves there, into space it disconnects.
    private func wireEnd(_ c: CanvasCard, _ target: String) -> some View {
        let start = wireStart(c.id), end = inPort(target)
        let spot = moving?.from == c.id && moving?.to == target ? moving!.at : along(start, end, 0.88)
        return Circle().fill(Theme.surface).frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
            .contentShape(Rectangle().size(width: 24, height: 24).offset(x: -6.5, y: -6.5))
            .help("Drag to another card to move this wire, or away to disconnect it")
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
                .onChanged { drag in moving = (c.id, target, drag.location) }
                .onEnded { drag in
                    moving = nil
                    if let other = card(at: drag.location, except: c.id) {
                        if other != target { rewire(c.id, target, other) }
                    } else {
                        unwire(c.id, target)
                    }
                })
            .accessibilityLabel("End of the wire from \(c.title) to \(target)")
            .accessibilityAddTraits(.isButton)
            .position(spot)
    }

    /// An OR or AND node, where a step's wires split.
    @ViewBuilder private func gateNode(_ id: String) -> some View {
        let next = graph.next(id)
        switch next {
        case .choice, .all:
            let isAnd: Bool = { if case .all = next { return true } else { return false } }()
            Text(isAnd ? "AND" : "OR")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(isAnd ? Theme.accent : Theme.warn))
                .overlay(Circle().strokeBorder(graph.orHasNoCriteria(id) ? Theme.danger : (selectedGate == id ? Color.primary : Color.clear), lineWidth: 2))
                .contentShape(Circle())
                .onTapGesture { selectedGate = id; selected = nil }
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
                    .onChanged { drag in positions["gate:\(id)"] = drag.location }
                    .onEnded { _ in moved() })
                .help(graph.orHasNoCriteria(id) ? "This OR has nothing to choose by yet. Choose it to say what decides it." : isAnd ? "AND: all of these run at once." : "OR: one of these runs, chosen by its criteria.")
                .accessibilityLabel(isAnd ? "AND after \(id)" : "OR after \(id)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { selectedGate = id; selected = nil }
            .position(gate(id))
        default:
            EmptyView()
        }
    }
}
