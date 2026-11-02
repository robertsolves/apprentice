"""Write the Codex wrapper for one or more agent commands.

    python3 -I .agents/skills/command-authoring/scripts/make_codex_wrapper.py <name> [<name> ...]

For each name, reads `.agents/commands/<name>.md` and (re)writes
`.agents/skills/<name>/SKILL.md` and `.agents/skills/<name>/agents/openai.yaml`.
The wrapper's description is copied from the command's frontmatter, so re-run
this whenever a description changes. A command with
`disable-model-invocation: true` gets `allow_implicit_invocation: false`.
"""

import pathlib
import re
import sys

AGENTS_DIR = pathlib.Path(__file__).resolve().parents[3]  # .agents/


def wrap(name: str) -> None:
    command = AGENTS_DIR / "commands" / f"{name}.md"
    if not command.is_file():
        raise SystemExit(f"no command file: {command}")
    text = command.read_text()
    match = re.search(r"^description: (.+)$", text, re.M)
    if match is None:
        raise SystemExit(f"{command}: frontmatter has no one-line description")
    description = match.group(1).strip()
    if description.startswith('"') and description.endswith('"'):
        # A quoted YAML scalar; the wrapper's `>-` block takes it bare.
        description = description[1:-1].replace('\\"', '"')
    model_invocation_disabled = re.search(r"^disable-model-invocation: true$", text, re.M)

    skill_dir = AGENTS_DIR / "skills" / name
    (skill_dir / "agents").mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: >-\n  {description}\n---\n\n"
        f"# Shared {name} workflow\n\n"
        f"Read `../../commands/{name}.md` completely before taking task actions, then follow that workflow faithfully.\n\n"
        f"Treat any text supplied with an explicit `${name}` invocation as the command document's `$ARGUMENTS`. "
        "When invoked implicitly, infer arguments only where the command defines a safe default; otherwise ask the user.\n\n"
        "The command document is the single source of truth. Ignore command-harness-only frontmatter while preserving "
        "its behavioral intent, including read-only restrictions and explicit confirmation requirements. When it refers "
        "to another `/command`, invoke or follow the equivalent `$skill` in Codex.\n"
    )
    yaml = (
        "interface:\n"
        f'  display_name: "{name}"\n'
        f'  short_description: "Run the shared {name} workflow"\n'
        f'  default_prompt: "Use ${name} to run the shared repository workflow."\n'
    )
    if model_invocation_disabled:
        yaml += "policy:\n  allow_implicit_invocation: false\n"
    (skill_dir / "agents" / "openai.yaml").write_text(yaml)
    print(f"wrapped {name}")


if len(sys.argv) < 2:
    raise SystemExit(__doc__)
for name in sys.argv[1:]:
    wrap(name)
