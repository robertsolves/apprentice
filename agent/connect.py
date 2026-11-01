"""Tell every AI assistant on this Mac about apprentice. Run by kit.sh.

Assistants with a shell get the instructions in their global rules file, in a section
between <!-- apprentice --> markers that is replaced on each run so updates reach them.
Apps without a shell get the MCP server (`apprentice mcp`) instead.
Only assistants that are installed are touched.
"""
import json
import os
import shutil
import sys

home = os.path.expanduser("~")
root = os.path.dirname(os.path.abspath(__file__))
binary = sys.argv[1]
section = open(os.path.join(root, "AGENTS.md")).read().strip()
start, end = "<!-- apprentice -->", "<!-- /apprentice -->"


def installed(command, folder):
    return shutil.which(command) is not None or os.path.isdir(folder)


def rules(name, command, folder, filename):
    if not installed(command, folder):
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


rules("Codex and ChatGPT", "codex", f"{home}/.codex", "AGENTS.md")
rules("opencode", "opencode", f"{home}/.config/opencode", "AGENTS.md")
rules("Kilo", "kilo", f"{home}/.config/kilo", "AGENTS.md")
rules("Gemini", "gemini", f"{home}/.gemini", "GEMINI.md")
mcp("Claude desktop app", "-", f"{home}/Library/Application Support/Claude", "claude_desktop_config.json")
mcp("Cursor", "cursor", f"{home}/.cursor", "mcp.json")
