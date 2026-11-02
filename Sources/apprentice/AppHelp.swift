import SwiftUI

/// What each split screen is for. Shown inline when nothing is chosen and from the help button once something is.
extension Explainer {
    static var projects: Explainer {
        Explainer(icon: Section.projects.icon, title: "What is a project?", 
            text: "A project is one piece of work, like running a shop's Instagram or sending the weekly invoices. It is a folder on this Mac with the project's files, its notes for agents and its pipelines. Any agent you open in it knows what the project is and which VM to use.", 
            points: ["New project makes the folder, and can make a VM just for it.", 
            "Open starts your agent in the project's folder.", 
            "Save keeps a version. Save to GitHub puts it online, private, so you can open it on another Mac.", 
            "In a terminal: apprentice project list, new, open and save."])
    }
    static var pipelines: Explainer {
        Explainer(icon: Section.pipelines.icon, title: "What is a pipeline?", 
            text: "A pipeline is a list of prompts that run one after another. Each step goes to your agent, and the agent sees what the step before it found.", 
            points: ["For example: 1. Get the new comments on my Instagram post. 2. Answer the ones that ask about prices by email. 3. Write me a two-line summary.", 
            "Run it now, or put it on a schedule: every morning, every Monday.", 
            "Each pipeline is a file in its project's pipelines folder. In a terminal: apprentice pipeline list, run and new."])
    }
    static var vms: Explainer {
        Explainer(icon: Section.vms.icon, title: "What is a VM?", 
            text: "A VM is a small Linux computer that runs inside this Mac. It has its own screen, mouse and keyboard, so an agent can use websites there while you keep using your Mac.", 
            points: ["Make one per project to keep each project's accounts apart.", 
            "Look at its screen any time to see what the agent is doing.", 
            "A VM only runs while this Mac is on and awake."])
    }
    static var schedules: Explainer {
        Explainer(icon: Section.schedules.icon, title: "What is a schedule?", 
            text: "A schedule runs something later, or again and again: a prompt for your agent, a pipeline, or a command. It asks for the same approvals as anything you start yourself.", 
            points: ["It runs while this Mac is on and awake, even with this window closed.", 
            "A run missed while the Mac slept is skipped, not repeated in a burst.", 
            "To run with nobody at the Mac, keep it plugged in and turn on Keep the Mac awake in Settings."])
    }
    static var skills: Explainer {
        Explainer(icon: Section.skills.icon, title: "What is a skill?", 
            text: "A skill is what an agent knows before it acts: how a website or an app works, the steps for a task, how a person behaves on a site, or a rule for everything. Agents find the right ones by themselves.", 
            points: ["Yours: written by you. Agents follow them.", 
            "Learned by apprentice: written by apprentice as it works, so the next run is faster. Agents treat them as hints, and you can edit or forget any of them.", 
            "Built in: come with apprentice. To change one, make your own copy; yours is used instead.", 
            "Keep names, handles and anything personal out. For those, apprentice keeps your preferences separately."])
    }
}
