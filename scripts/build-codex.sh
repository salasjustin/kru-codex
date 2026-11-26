#!/bin/bash
# builds the Codex plugin from this tree, generated each time and never committed.
#   build-codex.sh <out-dir>              the plugin tree: manifest, skills, role files, hooks
#   build-codex.sh --install <codex-home> the same tree into <codex-home>/plugins/cache/kru/kru/local,
#                                         and the role files into <codex-home>/agents
#   build-codex.sh --check <dir>          scan a built tree: manifest, skill names, role TOML,
#                                         leftover Claude Code names, plugin-root paths
#   build-codex.sh --verify               build into a temp dir, check it, remove it (what verify.sh runs)
#   build-codex.sh --help                 this text, on stdout
# exit: 0 done · 1 failed: a broken source tree, an output path it won't replace, a role file it
# didn't write in the way, --check problems, a missing or old python3 · 64 bad flags or arguments.
# needs bash and python3 3.11+ (tomllib). the same input builds the same bytes. a build goes into a
# temp sibling and moves into place whole, so a failed run leaves the previous tree as it was and a
# rerun replaces the tree it made and nothing else. every mapping is explained, with the Codex source
# line it rests on, in codex/PORTING.md.
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null || {
  echo "build-codex: needs python3 3.11 or newer (for tomllib); found: $(python3 --version 2>&1 || echo none)" >&2
  exit 1
}
KRU_REPO=$repo exec python3 - "$@" <<'PY'
import json, os, re, shutil, sys, tempfile, tomllib
from pathlib import Path

REPO = Path(os.environ["KRU_REPO"])
MARKER = ".kru-codex-build"          # a tree this script made; the only kind it replaces
ROLE_MARK = "# kru-codex-build"      # first line of a role file this script made
PLUGIN_ID = ("kru", "kru")           # plugin@marketplace, the key config.toml lists it under
ROOT_TOKEN = "<plugin-root>"         # stands for the plugin directory until an install knows it

# ---------------------------------------------------------------------------------------------
# the rewrite rules: every Claude Code name that becomes a Codex one, in one place. the build
# applies them and --check reads the same tables, so a name added to the repo with no rule here
# fails verify instead of shipping.
# ---------------------------------------------------------------------------------------------

# a backticked tool name, as the model sees it. Codex tool names: exec_command (shell),
# apply_patch (edits), spawn_agent / send_input / wait_agent / close_agent (sub-agents),
# update_plan (the worklist). Codex has no read, grep or fetch tool, so those go through the shell.
TOOL_NAMES = {
    "Agent": "`spawn_agent`",
    "Bash": "`exec_command`",
    "Edit": "`apply_patch`",
    "Write": "`apply_patch`",
    "Read": "READ",                  # becomes the verb: "`Read` the file" -> "read the file"
    "Grep": "`rg`",
    "Glob": "`rg --files`",
    "WebFetch": "`curl`",
    "SendMessage": "`send_input`",
    "TaskCreate": "`update_plan`",
    "TaskUpdate": "`update_plan`",
    "TaskList": "`update_plan`",
    "TaskGet": "`update_plan`",
    "TodoWrite": "`update_plan`",
    "TaskOutput": "`wait_agent`",
    "TaskStop": "`close_agent`",
}
# names with no Codex counterpart a rule could name; --check fails when one is left behind
CLAUDE_ONLY = set(TOOL_NAMES) | {"Skill", "WebSearch", "NotebookEdit", "AskUserQuestion", "ToolSearch", "Task"}
# skills about other platforms use these words as their own vocabulary (Cloudflare's `Agent` and
# `Workflow` classes), so the tool-name rules skip them
OWN_VOCABULARY = ("skills/workers-best-practices/", "skills/agents-sdk/", "skills/cloudflare/",
                  "skills/durable-objects/", "skills/wrangler/", "skills/nextjs-on-cloudflare/")
# Codex mentions a skill as $name, and a plugin's skills carry the plugin name as a prefix
SLASH_SKILL = (re.compile(r"(?<![\w/.:$-])/kru:([a-z][a-z0-9-]*)"), r"$kru:\1")
SKILL_TOOL = (re.compile(r"`Skill`( tool| call)?"), "`$skill` mention")
FIELD_NAMES = [("subagent_type", "agent_type")]
# skills that start a nested `claude -p`. A Codex session has no Claude login, so in this build the
# skill says so and stops; the body is replaced, so nothing in it can be followed past the notice
NESTED_PASS = {"reflect", "text-fix"}
NESTED_BODY = ("\n**This pass needs a Claude Code session.** It starts a nested `claude -p` session, and a "
               "Codex session has no Claude login, so it cannot run here. Say that in one line and stop. "
               "Do not attempt the nested call.\n")
# a Claude model name never reaches the output: ROSTER.md's model section is regenerated from
# MODEL_TABLE (roster_models), elsewhere an id becomes the gateway model DOC_TIER_MODEL fixes for its family, and a model's display name (Opus, Sonnet, Haiku, Fable, with or without a version)
# becomes "a model"
CLAUDE_MODEL_ID = re.compile(r"claude-(opus|sonnet|haiku)-[0-9][0-9.-]*")
CLAUDE_MODEL_NAME = re.compile(r"\b(?:Claude )?(?:Opus|Sonnet|Haiku|Fable)(?: [0-9]+(?:\.[0-9]+)*)?\b")
CLAUDE_MODEL_LEFT = re.compile(r"claude-(?:opus|sonnet|haiku|fable)|\b(?:Opus|Sonnet|Haiku|Fable)\b")
ROOT_NOTE = ("`<plugin-root>` below is the kru plugin directory: the one that holds `skills/`, "
             "`references/` and `hooks/`.\n\n")

# a seat whose description says it reports and does not edit gets a read-only sandbox
READ_ONLY_SEAT = re.compile(r"\b(does not edit|no edits)\b|Reports only")

# the model per seat. A Codex session runs on these models only, never a Claude one, and every seat
# takes the one model of its kind ("*": no tier lookup; a seat's Claude `model:` row is upstream
# metadata and no longer picks anything). Its `effort:` carries over unchanged as
# `model_reasoning_effort`, and MODEL_EFFORTS must list that effort for that model or the build fails.
# Every seat is listed once: a seat in no kind, in two, or a name with no seat file fails the build
# until the table is fixed.
DEEP = "deepseek/deepseek-v4.1-flash-1017"
UI = "minimax/minimax-m3.1-flash"
KIMI = "moonshotai/kimi-k3.1-pro"
LIGHT = "meta/muse-ember"
MODEL_TABLE = [
    # kind       seats                                                                        model
    ("deep engineering", ["better-auth-specialist", "chariot-specialist", "cloudflare-builder",
                          "express-builder", "fly-platform-engineer", "go-fullstack-builder", "hono-builder",
                          "nextjs-builder", "node-developer", "nowpayments-specialist", "paypal-specialist",
                          "postgres-architect", "python-developer", "quickbooks-specialist",
                          "react-router-builder", "sanity-builder", "sqlite-architect", "stripe-specialist",
                          "sveltekit-builder", "tanstack-start-builder", "turso-specialist",
                          "vercel-platform-engineer", "zapier-specialist", "zig-developer"],
     {"*": DEEP}),
    ("ui, test and independent reviewer", ["react-ui-builder", "svelte-ui-builder", "hono-ui-builder",
                                           "web-components-builder", "extension-builder", "motion-designer",
                                           "test-writer", "code-reviewer"],
     {"*": UI}),
    ("planning and architecture review", ["planner", "architecture-reviewer"],
     {"*": KIMI}),
    ("visual review and lighter repeated work", ["conversion-copywriter", "ux-auditor", "visual-reviewer",
                                                 "accessibility-reviewer", "dispatch-auditor",
                                                 "toolchain-engineer", "vercel-perf-optimizer"],
     {"*": LIGHT}),
]
MODELS_ALL = {m for _, _, by_tier in MODEL_TABLE for m in by_tier.values()}
# the reasoning efforts each gateway model accepts, from its `reasoning_options` in the public model
# list (https://ai-gateway.vercel.sh/v1/models, reviewed 2026-11-26). a pin outside this set has no
# request the gateway would take, so the build refuses it rather than ship it.
MODEL_EFFORTS = {
    DEEP: {"none", "low", "high", "max"},
    UI: {"low", "medium", "high", "xhigh", "max"},
    KIMI: {"low", "high", "max"},
    LIGHT: {"minimal", "low", "medium", "high", "xhigh", "max"},
}

def effort_problem(seat, model, effort):
    """a line when the seat's effort pin is not one its model accepts, else None."""
    if effort and model in MODEL_EFFORTS and effort not in MODEL_EFFORTS[model]:
        return f"agents/{seat}.md: effort {effort!r} is not one {model} accepts ({', '.join(sorted(MODEL_EFFORTS[model]))})"
    return None

def table_problems():
    """what is wrong with the table against the seat files, one line each."""
    seats = {f.stem for f in (REPO / "agents").glob("*.md")}
    listed = [s for _, names, _ in MODEL_TABLE for s in names]
    bad = [f"agents/{s}.md is in no seat kind of MODEL_TABLE" for s in sorted(seats - set(listed))]
    bad += [f"{s} is listed in MODEL_TABLE but has no seat file" for s in sorted(set(listed) - seats)]
    bad += [f"{s} is listed in MODEL_TABLE more than once" for s in sorted({s for s in listed if listed.count(s) > 1})]
    return bad

def seat_model(seat, fm):
    """(model, reasoning effort or None) for a seat, from its kind and its effort."""
    for kind, names, by_tier in MODEL_TABLE:
        if seat in names:
            model = by_tier.get("*")
            if not model:
                die(f"agents/{seat}.md: kind {kind!r} of MODEL_TABLE has no model for any tier")
            effort = fm.get("effort") or None
            problem = effort_problem(seat, model, effort)
            if problem:
                die(problem)
            return model, effort
    die(f"agents/{seat}.md is in no seat kind of MODEL_TABLE")

# the Codex build's hooks, as (event, matcher, hook, script args, timeout in s). each runs through
# hooks/codex-adapter.sh, which reshapes the payload and calls the same script the Claude Code hook
# runs, or for an ADAPTER_HOOKS entry answers itself.
# not carried: check-task-tools (Codex has no task tools to switch on)
HOOKS = [
    ("SessionStart", "startup", "setup-nudge", [], 10),
    ("SessionStart", "startup|clear|resume|compact|fork", "lead-first", [], 10),
    ("SessionStart", None, "store-sync", ["start"], 60),
    ("UserPromptSubmit", None, "record-prompt", [], 10),
    ("PreToolUse", "*", "require-lead", [], 10),
    ("PreToolUse", "spawn_agent", "check-handoff", [], 10),
    ("PreToolUse", "Write|Edit|Bash", "brainstorm-guard", [], 10),
    ("PostToolUse", "spawn_agent", "log-dispatch", [], 10),
    ("PostToolUse", "Bash", "record-read", [], 10),
    ("SubagentStop", None, "log-return", [], 10),
    ("Stop", None, "nudge-audit", [], 10),
    ("Stop", None, "store-sync", ["stop"], 30),
]

# what the plugin carries beyond skills/ and hooks/: files skills point at, and the files hooks read
ROOT_DOCS = ["ROSTER.md", "SOURCES.md", "TRACKER.md", "PREFERENCES.md"]
COPY_DIRS = ["references", "scripts/asset"]
RUNTIME_SCRIPTS = ["scripts/kru-store.sh", "scripts/kru-merge-lines.sh"]
LEGAL = ["LICENSE", "NOTICE", "VERSION"]

# hooks the adapter answers itself, with no script of their own: they write the shadow transcript
ADAPTER_HOOKS = ("record-prompt", "record-read")

# ---------------------------------------------------------------------------------------------

def die(msg):
    print(f"build-codex: {msg}", file=sys.stderr)
    sys.exit(1)

if MODELS_ALL != set(MODEL_EFFORTS):
    die(f"MODEL_EFFORTS lists {sorted(MODEL_EFFORTS)} but MODEL_TABLE assigns {sorted(MODELS_ALL)}")

def split_fm(text, where):
    if not text.startswith("---\n"):
        die(f"{where}: no frontmatter")
    end = text.find("\n---\n", 4)
    if end < 0:
        die(f"{where}: frontmatter not closed")
    return text[4:end], text[end + 5:]

def parse_fm(fm):
    """top-level keys of a frontmatter block, as strings; block scalars and wrapped values joined."""
    out, key, val = {}, None, []
    def flush():
        if key is not None:
            first, rest = val[0], [v.strip() for v in val[1:] if v.strip()]
            if first in (">", "|", ">-", "|-", ">+", "|+"):
                out[key] = " ".join(rest)
            else:
                s = " ".join([first] + rest).strip()
                if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
                    s = json.loads(s) if s[0] == '"' else s[1:-1].replace("''", "'")
                out[key] = s
    for line in fm.split("\n"):
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            flush(); key, val = m.group(1), [m.group(2).strip()]
        elif key is not None:
            val.append(line)
    flush()
    return out

def keep_keys(fm, keys):
    """a frontmatter block cut to the named top-level keys, each with its wrapped lines."""
    out, keep = [], False
    for line in fm.split("\n"):
        m = re.match(r"^([A-Za-z0-9_-]+):", line)
        if m:
            keep = m.group(1) in keys
        if keep:
            out.append(line)
    return "\n".join(out)

def one_line(s):
    return " ".join(s.split())

def rewrite_root(text, root):
    return text.replace("${CLAUDE_PLUGIN_ROOT}", root).replace("$CLAUDE_PLUGIN_ROOT", root)

# a Claude model id in a document becomes the gateway model fixed here for its family, whatever
# model the seats pinned to that id run on
OPUS, SONNET, HAIKU = "opus", "sonnet", "haiku"
DOC_TIER_MODEL = {OPUS: DEEP, SONNET: UI, HAIKU: LIGHT}

def tier_model(tier):
    return DOC_TIER_MODEL[tier]

# ROSTER.md's model section pins seats to Claude ids by Claude tier, which is not how this build picks
# a seat's model. the build swaps it, from its heading through the closing "Fable 5 is the premium
# tier" paragraph, for a table drawn from MODEL_TABLE. both anchors must be found, once each and in
# order, or the build stops: an upstream edit that moves them would otherwise ship the Claude table
ROSTER_MODEL_START = "## Model tiers\n"
ROSTER_MODEL_END = "Fable 5 is the premium tier"
EFFORT_ORDER = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

def roster_model_section():
    rows = ["| seat kind | seats | model | efforts accepted |", "|---|---|---|---|"]
    for kind, names, by_tier in MODEL_TABLE:
        model = by_tier["*"]
        seats = ", ".join(f"`{s}`" for s in names)
        efforts = " ".join(f"`{e}`" for e in sorted(MODEL_EFFORTS[model], key=lambda e: (EFFORT_ORDER.index(e) if e in EFFORT_ORDER else len(EFFORT_ORDER), e)))
        rows.append(f"| {kind} | {seats} | `{model}` | {efforts} |")
    return (ROSTER_MODEL_START + "\n"
            "In this build every seat runs on the one gateway model of its seat kind, never a Claude model. "
            "A seat's `effort:` carries over as `model_reasoning_effort`, and the build refuses one its model "
            "does not accept. The lead runs on the session's model.\n\n"
            + "\n".join(rows) + "\n\n"
            "`MODEL_TABLE` in the kru source repository's `scripts/build-codex.sh` is the source of this "
            "table; that repository's README, *Models* section, has the prices.\n")

def roster_models(text):
    """ROSTER.md with its Claude model-pin section replaced by the MODEL_TABLE one."""
    starts = [m.start() for m in re.finditer(r"(?m)^" + re.escape(ROSTER_MODEL_START), text)]
    ends = [m.start() for m in re.finditer(r"(?m)^" + re.escape(ROSTER_MODEL_END), text)]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        die(f"ROSTER.md: the model section needs one {ROSTER_MODEL_START.strip()!r} heading followed by one "
            f"paragraph starting {ROSTER_MODEL_END!r} (found {len(starts)} and {len(ends)}); "
            "update ROSTER_MODEL_START / ROSTER_MODEL_END in scripts/build-codex.sh to match ROSTER.md")
    start, end = starts[0], text.find("\n", ends[0])
    end = len(text) if end < 0 else end + 1
    between = text[start + len(ROSTER_MODEL_START):ends[0]]
    if re.search(r"(?m)^#{1,2} ", between):
        die(f"ROSTER.md: a heading sits between {ROSTER_MODEL_START.strip()!r} and the paragraph starting "
            f"{ROSTER_MODEL_END!r}; the model section would swallow it. update ROSTER_MODEL_START / "
            "ROSTER_MODEL_END in scripts/build-codex.sh to match ROSTER.md")
    return text[:start] + roster_model_section() + text[end:]

# source documents the build changes before the rules apply, by path
DOC_TRANSFORMS = {"ROSTER.md": roster_models}

def rewrite_models(text):
    text = CLAUDE_MODEL_ID.sub(lambda m: tier_model(m.group(1)), text)
    text = CLAUDE_MODEL_NAME.sub("a model", text)
    return re.sub(r"\b([Aa])n? a model\b", r"\1 model", text)

def rewrite(text, root, rel):
    """every rule, for a markdown file the model reads."""
    text = rewrite_models(rewrite_root(text, root))
    text = SLASH_SKILL[0].sub(SLASH_SKILL[1], text)
    if rel.startswith(OWN_VOCABULARY):
        return text
    text = SKILL_TOOL[0].sub(SKILL_TOOL[1], text)
    def tool(m):
        new = TOOL_NAMES[m.group(1)]
        if new != "READ":
            return new
        before = m.string[max(0, m.start() - 2):m.start()]
        start = m.start() == 0 or before.endswith(("\n", ". ", "- ", "* ", "| ", "> ", "# "))
        return "Read" if start else "read"
    text = re.sub(r"`(" + "|".join(TOOL_NAMES) + r")`", tool, text)
    for old, new in FIELD_NAMES:
        text = text.replace(old, new)
    return text

def is_text(path):
    try:
        path.read_text(encoding="utf-8"); return True
    except (UnicodeDecodeError, OSError):
        return False

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")

def tracked(f):
    return not {"node_modules", ".DS_Store"} & set(f.parts)

def copy_file(src, dst, root, rel, md_rules=True):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if is_text(src):
        text = src.read_text(encoding="utf-8")
        if rel in DOC_TRANSFORMS:
            text = DOC_TRANSFORMS[rel](text)
        text = rewrite(text, root, rel) if md_rules and src.suffix == ".md" else rewrite_root(text, root)
        if root == ROOT_TOKEN and src.suffix == ".md" and ROOT_TOKEN in text and "install dir" not in text:
            text = prepend_note(text, ROOT_NOTE)
        write(dst, text)
        shutil.copymode(src, dst)
    else:
        shutil.copy2(src, dst)

def prepend_note(text, note):
    """after a frontmatter block when there is one, else at the top."""
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end >= 0:
            cut = end + 5
            return text[:cut] + "\n" + note.rstrip("\n") + "\n" + text[cut:]
    return note + text

# ---- skills -----------------------------------------------------------------------------------

def build_skills(out, root):
    src_root = REPO / "skills"
    for sdir in sorted(p for p in src_root.iterdir() if p.is_dir()):
        skill = sdir / "SKILL.md"
        if not skill.is_file():
            die(f"{sdir.relative_to(REPO)}: no SKILL.md")
        if (sdir / "agents").exists():
            die(f"{sdir.relative_to(REPO)}: has an agents/ folder, where Codex keeps per-skill metadata; rename it")
        for f in sorted(sdir.rglob("*")):
            if not f.is_file() or not tracked(f):
                continue
            rel = f.relative_to(REPO).as_posix()
            if f == skill:
                continue
            copy_file(f, out / rel, root, rel)
        fm_text, body = split_fm(skill.read_text(encoding="utf-8"), skill.relative_to(REPO).as_posix())
        fm = parse_fm(fm_text)
        rel = skill.relative_to(REPO).as_posix()
        body = NESTED_BODY if sdir.name in NESTED_PASS else rewrite(body, root, rel)
        head = f"---\nname: {fm['name']}\ndescription: {json.dumps(rewrite_models(one_line(fm['description'])), ensure_ascii=False)}\n---\n"
        text = head + body
        if root == ROOT_TOKEN and ROOT_TOKEN in text and "install dir" not in text:
            text = prepend_note(text, ROOT_NOTE)
        write(out / rel, text)
        # a skill the Claude Code plugin keeps off the model's own initiative: Codex runs it only when
        # called as $name, through the per-skill policy file
        if fm.get("disable-model-invocation", "").lower() == "true":
            write(out / "skills" / sdir.name / "agents" / "openai.yaml",
                  "policy:\n  allow_implicit_invocation: false\n")

# ---- seats -> role files ------------------------------------------------------------------------

def toml_str(s):
    return json.dumps(s, ensure_ascii=False)

def toml_block(s):
    return "'''\n" + s + "\n'''" if "'''" not in s else toml_str(s)

def build_roles(out, root):
    count = 0
    for f in sorted((REPO / "agents").glob("*.md")):
        rel = f.relative_to(REPO).as_posix()
        fm_text, body = split_fm(f.read_text(encoding="utf-8"), rel)
        fm = parse_fm(fm_text)
        name, desc = fm["name"], rewrite_models(one_line(fm["description"]))
        if name != f.stem:
            die(f"{rel}: name {name!r} differs from the file name")
        body = rewrite(body, root, rel).strip("\n")
        if root == ROOT_TOKEN and ROOT_TOKEN in body:
            body = ROOT_NOTE.rstrip("\n") + "\n\n" + body
        lines = [ROLE_MARK, f"name = {toml_str(name)}", f"description = {toml_str(desc)}"]
        if READ_ONLY_SEAT.search(desc):
            lines.append('sandbox_mode = "read-only"')
        model, effort = seat_model(name, fm)
        lines.append(f"model = {toml_str(model)}")
        if effort:
            lines.append(f"model_reasoning_effort = {toml_str(effort)}")
        lines.append(f"developer_instructions = {toml_block(body)}")
        write(out / "roles" / f"{name}.toml", "\n".join(lines) + "\n")
        # the Claude Code seat file stays where the hook scripts look for it: they read it for the
        # seat's existence, its tools line and its return-pass heading. Codex loads no agents/ folder
        # from a plugin, so nothing here reaches the model
        write(out / "agents" / f.name, "---\n" + keep_keys(fm_text, ("name", "description", "tools")) + "\n---\n" + body)
        count += 1
    return count

# ---- hooks ---------------------------------------------------------------------------------------

def hooks_json():
    events = {}
    for event, matcher, hook, args, timeout in HOOKS:
        cmd = " ".join(['bash "${PLUGIN_ROOT}/hooks/codex-adapter.sh"', event, hook] + args + ['"${PLUGIN_ROOT}"'])
        group = {"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]}
        if matcher:
            group = {"matcher": matcher, **group}
        events.setdefault(event, []).append(group)
    return {"description": "kru's hooks, run through hooks/codex-adapter.sh", "hooks": events}

def build_hooks(out):
    (out / "hooks").mkdir(exist_ok=True)
    for f in sorted((REPO / "hooks").glob("*.sh")):
        if f.name.endswith(".test.sh"):
            continue
        shutil.copyfile(f, out / "hooks" / f.name)
        shutil.copymode(f, out / "hooks" / f.name)
    write(out / "hooks/hooks.json", json.dumps(hooks_json(), indent=2) + "\n")

# ---- the plugin ----------------------------------------------------------------------------------

def claim(out):
    """die unless out is absent, an empty directory, or a tree this script built."""
    if not out.exists():
        return
    if not out.is_dir():
        die(f"{out} is not a directory")
    if any(out.iterdir()) and not (out / MARKER).is_file():
        die(f"{out} exists and is not a tree this script built; pick an empty directory")

def build(out, root):
    out = Path(out)
    problems = table_problems()
    if problems:
        die("\n".join(problems))
    claim(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=f".{out.name}.", suffix=".kru-tmp", dir=out.parent))
    old = tmp.with_name(tmp.name + ".old")
    try:
        umask = os.umask(0); os.umask(umask)
        tmp.chmod(0o777 & ~umask)            # mkdtemp makes it 0700; out gets what mkdir would give it
        roles = build_tree(tmp, root)
        if out.exists():
            out.rename(old)
        tmp.rename(out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(old, ignore_errors=True)
    return roles

def build_tree(out, root):
    version = (REPO / "VERSION").read_text().strip()
    claude = json.loads((REPO / ".claude-plugin/plugin.json").read_text())
    manifest = {
        "name": "kru",
        "version": version,
        "description": claude["description"],
        "keywords": claude["keywords"],
        "skills": "./skills/",
        "hooks": "./hooks/hooks.json",
        "interface": {"displayName": "kru", "shortDescription": claude["description"]},
    }
    write(out / ".codex-plugin/plugin.json", json.dumps(manifest, indent=2) + "\n")
    build_skills(out, root)
    roles = build_roles(out, root)
    build_hooks(out)
    for name in ROOT_DOCS:
        copy_file(REPO / name, out / name, root, name)
    for d in COPY_DIRS:
        for f in sorted((REPO / d).rglob("*")):
            if f.is_file() and tracked(f):
                rel = f.relative_to(REPO).as_posix()
                copy_file(f, out / rel, root, rel)
    for s in RUNTIME_SCRIPTS:
        copy_file(REPO / s, out / s, root, s)
    for name in LEGAL:
        shutil.copyfile(REPO / name, out / name)
    write(out / MARKER, f"root={root}\n")
    return roles

def wrote_role(path):
    return path.is_file() and path.read_text(encoding="utf-8").startswith(ROLE_MARK + "\n")

def install(home):
    home = Path(home).resolve()
    plugin = home / "plugins" / "cache" / PLUGIN_ID[1] / PLUGIN_ID[0] / "local"
    agents = home / "agents"
    # every refusal before the first write: a role file in the way stops the install with the plugin
    # and the agents folder as they were
    taken = [agents / f"{f.stem}.toml" for f in sorted((REPO / "agents").glob("*.md"))]
    taken = [t for t in taken if t.exists() and not wrote_role(t)]
    if taken:
        die("these exist and are not role files this script wrote; move them aside:\n"
            + "\n".join(f"  {t}" for t in taken))
    roles = build(plugin, str(plugin))
    agents.mkdir(parents=True, exist_ok=True)
    fresh = {f.name for f in (plugin / "roles").glob("*.toml")}
    for old in agents.glob("*.toml"):
        if old.name not in fresh and wrote_role(old):
            old.unlink()
    for f in sorted((plugin / "roles").glob("*.toml")):
        shutil.copyfile(f, agents / f.name)
    print(f"installed kru {(REPO / 'VERSION').read_text().strip()}")
    print(f"  plugin  {plugin}")
    print(f"  roles   {roles} files in {agents}")
    print(f"config.toml is left as it is. To turn the plugin on, add to {home}/config.toml:")
    print(f'  [plugins."{PLUGIN_ID[0]}@{PLUGIN_ID[1]}"]')
    print("  enabled = true")
    print("If this install changed the build, approve the hooks again in Codex: it stops running a")
    print("plugin's hooks when any of the plugin's files change.")

# ---- check ---------------------------------------------------------------------------------------

def check(out):
    out = Path(out)
    bad = []
    def fail(msg): bad.append(msg)
    marker = out / MARKER
    if not out.is_dir():
        die(f"{out} is not a directory")
    if not marker.is_file():
        die(f"{out} is not a tree this script built")
    root = marker.read_text().strip().removeprefix("root=")
    try:
        man = json.loads((out / ".codex-plugin/plugin.json").read_text())
    except Exception as e:
        die(f"manifest does not parse: {e}")
    for key in ("name", "version", "skills", "hooks"):
        if not man.get(key):
            fail(f"manifest has no {key}")
    for key in ("skills", "hooks"):
        p = man.get(key, "")
        if not p.startswith("./") or not (out / p[2:]).exists():
            fail(f"manifest {key} path {p!r} is not a ./ path to something in the tree")
    # skills: folder name = frontmatter name, name at most 64 characters, a description, and a policy
    # file exactly where the Claude Code skill keeps the model off it
    src_skills = {p.name: p for p in (REPO / "skills").iterdir() if p.is_dir()}
    built = {p.name: p for p in (out / "skills").iterdir() if p.is_dir()}
    if set(src_skills) != set(built):
        fail(f"skills differ from the source: {sorted(set(src_skills) ^ set(built))}")
    for name, d in sorted(built.items()):
        fm = parse_fm(split_fm((d / "SKILL.md").read_text(encoding="utf-8"), name)[0])
        if fm.get("name") != name:
            fail(f"skill folder {name}: frontmatter name is {fm.get('name')!r}")
        if len(fm.get("name", "")) > 64 or not fm.get("description"):
            fail(f"skill {name}: name over 64 characters or no description")
        src_fm = parse_fm(split_fm((src_skills[name] / "SKILL.md").read_text(encoding="utf-8"), name)[0]) if name in src_skills else {}
        manual = src_fm.get("disable-model-invocation", "").lower() == "true"
        policy = d / "agents" / "openai.yaml"
        if manual != policy.is_file():
            fail(f"skill {name}: implicit-use policy file does not match the source")
    # roles
    for line in table_problems():
        fail(line)
    roles = sorted((out / "roles").glob("*.toml"))
    if len(roles) != len(list((REPO / "agents").glob("*.md"))):
        fail("role count differs from the seat count")
    for f in roles:
        try:
            t = tomllib.loads(f.read_text(encoding="utf-8"))
        except Exception as e:
            fail(f"{f.name}: does not parse as TOML: {e}"); continue
        if t.get("name") != f.stem or not t.get("description", "").strip() or not t.get("developer_instructions", "").strip():
            fail(f"{f.name}: needs name = file name, a description and developer_instructions")
        src = REPO / "agents" / f"{f.stem}.md"
        if src.is_file():
            fm = parse_fm(split_fm(src.read_text(encoding="utf-8"), f.stem)[0])
            want = seat_model(f.stem, fm)
            problem = effort_problem(f.stem, t.get("model"), t.get("model_reasoning_effort"))
            if problem:
                fail(f"{f.name}: {problem}")
            elif (t.get("model"), t.get("model_reasoning_effort")) != want:
                fail(f"{f.name}: model {t.get('model')!r} / effort {t.get('model_reasoning_effort')!r} is not the table's {want}")
        if t.get("model") not in MODELS_ALL:
            fail(f"{f.name}: model {t.get('model')!r} is not a gateway model")
    roster = out / "ROSTER.md"
    if roster.is_file() and roster_model_section() not in roster.read_text(encoding="utf-8"):
        fail("ROSTER.md: model section is not the one MODEL_TABLE gives")
    # hooks: parses, and every command names an adapter hook or a script that is in the tree
    try:
        hj = json.loads((out / "hooks/hooks.json").read_text())
        for event, groups in hj["hooks"].items():
            for g in groups:
                for h in g["hooks"]:
                    m = re.search(r"codex-adapter\.sh\" (\w+) ([\w-]+)", h["command"])
                    if not m or m.group(1) != event:
                        fail(f"hooks.json {event}: unreadable command {h['command']!r}")
                    elif m.group(2) not in ADAPTER_HOOKS and not (out / "hooks" / f"{m.group(2)}.sh").is_file():
                        fail(f"hooks.json {event}: no hooks/{m.group(2)}.sh in the tree")
    except Exception as e:
        fail(f"hooks.json: {e}")
    # leftovers, in what Codex or the model reads: skills, references, root docs, role files and the
    # manifests. hooks/ and scripts/ are programs run as they are, and agents/ is data they read
    scan = [out / ".codex-plugin/plugin.json", out / "hooks/hooks.json"] + roles
    scan += [out / d for d in ROOT_DOCS]
    for base in ("skills", "references"):
        scan += [f for f in sorted((out / base).rglob("*")) if f.is_file()]
    ticked = re.compile(r"`(" + "|".join(sorted(CLAUDE_ONLY)) + r")`")
    for f in scan:
        if not is_text(f):
            continue
        rel = f.relative_to(out).as_posix()
        text = f.read_text(encoding="utf-8")
        if "CLAUDE_PLUGIN_ROOT" in text:
            fail(f"{rel}: CLAUDE_PLUGIN_ROOT left")
        if rel.startswith(OWN_VOCABULARY) or not (f.suffix in (".md", ".toml")):
            continue
        for m in ticked.finditer(text):
            fail(f"{rel}: Claude Code tool name `{m.group(1)}` left")
        if "subagent_type" in text:
            fail(f"{rel}: subagent_type left")
    # no Claude model name anywhere in the tree, scripts and seat files included
    for f in sorted(out.rglob("*")):
        if f.is_file() and is_text(f):
            m = CLAUDE_MODEL_LEFT.search(f.read_text(encoding="utf-8"))
            if m:
                fail(f"{f.relative_to(out).as_posix()}: Claude model name {m.group(0)!r} left")
    # a path under the plugin root that resolves in the source resolves in the build
    ref = re.compile(re.escape(root) + r"/([A-Za-z0-9_][A-Za-z0-9_./-]*)")
    for f in scan:
        if not is_text(f):
            continue
        for m in ref.finditer(f.read_text(encoding="utf-8")):
            path = m.group(1).rstrip(".")
            if (REPO / path).exists() and not (out / path).exists():
                fail(f"{f.relative_to(out).as_posix()}: {root}/{path} exists in the source but not in the build")
    if bad:
        print("\n".join(sorted(set(bad))))
        print(f"build-codex: {len(set(bad))} problem(s)")
        sys.exit(1)
    print(f"build-codex: ok ({len(built)} skills, {len(roles)} roles, "
          f"{sum(len(g['hooks']) for gs in hj['hooks'].values() for g in gs)} hook commands)")

USAGE = """\
usage: build-codex.sh <out-dir>              build the plugin tree into <out-dir>
       build-codex.sh --install <codex-home> build into <codex-home>/plugins/cache/kru/kru/local and
                                             write the role files into <codex-home>/agents
       build-codex.sh --check <dir>          scan a built tree
       build-codex.sh --verify               build into a temp dir, check it, remove it
exit: 0 done, 1 failed (source tree, output path, --check problems), 64 bad flags or arguments
"""

def main(argv):
    if len(argv) == 2 and argv[1] in ("-h", "--help"):
        sys.stdout.write(USAGE)
    elif len(argv) == 2 and not argv[1].startswith("-"):
        n = build(argv[1], ROOT_TOKEN)
        print(f"built kru {(REPO / 'VERSION').read_text().strip()} for Codex into {argv[1]} ({n} roles)")
    elif len(argv) == 3 and argv[1] == "--install":
        install(argv[2])
    elif len(argv) == 3 and argv[1] == "--check":
        check(argv[2])
    elif len(argv) == 2 and argv[1] == "--verify":
        tmp = tempfile.mkdtemp()
        try:
            build(Path(tmp) / "out", ROOT_TOKEN)
            check(Path(tmp) / "out")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        print("build-codex: usage: build-codex.sh <out-dir> | --install <codex-home> | --check <dir> | --verify\n"
              "Run 'build-codex.sh --help' for more.", file=sys.stderr)
        sys.exit(64)

try:
    main(sys.argv)
except OSError as e:                     # a path that can't be read or written: one line, not a traceback
    die(str(e))
PY
