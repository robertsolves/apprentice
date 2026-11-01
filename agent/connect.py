"""Tell every AI assistant on this Mac about apprentice. Run by kit.sh.

Assistants with a shell get the skill (SKILL.md) where they look for skills, and the
instructions (AGENTS.md) in their global rules file, in a section between <!-- apprentice -->
markers that is replaced on each run so updates reach them. Apps without a shell get the MCP
server (`apprentice mcp`) instead. Only assistants that are installed are touched, except the
shared ~/.agents folder, which any agent that follows that convention reads.
"""
import json
import os
import shutil
import sys

home = os.path.expanduser("~")
root = os.path.dirname(os.path.abspath(__file__))
binary = sys.argv[1]
section = open(os.path.join(root, "AGENTS.md")).read().strip()
skill_text = open(os.path.join(root, "SKILL.md")).read()
start, end = "<!-- apprentice -->", "<!-- /apprentice -->"


def installed(commands, folder):
    if isinstance(commands, str):
        commands = [commands]
    return any(shutil.which(c) for c in commands) or (folder is not None and os.path.isdir(folder))


def skill(name, commands, folder):
    """Writes SKILL.md to <folder>/apprentice/SKILL.md; commands=None means always."""
    if commands is not None and not installed(commands, folder):
        return
    path = os.path.join(folder, "apprentice", "SKILL.md")
    if os.path.exists(path) and open(path).read() == skill_text:
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(skill_text)
    print(f"{name}: skill in {path}")


def rules(name, commands, folder, filename):
    """Puts the section in <folder>/<filename>; commands=None means always."""
    if commands is not None and not installed(commands, folder):
        return
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, filename)
    text = open(path).read() if os.path.exists(path) else ""
    block = f"{start}\n{section}\n{end}"
    if start in text:
        before, rest = text.split(start, 1)
        # Sections from older installs had no end marker and ran to the end of the file.
        after = rest.split(end, 1)[1] if end in rest else ""
        new = before + block + after
    else:
        new = text.rstrip() + ("\n\n" if text.strip() else "") + block + "\n"
    if new != text:
        open(path, "w").write(new)
        print(f"{name}: instructions in {path}")


def mcp(name, command, folder, filename):
    if not installed(command, folder):
        return
    path = os.path.join(folder, filename)
    try:
        config = json.load(open(path)) if os.path.exists(path) else {}
    except ValueError:
        print(f"{name}: skipped, {path} is not valid JSON")
        return
    entry = {"command": binary, "args": ["mcp"]}
    servers = config.setdefault("mcpServers", {})
    if servers.get("apprentice") != entry:
        servers["apprentice"] = entry
        os.makedirs(folder, exist_ok=True)
        with open(path, "w") as f:
            json.dump(config, f, indent=2)
            f.write("\n")
        print(f"{name}: MCP server in {path} (restart the app)")


# Skills. Codex, opencode and Amp read the shared ~/.agents/skills.
skill("Claude Code", None, f"{home}/.claude/skills")
skill("Codex, opencode and Amp", None, f"{home}/.agents/skills")
if installed("droid", f"{home}/.factory"):
    skill("Factory Droid", None, f"{home}/.factory/skills")

# Global rules files.
rules("Shared agents folder (Cline and others)", None, f"{home}/.agents", "AGENTS.md")
rules("Codex and ChatGPT", "codex", f"{home}/.codex", "AGENTS.md")
rules("opencode", "opencode", f"{home}/.config/opencode", "AGENTS.md")
rules("Kilo", "kilo", f"{home}/.config/kilo", "AGENTS.md")
rules("Gemini", "gemini", f"{home}/.gemini", "GEMINI.md")
rules("Qwen Code", "qwen", f"{home}/.qwen", "QWEN.md")
rules("GitHub Copilot CLI", "copilot", f"{home}/.copilot", "copilot-instructions.md")
rules("Amp", "amp", f"{home}/.config/amp", "AGENTS.md")
rules("Factory Droid", "droid", f"{home}/.factory", "AGENTS.md")
rules("Crush", "crush", f"{home}/.config/crush", "CRUSH.md")
rules("goose", "goose", f"{home}/.config/goose", ".goosehints")
rules("Augment (Auggie)", "auggie", f"{home}/.augment/rules", "apprentice.md")
# Freebuff and Codebuff read the first of ~/.knowledge.md (older versions), ~/.AGENTS.md.
if installed(["freebuff", "codebuff"], None):
    rules("Freebuff and Codebuff", None, home, ".AGENTS.md")
    if os.path.exists(f"{home}/.knowledge.md"):
        rules("Freebuff and Codebuff", None, home, ".knowledge.md")

# Apps without a shell.
mcp("Claude desktop app", "-", f"{home}/Library/Application Support/Claude", "claude_desktop_config.json")
mcp("Cursor", "cursor", f"{home}/.cursor", "mcp.json")
