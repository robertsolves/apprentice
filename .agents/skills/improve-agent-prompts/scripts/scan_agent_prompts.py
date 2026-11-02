#!/usr/bin/env python3
# @admin.description Lint every agent prompt (commands, skills, subagents, rules) against the weak-agent standard (/improve-agent-prompts); fails on broken frontmatter, dead paths or wrapper drift.
"""Score every agent prompt against the weak-agent standard.

    python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py
    python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py <file> [<file> ...]
    python3 -I .agents/skills/improve-agent-prompts/scripts/scan_agent_prompts.py --errors

No arguments: one line per prompt file, worst first, then totals.
With files: every finding for those files, as `path:line CODE message`.
--errors: only the ERROR findings, across every prompt file.

Reads the agent directory (`.agents/` if the repo has one, else `.claude/`):
commands/*.md and *.toml, skills/*/SKILL.md and skills/*/references/*.md,
agents/*.md, rules/*.md. Read-only. Runs from any directory: the repo root
comes from git. The standard behind every code is
.agents/skills/improve-agent-prompts/references/weak_agent_standard.md.

Exit 1 when any ERROR finding exists (the file is broken for some tool),
0 otherwise. WARN findings are the rewrite to-do list; they never fail.
"""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(
    subprocess.run(
        ["git", "-C", str(pathlib.Path(__file__).resolve().parent), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
)
AGENT_DIR = ROOT / ".agents" if (ROOT / ".agents").is_dir() else ROOT / ".claude"
TRACKED = subprocess.run(
    ["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=True
).stdout.splitlines()
TRACKED_SET = set(TRACKED)
TRACKED_DIRS = {str(pathlib.PurePosixPath(p).parent) for p in TRACKED}
TOP_LEVEL = {p.split("/", 1)[0] for p in TRACKED if "/" in p}
# A project-scoped prompt (`<repo>-name`, a rule, a subagent) cites real paths, so a
# dead one is an ERROR; a generic prompt's dead path is usually an example (WARN).
PROJECT_SCOPE = ROOT.name + "-"
for _p in list(TRACKED_DIRS):
    while "/" in _p:
        _p = _p.rsplit("/", 1)[0]
        TRACKED_DIRS.add(_p)

ERROR, WARN = "ERROR", "WARN"
DETAIL_CAP = 40  # findings printed per file in detail mode

COMMAND_LINES_MAX = 200
SKILL_LINES_MAX = 150  # our budget; Anthropic's hard ceiling is 500
REFERENCE_TOC_OVER = 100  # Anthropic: a reference over 100 lines gets a contents list
DESCRIPTION_CHARS_MAX = 1024  # Agent Skills spec; Claude Code truncates at 1,536

VAGUE = re.compile(
    r"\b(as appropriate|appropriate(ly)?|as needed|if needed|if necessary|if relevant|"
    r"where possible|when possible|reasonable|properly|relevant (files|code|parts)|"
    r"and so on|etc\.|consider (whether|if))\b",
    re.I,
)
HARNESS_TOOL = re.compile(
    r"\b(TodoWrite|AskUserQuestion|ExitPlanMode|NotebookEdit|the (Task|Agent|Skill|Glob|Grep|Edit|Write|Read|Bash) tool)\b"
)
SEARCH_CMD = re.compile(r"(^|[\s`(|;&])(rg|grep -[a-zA-Z]*r[a-zA-Z]*|git grep|find \.)\s")
SEARCH_CAP = re.compile(r"\|\s*(head|tail|wc|sort -u|cut)|--max-count|-m ?\d|\s-[a-zA-Z]*[lcq][a-zA-Z]*\b|--files|--count|-maxdepth")
STEP_RIGHT = re.compile(r"^## Step (\d+): \S")
STEP_WRONG = re.compile(r"^(#{3,} Step \d|## Step \d+ *[—–-]|## \d+\.|## Step \d+\.)")
INLINE_COMMAND = re.compile(r"`(bash|sh|python3?|node|rg|grep|git|ls|cat|dart|fvm|flutter|npm|npx|make|gh|cd|test) [^`]+`")
PROOF = re.compile(r"\b(done when|done means|must (print|show|pass|be empty)|prints?|expect(ed)?|exit (code|0|1)|passes|is empty|shows)\b", re.I)
EMPTY_ARGS = re.compile(r"\b(empty|no argument|without (an )?argument|absent|not given|omitted|nothing (is )?(passed|given))\b", re.I)
PATH_SPAN = re.compile(r"`([^`\s<>*$]+)`")


def parse(path):
    """Return (frontmatter dict, frontmatter raw lines, body lines, body start line, error)."""
    lines = path.read_text().splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, [], lines, 1, "the first line is not `---`, so every tool reads the file as frontmatter-less"
    try:
        end = lines.index("---", 1)
    except ValueError:
        return {}, [], lines, 1, "frontmatter never closes with `---`"
    raw = lines[1:end]
    meta, key = {}, None
    for line in raw:
        m = re.match(r"^([A-Za-z_-]+):(.*)$", line)
        if m:
            key = m.group(1)
            meta[key] = m.group(2).strip()
        elif key and line.startswith((" ", "\t")):
            meta[key] = (meta[key] + " " + line.strip()).strip()
    for k, v in meta.items():
        if v.startswith((">", "|")):
            meta[k] = v[1:].lstrip("-+").strip()
        elif len(v) > 1 and v[0] == v[-1] and v[0] in "\"'":
            meta[k] = v[1:-1].replace('\\"', '"')
    return meta, raw, lines[end + 1:], end + 2, None


def unquoted_colon(raw):
    """Gemini CLI parses frontmatter as strict YAML: an unquoted `: ` in a value drops the file."""
    for i, line in enumerate(raw, start=2):
        m = re.match(r"^[A-Za-z_-]+: (.+)$", line)
        if m and not m.group(1).startswith(("\"", "'", ">", "|", "[", "{")) and ": " in m.group(1):
            return i
    return None


def code_mask(body):
    """True for each body line inside a fenced block."""
    inside, mask = False, []
    for line in body:
        if line.lstrip().startswith(("```", "~~~")):
            mask.append(True)
            inside = not inside
            continue
        mask.append(inside)
    return mask


def path_alive(span, file):
    span = re.sub(r":\d+(-\d+)?$", "", span).rstrip("/")
    if not span or span.startswith(("http", "~", "/", "$")):
        return True
    for candidate in (ROOT / span, file.parent / span, AGENT_DIR / span):
        if candidate.exists():
            return True
    if span in TRACKED_SET or span in TRACKED_DIRS:
        return True
    suffix = "/" + span
    return any(p.endswith(suffix) for p in TRACKED) or any(d.endswith(suffix) for d in TRACKED_DIRS)


def looks_like_path(span):
    """Only spans rooted in a real top-level folder: `docs/`, `src/a.ts` and `roles/x` are examples elsewhere."""
    if "{" in span or "..." in span or "::" in span or "/" not in span:
        return False
    return span.split("/", 1)[0] in TOP_LEVEL or span.startswith((".agents/", ".claude/", "./", "../"))


def lint_body(kind, path, body, start, out, project_scoped):
    mask = code_mask(body)
    steps, current = [], None
    for i, line in enumerate(body):
        n = start + i
        prose = not mask[i]
        if prose and kind == "command" and STEP_WRONG.match(line):
            out.append((WARN, "step-heading", n, "write steps as `## Step N: <title>`"))
        m = STEP_RIGHT.match(line) if prose else None
        if m:
            current = {"num": int(m.group(1)), "line": n, "command": False, "proof": False}
            steps.append(current)
        elif prose and line.startswith("## ") and current:
            current = None
        if current:
            if mask[i] or INLINE_COMMAND.search(line):
                current["command"] = True
            if PROOF.search(line):
                current["proof"] = True
        if prose:
            words = re.sub(r"`[^`]*`", "", line)  # a quoted word is a mention, not an instruction
            for v in VAGUE.finditer(words):
                out.append((WARN, "vague-word", n, f"'{v.group(0)}' asks a weak agent for judgement: name the case or the rule"))
            t = HARNESS_TOOL.search(words)
            if t:
                out.append((WARN, "harness-tool", n, f"'{t.group(0)}' exists in one CLI only: name the action instead"))
            if re.match(r"^ {4,}([-*]|\d+\.) ", line):
                out.append((WARN, "deep-nesting", n, "list nested three deep: flatten into numbered steps"))
        if (mask[i] or "`" in line) and SEARCH_CMD.search(line) and not SEARCH_CAP.search(line):
            out.append((WARN, "uncapped-search", n, "search with no cap: add `-l`, `--max-count N` or `| head -n N`"))
        for span in PATH_SPAN.findall(line):
            if looks_like_path(span) and f"no `{span}`" not in line and "first run" not in line and not path_alive(span, path):
                if project_scoped:
                    out.append((ERROR, "dead-path", n, f"`{span}` does not exist"))
                else:
                    out.append((WARN, "example-path", n, f"`{span}` looks real but does not exist; a weak agent will try to open it: write `<placeholder>` instead"))
    for want, step in enumerate(steps, start=1):
        if step["num"] != want:
            out.append((WARN, "step-order", step["line"], f"Step {step['num']} where Step {want} belongs"))
            break
    if kind == "command":
        for step in steps:
            if not step["command"]:
                out.append((WARN, "step-no-command", step["line"], f"Step {step['num']} has no command to copy (fenced block or `cmd args`)"))
            if not step["proof"]:
                out.append((WARN, "step-no-proof", step["line"], f"Step {step['num']} never says what output proves it done"))
    text = "\n".join(body)
    for i, line in enumerate(body):
        if re.match(r"Not this:", line):
            out.append((WARN, "body-handoff", start + i, "`Not this:` line in the body: neighbours belong in the description, not the body"))
    if kind in ("command", "skill", "agent"):
        if not re.search(r"^#+ *Done means|^\*\*Done means", text, re.M):
            out.append((WARN, "no-done-means", start, "no `## Done means` section repeating the make-or-break checks"))
    return steps


def lint_file(path, wrappers):
    out = []
    rel = path.relative_to(ROOT)
    parts = path.relative_to(AGENT_DIR).parts
    if path.suffix == ".toml":
        for n, line in enumerate(path.read_text().splitlines(), start=1):
            for span in re.findall(r"[\w./-]+\.md", line):
                if "/" in span and not path_alive(span, path):
                    out.append((ERROR, "dead-path", n, f"`{span}` does not exist"))
        return out, 0
    if parts[0] == "skills" and parts[-1] == "SKILL.md" and "../../commands/" in path.read_text():
        kind = "wrapper"
    elif parts[0] == "skills" and parts[-1] == "SKILL.md":
        kind = "skill"
    elif parts[0] == "skills":
        kind = "reference"
    else:
        kind = {"commands": "command", "agents": "agent", "rules": "rule"}[parts[0]]

    meta, raw, body, start, broken = parse(path)
    scope = parts[1] if parts[0] == "skills" else path.stem
    project_scoped = kind in ("rule", "agent") or scope.startswith(PROJECT_SCOPE)
    if kind == "rule" and broken and "first line" in broken:
        out.append((WARN, "rule-no-paths", 1, "no frontmatter `paths:` glob, so it loads into every session"))
        lint_body(kind, path, body, start, out, project_scoped)
        return out, len(body)
    if kind != "reference":
        if broken:
            out.append((ERROR, "frontmatter", 1, broken))
            return out, len(body)
        if (n := unquoted_colon(raw)) is not None:
            out.append((ERROR, "yaml-colon", n, "unquoted `: ` in a value: wrap the value in double quotes"))
    description = meta.get("description", "")
    if kind in ("command", "skill", "agent", "wrapper"):
        if not description:
            out.append((ERROR, "no-description", 2, "no `description:`: the prompt is never selected (or silently skipped)"))
        elif len(description) > DESCRIPTION_CHARS_MAX:
            out.append((ERROR, "description-long", 2, f"description is {len(description)} chars; the limit is {DESCRIPTION_CHARS_MAX}"))
        elif kind != "wrapper" and not re.search(r"\b(when|before|after|whenever)\b", description, re.I):
            out.append((WARN, "no-trigger", 2, "description has no 'Run when …' / 'Use when …' trigger"))
    if kind in ("skill", "wrapper", "agent"):
        name = meta.get("name", "")
        expected = parts[1] if kind != "agent" else path.stem
        if name != expected:
            out.append((ERROR, "name", 2, f"`name: {name}` must equal `{expected}`"))
        elif not re.fullmatch(r"[a-z0-9-]{1,64}", name):
            out.append((ERROR, "name", 2, "name must be 1-64 lowercase letters, digits and hyphens"))
    if kind == "agent" and "tools" in meta:
        out.append((ERROR, "agent-tools-key", 2, "`tools:` allow-list breaks OpenCode: use `disallowedTools:`"))
    if kind in ("command", "agent") and "model" in meta:
        out.append((WARN, "model-key", 2, "`model:` takes a different value format in each CLI; leave it off shared files"))
    if kind == "rule" and "paths" not in meta:
        out.append((WARN, "rule-no-paths", 1, "no `paths:` glob, so it loads into every session"))

    if kind == "wrapper":
        command = AGENT_DIR / "commands" / f"{parts[1]}.md"
        if not command.is_file():
            out.append((ERROR, "wrapper-orphan", 1, f"wraps `{command.relative_to(ROOT)}`, which does not exist"))
        elif parse(command)[0].get("description", "") != description:
            out.append((ERROR, "wrapper-drift", 2, "description differs from its command's: regenerate the wrapper"))
        if not (path.parent / "agents" / "openai.yaml").is_file():
            out.append((ERROR, "wrapper-yaml", 1, "no agents/openai.yaml beside the wrapper"))
        return out, len(body)

    if kind == "command":
        if not any(line.strip() == f"# /{path.stem}" for line in body[:5]):
            out.append((ERROR, "h1", start, f"first heading must be `# /{path.stem}`"))
        if wrappers and not (AGENT_DIR / "skills" / path.stem / "SKILL.md").is_file():
            out.append((ERROR, "no-wrapper", 1, "no skills/<name>/SKILL.md wrapper, so Codex-style CLIs never see it"))
        text = "\n".join(body)
        if "argument-hint" in meta and "$ARGUMENTS" not in text:
            out.append((WARN, "arguments", 2, "`argument-hint` but the body never uses `$ARGUMENTS`"))
        if "$ARGUMENTS" in text and not EMPTY_ARGS.search(text):
            out.append((WARN, "arguments", start, "uses `$ARGUMENTS` but never says what happens when it is empty"))
        if re.search(r"\$[0-9]\b", text):
            out.append((WARN, "positional-arg", start, "`$N` is replaced by the Nth argument (0-based in Claude Code, 1-based in OpenCode), even inside awk or shell code: use `$ARGUMENTS`, and `{print $NF}`-free code"))

    lint_body(kind, path, body, start, out, project_scoped)
    limit = {"command": COMMAND_LINES_MAX, "skill": SKILL_LINES_MAX}.get(kind)
    if limit and len(body) > limit:
        out.append((WARN, "long-body", start, f"{len(body)} body lines (budget {limit}): move reference material to references/ or a script"))
    if kind == "reference" and len(body) > REFERENCE_TOC_OVER and not re.search(r"^## (Contents|Table of contents)", "\n".join(body[:30]), re.M | re.I):
        out.append((WARN, "no-toc", 1, f"{len(body)} lines and no `## Contents` list in the first 30 lines"))
    return out, len(body)


def prompt_files():
    files = sorted(AGENT_DIR.glob("commands/*.md")) + sorted(AGENT_DIR.glob("commands/*.toml"))
    files += sorted(AGENT_DIR.glob("skills/*/SKILL.md")) + sorted(AGENT_DIR.glob("skills/*/references/*.md"))
    files += sorted(AGENT_DIR.glob("agents/*.md")) + sorted(AGENT_DIR.glob("rules/*.md"))
    return [f for f in files if f.is_file()]


def main(argv):
    every = prompt_files()
    errors_only = argv == ["--errors"]
    if errors_only:
        argv = []
    wrappers = any("../../commands/" in f.read_text() for f in AGENT_DIR.glob("skills/*/SKILL.md"))
    chosen = [pathlib.Path(a).resolve() for a in argv] if argv else every
    for f in chosen:
        if f not in every:
            raise SystemExit(f"not an agent prompt under {AGENT_DIR.relative_to(ROOT)}/: {f}")
    rows, errors = [], 0
    for f in chosen:
        findings, length = lint_file(f, wrappers)
        errors += sum(1 for s, *_ in findings if s == ERROR)
        rows.append((f, findings, length))
    if errors_only:
        for f, findings, _ in rows:
            for sev, code, line, msg in findings:
                if sev == ERROR:
                    print(f"{f.relative_to(ROOT)}:{line} {sev} {code}: {msg}")
        print(f"--- {errors} errors")
    elif argv:
        for f, findings, length in rows:
            rel = f.relative_to(ROOT)
            print(f"=== {rel} ({length} body lines, {len(findings)} findings) ===")
            for sev, code, line, msg in sorted(findings, key=lambda x: (x[0] != ERROR, x[2]))[:DETAIL_CAP]:
                print(f"{rel}:{line} {sev} {code}: {msg}")
            if len(findings) > DETAIL_CAP:
                print(f"... {len(findings) - DETAIL_CAP} more")
    else:
        def score(row):
            return sum(10 if s == ERROR else 1 for s, *_ in row[1])
        for f, findings, length in sorted(rows, key=score, reverse=True):
            if not findings:
                continue
            codes = {}
            for sev, code, *_ in findings:
                codes[code] = codes.get(code, 0) + 1
            n_err = sum(1 for s, *_ in findings if s == ERROR)
            summary = " ".join(f"{c}×{k}" for c, k in sorted(codes.items(), key=lambda x: -x[1]))
            print(f"{score((f, findings, 0)):4d}  E{n_err:<2d} {f.relative_to(ROOT)} ({length} lines): {summary}")
        clean = sum(1 for _, findings, _ in rows if not findings)
        print(f"--- {len(rows)} prompt files, {clean} clean, {errors} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
