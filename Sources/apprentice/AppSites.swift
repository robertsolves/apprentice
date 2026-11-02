import AppKit
import SwiftUI

/// The Sites screen: each website's pace, hours and limits, as plain controls. Everything it shows comes
/// from `agent/site-settings.toml` (`SiteSettings`): a field there is a control here, a preset a site that
/// is one click from set up. Values go to config.toml and budgets.json, where the commands read them.
struct SitesView: View {
    @ObservedObject var model: AppModel
    @State private var spec = SiteSettings.spec()
    @State private var sites: [String] = []
    @State private var selected: String?
    @State private var adding = false

    private var ready: [SiteSettings.Preset] { spec.presets.filter { !sites.contains($0.site) } }

    var body: some View {
        SplitPane(id: "sites") {
            ListColumn(count: spec.text("set_up_count", ["count": "\(sites.count)"]), newTitle: spec.text("add"), new: { adding = true }) {
                List(selection: $selected) {
                    SwiftUI.Section(header: Text(spec.text("set_up_group")).eyebrow()) {
                        SiteRow(site: SiteSettings.everyWebsite, title: spec.label(SiteSettings.everyWebsite), detail: spec.text("every_website_detail"))
                            .tag(SiteSettings.everyWebsite)
                        ForEach(sites, id: \.self) { site in
                            SiteRow(site: site, title: spec.label(site), detail: site).tag(site)
                        }
                    }
                    if !ready.isEmpty {
                        SwiftUI.Section(header: Text(spec.text("ready_group")).eyebrow()) {
                            ForEach(ready) { preset in
                                SiteRow(site: preset.site, title: preset.label, detail: spec.text("ready_detail")).tag(preset.site)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        } right: {
            if let site = selected {
                SiteDetail(spec: spec, site: site, configured: site == SiteSettings.everyWebsite || sites.contains(site)) { next in
                    reload(select: next)
                }
                .id(site)
            } else {
                ScreenPage(title: spec.title, subtitle: spec.subtitle) {
                    AnyView(IconButton(spec.text("add_site"), "plus", prominent: true) { adding = true })
                } content: {
                    Explainer(icon: Section.sites.icon, title: spec.text("explainer_title"), text: spec.about, points: spec.points)
                    if !ready.isEmpty {
                        Panel(title: spec.text("ready_group")) {
                            PresetGrid(presets: ready) { preset in setUp(preset) }
                        }
                    }
                }
            }
        }
        .background(Theme.canvas)
        .onAppear { reload() }
        .sheet(isPresented: $adding) {
            AddSiteSheet(spec: spec, ready: ready) { added in
                adding = false
                if let added { reload(select: added) }
            }
        }
    }

    private func setUp(_ preset: SiteSettings.Preset) {
        AppModel.backup(Config.path)
        AppModel.backup(Budgets.path)
        _ = try? SiteSettings.apply(preset, spec: spec)
        reload(select: preset.site)
    }

    private func reload(select: String? = nil) {
        spec = SiteSettings.spec()
        sites = SiteSettings.sites()
        if let select { selected = select }
    }
}

/// A site in a list: its own icon, its name and a quieter line.
struct SiteRow: View {
    let site: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Theme.s3) {
            SiteIcon(site: site, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(detail).font(Theme.monoSmall).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A website's own icon, as the site serves it: its apple-touch-icon, else its favicon, fetched once and kept
/// in `~/.apprentice/icons`. Every website, or a site whose icon cannot be had, shows a plain globe.
struct SiteIcon: View {
    let site: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Image(systemName: Section.sites.icon).font(.system(size: size * 0.8)).foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size)
        .task(id: site) { image = await SiteIcons.image(site) }
    }
}

enum SiteIcons {
    static var dir: URL { Store.dir.appendingPathComponent("icons") }

    /// The cached icon, else one fetched now. A site with none is tried again after a day.
    static func image(_ site: String) async -> NSImage? {
        guard site.contains("."), !site.contains("/") else { return nil }
        let file = dir.appendingPathComponent(site + ".png"), miss = dir.appendingPathComponent(site + ".none")
        if let cached = NSImage(contentsOf: file) { return cached }
        if let at = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, Date().timeIntervalSince(at) < 86_400 {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for path in ["https://\(site)/apple-touch-icon.png", "https://www.\(site)/apple-touch-icon.png", "https://\(site)/favicon.ico", "https://www.\(site)/favicon.ico"] {
            guard let url = URL(string: path) else { continue }
            var request = URLRequest(url: url, timeout: 6)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data), image.isValid,
                  let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: file)
            return image
        }
        FileManager.default.createFile(atPath: miss.path, contents: Data())
        return nil
    }
}

extension URLRequest {
    init(url: URL, timeout: TimeInterval) {
        self.init(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    }
}

/// The presets as cards: the site's icon and name, one click to set it up.
struct PresetGrid: View {
    let presets: [SiteSettings.Preset]
    let pick: (SiteSettings.Preset) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Theme.s2)], spacing: Theme.s2) {
            ForEach(presets) { preset in
                Button { pick(preset) } label: {
                    HStack(spacing: Theme.s2) {
                        SiteIcon(site: preset.site, size: 18)
                        Text(preset.label).font(.system(size: 12.5, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, Theme.s2)
                    .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One site: its fields under their groups, each showing the value that applies and whether it is the
/// site's own (with Reset) or the usual one.
struct SiteDetail: View {
    let spec: SiteSettings.Spec
    let site: String
    let configured: Bool
    let changed: (String?) -> Void
    @State private var own: [String: String] = [:]
    @State private var usual: [String: String] = [:]
    @State private var status = ""

    private var preset: SiteSettings.Preset? { spec.preset(site) }
    private var fields: [SiteSettings.Field] { spec.fields.filter { $0.applies(to: site) } }

    var body: some View {
        ScreenPage(title: spec.label(site), subtitle: site == SiteSettings.everyWebsite ? spec.text("every_website_subtitle") : site) {
            AnyView(HStack(spacing: Theme.s2) {
                if !status.isEmpty {
                    Text(status).font(Theme.caption).foregroundStyle(status == spec.text("saved") ? Color.secondary : Theme.danger).lineLimit(2)
                }
                if let preset {
                    IconButton(configured ? spec.text("preset_again") : spec.text("set_up", ["label": preset.label]), "wand.and.stars", prominent: !configured) { apply(preset) }
                }
                if configured, site != SiteSettings.everyWebsite {
                    IconButton(spec.text("remove"), "trash") { remove() }
                }
            })
        } content: {
            if !configured, let preset {
                Explainer(icon: Section.sites.icon, title: spec.text("not_set_up_title", ["label": preset.label]), text: spec.text("not_set_up"),
                          points: summary(preset))
            }
            ForEach(spec.groups) { group in
                let rows = fields.filter { $0.group == group.id }
                if !rows.isEmpty {
                    Panel(title: group.title) {
                        if !group.about.isEmpty {
                            Text(group.about).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(rows) { field in
                            Divider()
                            SiteFieldRow(spec: spec, field: field, site: site, own: own[field.id], usual: usual[field.id] ?? "") { write(field, $0) }
                        }
                    }
                }
            }
            Text("\(Config.path.path) · \(Budgets.path.path)").font(Theme.monoSmall).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .onAppear(perform: load)
    }

    private func summary(_ preset: SiteSettings.Preset) -> [String] {
        fields.filter { $0.type == "cap" }.compactMap { field in
            preset.values[field.id].flatMap { SiteFieldRow.capWords(spec, field.label, $0) }
        }
    }

    private func load() {
        let config = Config.load()
        var o: [String: String] = [:], u: [String: String] = [:]
        for field in fields {
            o[field.id] = SiteSettings.explicit(site, field)
            u[field.id] = SiteSettings.usual(site, field, config: config)
        }
        own = o
        usual = u
    }

    private func write(_ field: SiteSettings.Field, _ literal: String?) {
        AppModel.backup(field.store == "budget" ? Budgets.path : Config.path)
        do {
            try SiteSettings.set(site, field, literal)
            Config.reloadIfChanged()
            status = spec.text("saved")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if status == spec.text("saved") { status = "" } }
        } catch let f as Fail {
            status = f.message
        } catch {
            status = error.localizedDescription
        }
        load()
        if !configured { changed(site) }
    }

    private func apply(_ preset: SiteSettings.Preset) {
        AppModel.backup(Config.path)
        AppModel.backup(Budgets.path)
        do { try SiteSettings.apply(preset, spec: spec) } catch let f as Fail { status = f.message } catch {}
        load()
        changed(site)
    }

    private func remove() {
        AppModel.backup(Config.path)
        AppModel.backup(Budgets.path)
        do { try SiteSettings.remove(site) } catch let f as Fail { status = f.message } catch {}
        changed(spec.preset(site) == nil ? nil : site)
    }
}

/// One field: its label and help, a control for its type, and Reset when the site has its own value.
struct SiteFieldRow: View {
    let spec: SiteSettings.Spec
    let field: SiteSettings.Field
    let site: String
    /// The site's own value as the file writes it; nil when the usual one applies.
    let own: String?
    let usual: String
    let set: (String?) -> Void

    private var value: String { own ?? usual }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label).font(Theme.heading)
                    if !field.help.isEmpty {
                        Text(field.help).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.s3)
                if own != nil {
                    Button { set(nil) } label: { Label(spec.text("reset"), systemImage: "arrow.uturn.backward") }
                        .controlSize(.small)
                        .help(spec.text("reset_help"))
                } else {
                    Text(spec.text("usual")).font(Theme.monoSmall).foregroundStyle(.tertiary)
                }
            }
            control
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var control: some View {
        switch field.type {
        case "choice": choice
        case "number": number
        case "range": range
        case "percent": percent
        case "hours": hours
        case "cap": cap
        default: Text(value).font(Theme.mono)
        }
    }

    // MARK: Controls

    private var choice: some View {
        let current = Toml.unquote(value)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(field.choices.enumerated()), id: \.offset) { i, option in
                let allowed = field.store != "style" || PaceStyles.refusal(site, option) == nil
                Button { set("\"\(option)\"") } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                        Image(systemName: option == current ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(option == current ? Theme.accent : .secondary)
                        Text(field.labels[safe: i] ?? option).font(.system(size: 12.5, weight: option == current ? .semibold : .regular))
                        if let note = field.notes[safe: i] {
                            Text(note).font(Theme.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!allowed)
                .opacity(allowed ? 1 : 0.4)
                .help(allowed ? "" : spec.text("below_steady"))
            }
        }
    }

    private func numberBinding(_ index: Int?) -> Binding<Double> {
        Binding(
            get: {
                let numbers = index == nil ? [Double(Toml.unquote(value)) ?? 0] : (Toml.doubles(value) ?? [])
                return (numbers[safe: index ?? 0] ?? 0) / field.scale
            },
            set: { shown in
                let v = min(max(shown, field.min), field.max) * field.scale
                guard let index else { set(SiteSettings.number(v)); return }
                var pair = Toml.doubles(value) ?? [0, 0]
                while pair.count < 2 { pair.append(pair.last ?? 0) }
                pair[index] = v
                set("[\(SiteSettings.number(pair[0])), \(SiteSettings.number(pair[1]))]")
            })
    }

    private func numberBox(_ binding: Binding<Double>) -> some View {
        HStack(spacing: 2) {
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Stepper("", value: binding, in: field.min...field.max, step: field.step).labelsHidden()
        }
        .controlSize(.small)
    }

    private var number: some View {
        HStack(spacing: Theme.s2) {
            numberBox(numberBinding(nil))
            Text(field.unit).font(Theme.caption).foregroundStyle(.secondary)
            if !field.zero.isEmpty, (Double(Toml.unquote(value)) ?? 0) == 0 {
                StatusPill(text: field.zero, tint: .secondary, dot: false)
            }
        }
    }

    private var range: some View {
        HStack(spacing: Theme.s2) {
            Text(spec.text("from")).font(Theme.caption).foregroundStyle(.secondary)
            numberBox(numberBinding(0))
            Text(spec.text("to")).font(Theme.caption).foregroundStyle(.secondary)
            numberBox(numberBinding(1))
            Text(field.unit).font(Theme.caption).foregroundStyle(.secondary)
        }
    }

    private var percent: some View {
        PercentSlider(value: Double(Toml.unquote(value)) ?? 0, max: field.max, off: spec.text("off")) { set(SiteSettings.number($0)) }
    }

    private var hours: some View {
        let pair = Toml.doubles(value) ?? []
        let on = pair.count >= 2
        let from = on ? Int(pair[0]) : 22, to = on ? Int(pair[1]) : 7
        func write(_ f: Int, _ t: Int) { set("[\(f), \(t)]") }
        return HStack(spacing: Theme.s2) {
            Toggle("", isOn: Binding(get: { on }, set: { $0 ? write(from, to) : set("[]") }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
            if on {
                Text(spec.text("from")).font(Theme.caption).foregroundStyle(.secondary)
                HourPicker(hour: Binding(get: { from }, set: { write($0, to) }), range: 0...23)
                Text(spec.text("to")).font(Theme.caption).foregroundStyle(.secondary)
                HourPicker(hour: Binding(get: { to }, set: { write(from, $0) }), range: 1...24)
            } else {
                Text(spec.text("hours_off")).font(Theme.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func capParts(_ spec: SiteSettings.Spec) -> [(key: String, unit: String)] {
        [("hour", spec.text("cap_hour")), ("day", spec.text("cap_day")), ("week", spec.text("cap_week")), ("min_gap_s", spec.text("cap_gap"))]
    }

    private var cap: some View {
        let mine = Toml.table(own ?? "")
        let shown = Toml.table(usual)
        return HStack(spacing: Theme.s3) {
            ForEach(Self.capParts(spec), id: \.key) { part in
                HStack(spacing: 4) {
                    TextField(shown[part.key].map(Toml.unquote) ?? spec.text("cap_any"), text: Binding(
                        get: { mine[part.key].map(Toml.unquote) ?? "" },
                        set: { text in
                            var next = own == nil ? shown : mine
                            let digits = text.filter(\.isNumber)
                            next[part.key] = digits.isEmpty ? nil : digits
                            let literal = SiteSettings.capLiteral(next.compactMapValues { Double(Toml.unquote($0)) })
                            set(literal.isEmpty ? nil : literal)
                        }))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .controlSize(.small)
                    Text(part.unit).font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Likes: 20 an hour, 100 a day, 30 s apart" for a cap literal.
    static func capWords(_ spec: SiteSettings.Spec, _ label: String, _ literal: String) -> String? {
        let t = Toml.table(literal)
        let parts = capParts(spec).compactMap { p in t[p.key].map { "\(Toml.unquote($0)) \(p.unit)" } }
        return parts.isEmpty ? nil : "\(label): " + parts.joined(separator: ", ")
    }
}

/// A share as a percentage: a slider that writes when let go, so a drag is one save.
struct PercentSlider: View {
    let max: Double
    let off: String
    let commit: (Double) -> Void
    @State private var shown: Double

    init(value: Double, max: Double, off: String, commit: @escaping (Double) -> Void) {
        self.max = max
        self.off = off
        self.commit = commit
        _shown = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: Theme.s3) {
            Slider(value: $shown, in: 0...max, step: max / 100) { editing in if !editing { commit(shown) } }
                .frame(maxWidth: 260)
                .controlSize(.small)
            Text(shown == 0 ? off : String(format: shown * 100 < 1 ? "%.1f%%" : "%.0f%%", shown * 100))
                .font(Theme.mono)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
    }
}

/// An hour of the day by the system's clock style: "2 AM" or "02:00".
struct HourPicker: View {
    @Binding var hour: Int
    let range: ClosedRange<Int>

    var body: some View {
        Picker("", selection: $hour) {
            ForEach(Array(range), id: \.self) { h in Text(Self.name(h)).tag(h) }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 96)
    }

    static func name(_ h: Int) -> String {
        guard let date = Calendar.current.date(bySettingHour: h % 24, minute: 0, second: 0, of: Date()) else { return String(h) }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Add a site: a preset in one click, or any other website by name.
struct AddSiteSheet: View {
    let spec: SiteSettings.Spec
    let ready: [SiteSettings.Preset]
    let done: (String?) -> Void
    @State private var name = ""
    @State private var problem = ""

    var body: some View {
        SheetFrame(title: spec.text("add_title"), subtitle: spec.text("add_subtitle"), idealHeight: 440, idealWidth: 560) {
            if !ready.isEmpty {
                Panel(title: spec.text("ready_made")) {
                    Text(spec.text("ready_made_about"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                    PresetGrid(presets: ready) { preset in
                        AppModel.backup(Config.path)
                        AppModel.backup(Budgets.path)
                        do { try SiteSettings.apply(preset, spec: spec); done(preset.site) } catch let f as Fail { problem = f.message } catch {}
                    }
                }
            }
            Panel(title: spec.text("another")) {
                LabeledField(spec.text("website")) {
                    TextField(spec.text("website_placeholder"), text: $name).font(Theme.mono).onSubmit(add)
                }
                Text(spec.text("another_about")).font(Theme.caption).foregroundStyle(.secondary)
                if !problem.isEmpty { Text(problem).font(Theme.caption).foregroundStyle(Theme.danger) }
            }
        } buttons: {
            Spacer()
            Button(spec.text("cancel")) { done(nil) }.keyboardShortcut(.cancelAction)
            Button(spec.text("add"), action: add).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        AppModel.backup(Config.path)
        do { done(try SiteSettings.add(name, spec: spec)) } catch let f as Fail { problem = f.message } catch { problem = error.localizedDescription }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
