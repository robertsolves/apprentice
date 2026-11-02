import SwiftUI

/// What each split screen is for. Shown inline when nothing is chosen and from the help button once something is.
extension Explainer {
    /// A section's explainer, from `[section.<id>]` in agent/app-text.toml.
    init(_ section: Section) {
        let s = AppText.screen(section.rawValue)
        self.init(icon: s.icon, title: s.explainerTitle, text: s.about, points: s.points)
    }

    static var projects: Explainer { Explainer(.projects) }
    static var pipelines: Explainer { Explainer(.pipelines) }
    static var vms: Explainer { Explainer(.vms) }
    static var schedules: Explainer { Explainer(.schedules) }
    static var skills: Explainer { Explainer(.skills) }
}
