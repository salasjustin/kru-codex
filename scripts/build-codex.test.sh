#!/bin/bash
# tests for build-codex.sh: the build is repeatable, the install writes only what it owns, and the
# check catches what the build must never leave. run: bash scripts/build-codex.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
build="$here/build-codex.sh"

sandbox=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$sandbox"' EXIT
pass=0 fail=0
report() {
  if $2; then pass=$((pass + 1)); else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  %s\n' "$1" "$3"
  fi
}
check() { report "$1" "$( eval "$2" && echo true || echo false)" "${3:-}"; }

out="$sandbox/out"
bash "$build" "$out" >/dev/null 2>&1
check "builds a tree with a manifest" 'jq -e ".name == \"kru\" and .skills == \"./skills/\"" "$out/.codex-plugin/plugin.json" >/dev/null'
check "the build passes its own check" 'bash "$build" --check "$out" >/dev/null 2>&1'

cp -R "$out" "$sandbox/first"
bash "$build" "$out" >/dev/null 2>&1
check "a rebuild is byte-identical" 'diff -r "$sandbox/first" "$out" >/dev/null'

want=$(ls "$root/skills" | wc -l | tr -d ' ')
check "every skill folder is built" '[ "$(ls "$out/skills" | wc -l | tr -d " ")" = "$want" ]'
manual=$(grep -rl --include=SKILL.md '^disable-model-invocation: true' "$root/skills" | wc -l | tr -d ' ')
check "exactly the manual-only skills carry the implicit-use policy" '[ "$(ls "$out"/skills/*/agents/openai.yaml | wc -l | tr -d " ")" = "$manual" ] && grep -q "allow_implicit_invocation: false" "$out/skills/reflect/agents/openai.yaml"'
check "every seat is a role" '[ "$(ls "$out/roles" | wc -l | tr -d " ")" = "$(ls "$root/agents" | wc -l | tr -d " ")" ]'
check "a reviewer is read-only and a builder is not" 'grep -q "^sandbox_mode = \"read-only\"" "$out/roles/code-reviewer.toml" && ! grep -q "^sandbox_mode" "$out/roles/react-ui-builder.toml"'
model_is() { grep -q "^model = \"$2\"" "$out/roles/$1.toml"; }
effort_is() { if [ -z "$2" ]; then ! grep -q "^model_reasoning_effort" "$out/roles/$1.toml"; else grep -q "^model_reasoning_effort = \"$2\"" "$out/roles/$1.toml"; fi; }
# the four value tiers, by the brief's exact seat lists
deep_seats="better-auth-specialist chariot-specialist cloudflare-builder express-builder fly-platform-engineer go-fullstack-builder hono-builder nextjs-builder node-developer nowpayments-specialist paypal-specialist postgres-architect python-developer quickbooks-specialist react-router-builder sanity-builder sqlite-architect stripe-specialist sveltekit-builder tanstack-start-builder turso-specialist vercel-platform-engineer zapier-specialist zig-developer"
ui_seats="react-ui-builder svelte-ui-builder hono-ui-builder web-components-builder extension-builder motion-designer test-writer code-reviewer"
kimi_seats="planner architecture-reviewer"
light_seats="conversion-copywriter ux-auditor visual-reviewer accessibility-reviewer dispatch-auditor toolchain-engineer vercel-perf-optimizer"
check "the brief's four lists are 24, 8, 2 and 7 seats" '[ "$(printf "%s" "$deep_seats" | wc -w)" -eq 24 ] && [ "$(printf "%s" "$ui_seats" | wc -w)" -eq 8 ] && [ "$(printf "%s" "$kimi_seats" | wc -w)" -eq 2 ] && [ "$(printf "%s" "$light_seats" | wc -w)" -eq 7 ]'
group_is() { # <model> <seats...>: every named seat has that one model, and no other role does
  local m=$1; shift
  for s in "$@"; do grep -q "^model = \"$m\"" "$out/roles/$s.toml" || { echo "$s is not on $m"; return 1; }; done
  # the set of roles on the model is exactly this list
  local got want; got=$(grep -l "^model = \"$m\"" "$out"/roles/*.toml | xargs -n1 basename | sed 's/\.toml$//' | sort | tr '\n' ' ')
  want=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  [ "$got" = "$want" ] || { echo "roles on $m: $got"; return 1; }
}
check "deep engineering takes DeepSeek, and only those seats do" 'group_is deepseek/deepseek-v4.1-flash-1017 $deep_seats'
check "UI, tests and the code reviewer take MiniMax, and only those seats do" 'group_is minimax/minimax-m3.1-flash $ui_seats'
check "planner and architecture reviewer take Kimi K3.1 Pro, and only those seats do" 'group_is moonshotai/kimi-k3.1-pro $kimi_seats'
check "visual review and lighter work take Muse Ember, and only those seats do" 'group_is meta/muse-ember $light_seats'
alloc="$(printf '%s %s %s %s' "$deep_seats" "$ui_seats" "$kimi_seats" "$light_seats" | tr " " "\n")"
bad_count=$(printf '%s\n' "$alloc" | sort | uniq -d | wc -l | tr -d ' ')
check "all 41 current seats are in the four lists exactly once" '[ "$(printf "%s\n" "$alloc" | grep -c .)" -eq 41 ] && [ "$bad_count" = 0 ] && [ "$(ls "$root/agents"/*.md | xargs -n1 basename | sed "s/\.md$//" | sort | tr "\n" " ")" = "$(printf "%s\n" "$alloc" | sort | tr "\n" " ")" ]'
check "every role is on one of the four models, and every model is used" '[ "$(grep -h "^model = " "$out"/roles/*.toml | sort -u | tr "\n" " ")" = "$(printf "%s\n" "model = \"deepseek/deepseek-v4.1-flash-1017\"" "model = \"meta/muse-ember\"" "model = \"minimax/minimax-m3.1-flash\"" "model = \"moonshotai/kimi-k3.1-pro\"" | sort | tr "\n" " ")" ]'
# K3 itself, GLM, GPT-Sol and Anthropic ids. The K3 rule matches 'moonshotai/kimi-k3' followed by the
# closing quote or end of line, never 'kimi-k3.1-pro', and a planted pin keeps the pattern honest
old_re='moonshotai/kimi-k3"|moonshotai/kimi-k3$|zai/glm|openai/gpt-6.2-sol|anthropic/|claude-(opus|sonnet|haiku|fable)'
grep -rh "^model = " "$out"/roles | grep -Eq "$old_re"; scan=$?
check "no old or Anthropic model id remains in generated roles" '[ "$scan" -eq 1 ]' "grep exit $scan"
check "the old-id scan finds a planted Kimi K3 pin and not Kimi K3.1 Pro" '[ "$(printf "model = \"moonshotai/kimi-k3\"\nmodel = \"moonshotai/kimi-k3.1-pro\"\n" | grep -Ec "$old_re")" -eq 1 ]'
check "a seat's effort carries over unchanged, and none is invented" 'effort_is planner high && effort_is architecture-reviewer high && effort_is code-reviewer high && effort_is ux-auditor high && effort_is dispatch-auditor medium && effort_is toolchain-engineer medium && effort_is vercel-perf-optimizer medium && effort_is react-ui-builder "" && effort_is test-writer ""'
check "every effort pin is one its model accepts" 'for f in "$out"/roles/*.toml; do e=$(grep "^model_reasoning_effort" "$f" | sed "s/.*= \"//;s/\"//"); [ -n "$e" ] || continue; m=$(grep "^model = " "$f" | sed "s/.*= \"//;s/\"//"); case "$m:$e" in deepseek/deepseek-v4.1-flash-1017:none|deepseek/deepseek-v4.1-flash-1017:low|deepseek/deepseek-v4.1-flash-1017:high|deepseek/deepseek-v4.1-flash-1017:max|minimax/minimax-m3.1-flash:low|minimax/minimax-m3.1-flash:medium|minimax/minimax-m3.1-flash:high|minimax/minimax-m3.1-flash:xhigh|minimax/minimax-m3.1-flash:max|moonshotai/kimi-k3.1-pro:low|moonshotai/kimi-k3.1-pro:high|moonshotai/kimi-k3.1-pro:max|meta/muse-ember:minimal|meta/muse-ember:low|meta/muse-ember:medium|meta/muse-ember:high|meta/muse-ember:xhigh|meta/muse-ember:max) ;; *) echo "$f: $m/$e"; exit 1;; esac; done'
# grep exits 1 for "no match" and 2 for an error: `! grep` would pass on both, so the clean read is
# exit 1 exactly, paired with planted names the same pattern must find
model_re='claude-(opus|sonnet|haiku|fable)|\b(Opus|Sonnet|Haiku|Fable)\b'
grep -rEq "$model_re" "$out"; scan=$?
check "no Claude model name is anywhere in the build" '[ "$scan" -eq 1 ]' "grep exit $scan"
mkdir -p "$sandbox/planted"; printf 'pin claude-opus-5-5\n' > "$sandbox/planted/id"; printf 'ask Sonnet\n' > "$sandbox/planted/word"
check "the Claude model scan finds a planted model id and a planted model word" 'grep -rEl "$model_re" "$sandbox/planted" | wc -l | grep -q "^ *2$"'
check "reflect and text-fix say they need a Claude Code session and stop there" 'for n in reflect text-fix; do grep -q "needs a Claude Code session" "$out/skills/$n/SKILL.md" && [ "$(wc -l < "$out/skills/$n/SKILL.md")" -lt 12 ] || exit 1; done'
check "a shell call that ran reaches the adapter's record-read on PostToolUse" 'jq -e "[.hooks.PostToolUse[] | select(.matcher == \"Bash\") | .hooks[].command | select(test(\"codex-adapter\\\\.sh\\\" PostToolUse record-read \"))] | length == 1" "$out/hooks/hooks.json" >/dev/null'
check "plugin-root and tool names are rewritten" '! grep -rq "CLAUDE_PLUGIN_ROOT" "$out/skills" && grep -q "<plugin-root>/references/routing.md" "$out/skills/lead/SKILL.md"'

# the check fails on each thing it guards, and says which: a bare non-zero exit would stay green
# if the check died for some other reason
edit() { sed "$1" "$2" > "$sandbox/x" && cp "$sandbox/x" "$2"; }
mutate() { # <label> <text the check must print> <edit, run inside a copy of the built tree>
  rm -rf "$sandbox/leak"; cp -R "$out" "$sandbox/leak"
  (cd "$sandbox/leak" && eval "$3")
  msg=$(bash "$build" --check "$sandbox/leak" 2>&1); c=$?
  report "$1" "$([ "$c" -ne 0 ] && printf '%s' "$msg" | grep -qF -- "$2" && echo true || echo false)" "exit $c, wanted [$2] in: $msg"
}
mutate "a plugin-root variable left in a skill fails the check" "CLAUDE_PLUGIN_ROOT left" 'printf "%s\n" "run \${CLAUDE_PLUGIN_ROOT}/x" >> skills/lead/SKILL.md'
mutate "a Claude tool name left in a skill fails the check" 'Claude Code tool name `Bash` left' 'printf "%s\n" "then use the \`Bash\` tool" >> skills/lead/SKILL.md'
mutate "a Claude model name left in a skill fails the check" "Claude model name 'claude-opus' left" 'printf "%s\n" "pin claude-opus-5-5" >> skills/lead/SKILL.md'
mutate "a subagent_type left in a skill fails the check" "skills/lead/SKILL.md: subagent_type left" 'printf "%s\n" "set subagent_type to x" >> skills/lead/SKILL.md'
mutate "a role that is not TOML fails the check" "code-reviewer.toml: does not parse as TOML" 'printf "%s\n" "not = = toml" >> roles/code-reviewer.toml'
mutate "a skill whose name differs from its folder fails the check" "skill folder lead: frontmatter name is 'leader'" 'edit "s/^name: lead\$/name: leader/" skills/lead/SKILL.md'
mutate "a role pinned off the model table fails the check" "code-reviewer.toml: model 'moonshotai/kimi-k3' / effort 'high' is not the table's" 'edit "s#^model = .*#model = \"moonshotai/kimi-k3\"#" roles/code-reviewer.toml'
mutate "a role on a model outside the gateway list fails the check" "code-reviewer.toml: model 'zz/unlisted' is not a gateway model" 'edit "s#^model = .*#model = \"zz/unlisted\"#" roles/code-reviewer.toml'
mutate "a role with an empty description fails the check" "code-reviewer.toml: needs name = file name, a description and developer_instructions" 'edit "s#^description = .*#description = \"\"#" roles/code-reviewer.toml'
mutate "a role file missing fails the check" "role count differs from the seat count" 'rm roles/test-writer.toml'
mutate "a manifest without its hooks key fails the check" "manifest has no hooks" 'jq "del(.hooks)" .codex-plugin/plugin.json > "$sandbox/x" && cp "$sandbox/x" .codex-plugin/plugin.json'
mutate "a manifest path that is not ./ fails the check" "manifest skills path 'skills/' is not a ./ path" 'jq ".skills = \"skills/\"" .codex-plugin/plugin.json > "$sandbox/x" && cp "$sandbox/x" .codex-plugin/plugin.json'
mutate "a skill dropped from the build fails the check" "skills differ from the source: ['lead']" 'rm -rf skills/lead'
mutate "a manual-only skill without its policy file fails the check" "skill reflect: implicit-use policy file does not match the source" 'rm "skills/reflect/"agents/*.yaml'
mutate "a hook command the check cannot read fails the check" "unreadable command" 'edit "s/codex-adapter\\.sh/codex-adaptor.sh/" hooks/hooks.json'
mutate "a hook whose script is not in the tree fails the check" "no hooks/lead-first.sh in the tree" 'rm hooks/lead-first.sh'
mutate "a plugin-root path that resolves in the source but not in the build fails the check" "<plugin-root>/README.md exists in the source but not in the build" 'printf "%s\n" "see <plugin-root>/README.md" >> skills/lead/SKILL.md'

# a seat in no kind of the model table fails the build until it is placed
src="$sandbox/src"; mkdir -p "$src"
git -C "$root" ls-files -z | tar -C "$root" --null -T - -cf - | tar -C "$src" -xf -
sed 's/^name: stripe-specialist$/name: zz-new-seat/' "$root/agents/stripe-specialist.md" > "$src/agents/zz-new-seat.md"
msg=$(bash "$src/scripts/build-codex.sh" "$sandbox/unlisted" 2>&1); c=$?
check "a new seat missing from the model table fails the build" '[ "$c" -ne 0 ] && printf "%s" "$msg" | grep -q "agents/zz-new-seat.md is in no seat kind"' "$msg"

# an effort pin the model does not accept fails the build; one it accepts builds and is kept in the
# role. --check holds both against the source table, and against a role it is handed as already built.
esrc="$sandbox/esrc"; mkdir -p "$esrc"
git -C "$root" ls-files -z | tar -C "$root" --null -T - -cf - | tar -C "$esrc" -xf -
# esed fails loudly when its sed changed nothing: a pin that drifted in agents/*.md would otherwise
# leave the source untouched and the case below it would go red for an unrelated reason
esed() {
  sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"
  cmp -s "$2" "$root/${2#"$esrc"/}" && { report "esed: sed matched nothing in ${2#"$esrc"/}" false "[$1] left the file as the source has it"; return 1; }
  return 0
}
# each case edits one agent file; putting it back keeps every build one line away from the source
ereset() { cp "$root/agents/$1.md" "$esrc/agents/$1.md"; }
eout="$sandbox/efforts"
esed 's/^effort: .*$/effort: minimal/' "$esrc/agents/dispatch-auditor.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "Muse Ember accepts minimal, so dispatch-auditor builds on it" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"minimal\"" "$eout/roles/dispatch-auditor.toml"' "exit $c"
rm -rf "$eout"; ereset dispatch-auditor
esed 's/^effort: .*$/effort: minimal/' "$esrc/agents/planner.md"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "an unsupported effort pin fails the build and names the model's set" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "agents/planner.md: effort '\''minimal'\'' is not one moonshotai/kimi-k3.1-pro accepts (high, low, max)"' "exit $c [$msg]"
check "a failed build leaves no tree" '[ ! -e "$eout" ]'
ereset planner
esed 's/^effort: .*$/effort: max/' "$esrc/agents/planner.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "the same seat takes an effort Kimi does accept, and keeps it" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"max\"" "$eout/roles/planner.toml"' "exit $c"
rm -rf "$eout"; ereset planner
esed 's/^effort: .*$/effort: none/' "$esrc/agents/code-reviewer.md"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "MiniMax has no none, so a none pin there fails the build" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "is not one minimax/minimax-m3.1-flash accepts" ' "exit $c [$msg]"
ereset code-reviewer
esed 's/^effort: .*$/effort: xhigh/' "$esrc/agents/code-reviewer.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "MiniMax does accept xhigh, and keeps it" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"xhigh\"" "$eout/roles/code-reviewer.toml"' "exit $c"
rm -rf "$eout"; ereset code-reviewer
esed 's/^model: .*$/&\neffort: none/' "$esrc/agents/stripe-specialist.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "an explicit none on DeepSeek builds and is kept" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"none\"" "$eout/roles/stripe-specialist.toml"' "exit $c"
rm -rf "$eout"; ereset stripe-specialist
# the seat's kind picks its model: a different Claude id in its model: row changes nothing
esed 's/^model: .*$/model: claude-haiku-5-5/' "$esrc/agents/stripe-specialist.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "a seat's Claude model pin does not pick its model" '[ "$c" -eq 0 ] && grep -q "^model = \"deepseek/deepseek-v4.1-flash-1017\"" "$eout/roles/stripe-specialist.toml"' "exit $c"
rm -rf "$eout"; ereset stripe-specialist
# a model dropped from MODEL_EFFORTS no longer matches the table: the build names both and exits 1
esed '/^    LIGHT: {"minimal"/d' "$esrc/scripts/build-codex.sh"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "a model in MODEL_TABLE but not in MODEL_EFFORTS fails the build and says so" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "build-codex: MODEL_EFFORTS lists"' "exit $c [$msg]"
rm -rf "$esrc" "$eout"
rm -rf "$sandbox/leak"; cp -R "$out" "$sandbox/leak"
edit 's/^model_reasoning_effort = .*/model_reasoning_effort = "minimal"/' "$sandbox/leak/roles/code-reviewer.toml"
msg=$(bash "$build" --check "$sandbox/leak" 2>&1); c=$?
report "a built role with an unsupported effort fails the check" "$([ "$c" -ne 0 ] && printf '%s' "$msg" | grep -qF "effort 'minimal' is not one minimax/minimax-m3.1-flash accepts" && echo true || echo false)" "exit $c: $msg"
rm -rf "$sandbox/leak"

# the install
home="$sandbox/codex-home"
mkdir -p "$home/agents"
printf 'model = "kept"\n' > "$home/config.toml"
printf 'name = "mine"\ndescription = "x"\ndeveloper_instructions = "x"\n' > "$home/agents/mine.toml"
msg=$(bash "$build" --install "$home" 2>&1)
plugin="$home/plugins/cache/kru/kru/local"
check "install puts the plugin where Codex keeps an installed one" '[ -f "$plugin/.codex-plugin/plugin.json" ]'
check "install puts the roles in the home's agents folder" '[ "$(ls "$home"/agents/*.toml | wc -l | tr -d " ")" = "$(( $(ls "$root/agents" | wc -l) + 1 ))" ]'
check "install leaves config.toml and a role it did not write alone" '[ "$(cat "$home/config.toml")" = "model = \"kept\"" ] && [ -f "$home/agents/mine.toml" ]'
check "install resolves the plugin root to the install path" 'grep -q "$plugin/references/routing.md" "$plugin/skills/lead/SKILL.md" && ! grep -rq "<plugin-root>" "$plugin/skills" "$plugin/roles"'
check "install names the config entry and does not write it" 'printf "%s" "$msg" | grep -q "plugins.\"kru@kru\"" && ! grep -q plugins "$home/config.toml"'
check "install says the hooks need approving again after a changed build" 'printf "%s" "$msg" | grep -qi "approve the hooks again"'
check "an installed tree passes the check" 'bash "$build" --check "$plugin" >/dev/null 2>&1'
bash "$build" --install "$home" >/dev/null 2>&1
check "a second install is a no-op in effect" '[ "$(ls "$home"/agents/*.toml | wc -l | tr -d " ")" = "$(( $(ls "$root/agents" | wc -l) + 1 ))" ]'

mkdir -p "$sandbox/other" && printf 'x' > "$sandbox/other/file"
bash "$build" "$sandbox/other" >/dev/null 2>&1; c=$?
check "a directory the script did not build is refused, not wiped" '[ "$c" -ne 0 ] && [ -f "$sandbox/other/file" ]'

# a failed build changes nothing: the previous tree stays whole, no temp folder is left, and a rerun
# after the cause is gone succeeds
fsrc="$sandbox/fsrc"; cp -R "$src" "$fsrc"; rm "$fsrc/agents/zz-new-seat.md"
fbuild="$fsrc/scripts/build-codex.sh"
fout="$sandbox/fbuilds/out"
bash "$fbuild" "$fout" >/dev/null 2>&1
cp -R "$fout" "$sandbox/fprev"
mkdir "$fsrc/skills/zz-broken"
msg=$(bash "$fbuild" "$fout" 2>&1); c=$?
check "a build that fails says which skill and exits 1" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "skills/zz-broken: no SKILL.md"' "exit $c [$msg]"
check "a failed build leaves the previous tree intact" 'diff -r "$sandbox/fprev" "$fout" >/dev/null' "$(diff -rq "$sandbox/fprev" "$fout" 2>&1 | head -3)"
check "a failed build leaves no temp folder beside the tree" '[ "$(ls -A "$sandbox/fbuilds")" = "out" ]' "$(ls -A "$sandbox/fbuilds")"
rmdir "$fsrc/skills/zz-broken"
bash "$fbuild" "$fout" >/dev/null 2>&1; c=$?
check "a rerun after removing the cause succeeds" '[ "$c" -eq 0 ] && bash "$fbuild" --check "$fout" >/dev/null 2>&1' "exit $c"
mkdir "$fsrc/skills/zz-broken"
bash "$fbuild" "$sandbox/fbuilds/fresh" >/dev/null 2>&1; c=$?
check "a failed first build leaves neither a tree nor a temp folder" '[ "$c" -eq 1 ] && [ "$(ls -A "$sandbox/fbuilds")" = "out" ]' "exit $c [$(ls -A "$sandbox/fbuilds")]"
rmdir "$fsrc/skills/zz-broken"

# an install refused for a foreign role file writes nothing: the message names the file, the plugin
# dir and the other roles are absent, and what was there is as it was
ihome="$sandbox/ihome"; mkdir -p "$ihome/agents"
printf 'name = "code-reviewer"\n# mine\n' > "$ihome/agents/code-reviewer.toml"
printf '# kru-codex-build\nname = "gone-seat"\n' > "$ihome/agents/gone-seat.toml"
printf 'name = "mine"\n' > "$ihome/agents/mine.toml"
cp -R "$ihome" "$sandbox/ihome-before"
msg=$(bash "$build" --install "$ihome" 2>&1); c=$?
check "install over a foreign role file exits non-zero and names the file" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -qF "$ihome/agents/code-reviewer.toml"' "exit $c [$msg]"
check "a refused install writes nothing" '[ ! -e "$ihome/plugins" ] && diff -r "$sandbox/ihome-before" "$ihome" >/dev/null' "$(diff -rq "$sandbox/ihome-before" "$ihome" 2>&1 | head -3)"
rm -rf "$ihome"; mkdir -p "$ihome"
bash "$build" --install "$ihome" >/dev/null 2>&1
printf 'name = "code-reviewer"\n# mine\n' > "$ihome/agents/code-reviewer.toml"
printf '# kru-codex-build\nname = "gone-seat"\n' > "$ihome/agents/gone-seat.toml"
cp -R "$ihome" "$sandbox/ihome-before2"
bash "$build" --install "$ihome" >/dev/null 2>&1; c=$?
check "a refused install over an earlier one leaves the plugin, the roles and a stale role as they were" '[ "$c" -eq 1 ] && diff -r "$sandbox/ihome-before2" "$ihome" >/dev/null' "exit $c $(diff -rq "$sandbox/ihome-before2" "$ihome" 2>&1 | head -3)"

# exit codes: 0 done, 1 failed, 64 usage
help=$(bash "$build" --help 2>"$sandbox/helperr"); c=$?
check "--help prints the usage to stdout and exits 0" '[ "$c" -eq 0 ] && printf "%s" "$help" | grep -q "^usage:" && [ ! -s "$sandbox/helperr" ]' "exit $c"
bash "$build" --nope >/dev/null 2>&1; c=$?
check "a bad flag exits 64" '[ "$c" -eq 64 ]' "exit $c"
bash "$build" >/dev/null 2>&1; c=$?
check "no arguments exits 64" '[ "$c" -eq 64 ]' "exit $c"
printf 'x' > "$sandbox/afile"
msg=$(bash "$build" "$sandbox/afile" 2>&1); c=$?
check "an output path that is a file exits 1 with one line, no traceback" '[ "$c" -eq 1 ] && ! printf "%s" "$msg" | grep -q Traceback && printf "%s" "$msg" | grep -qF "$sandbox/afile" && [ "$(printf "%s\n" "$msg" | wc -l | tr -d " ")" = 1 ] && [ "$(cat "$sandbox/afile")" = x ]' "exit $c [$msg]"
msg=$(bash "$build" --check "$sandbox/afile" 2>&1); c=$?
check "--check of a file exits 1 with no traceback" '[ "$c" -eq 1 ] && ! printf "%s" "$msg" | grep -q Traceback' "exit $c [$msg]"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
