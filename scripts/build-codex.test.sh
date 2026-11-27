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
# the four seat kinds of MODEL_TABLE, seat by seat
deep_seats="better-auth-specialist chariot-specialist cloudflare-builder express-builder fly-platform-engineer go-fullstack-builder hono-builder nextjs-builder node-developer nowpayments-specialist paypal-specialist postgres-architect python-developer quickbooks-specialist react-router-builder sanity-builder sqlite-architect stripe-specialist sveltekit-builder tanstack-start-builder turso-specialist vercel-platform-engineer zapier-specialist zig-developer react-ui-builder svelte-ui-builder hono-ui-builder web-components-builder extension-builder motion-designer"
glm_seats="code-reviewer test-writer"
kimi_seats="planner architecture-reviewer"
light_seats="conversion-copywriter ux-auditor visual-reviewer accessibility-reviewer dispatch-auditor toolchain-engineer vercel-perf-optimizer"
check "the four lists are 30, 2, 2 and 7 seats" '[ "$(printf "%s" "$deep_seats" | wc -w)" -eq 30 ] && [ "$(printf "%s" "$glm_seats" | wc -w)" -eq 2 ] && [ "$(printf "%s" "$kimi_seats" | wc -w)" -eq 2 ] && [ "$(printf "%s" "$light_seats" | wc -w)" -eq 7 ]'
group_is() { # <model> <seats...>: every named seat has that one model, and no other role does
  local m=$1; shift
  for s in "$@"; do grep -q "^model = \"$m\"" "$out/roles/$s.toml" || { echo "$s is not on $m"; return 1; }; done
  # the set of roles on the model is exactly this list
  local got want; got=$(grep -l "^model = \"$m\"" "$out"/roles/*.toml | xargs -n1 basename | sed 's/\.toml$//' | sort | tr '\n' ' ')
  want=$(printf '%s\n' "$@" | sort | tr '\n' ' ')
  [ "$got" = "$want" ] || { echo "roles on $m: $got"; return 1; }
}
check "deep engineering and the UI builders take DeepSeek V4.1 Flash, and only those seats do" 'group_is deepseek/deepseek-v4.1-flash $deep_seats'
check "the code reviewer and test writer take GLM 5.3, and only those seats do" 'group_is zai/glm-5.3 $glm_seats'
check "planner and architecture reviewer take Kimi K3.1 Pro, and only those seats do" 'group_is moonshotai/kimi-k3.1-pro $kimi_seats'
check "visual review and lighter work take GLM 5.3 Flash, and only those seats do" 'group_is zai/glm-5.3-flash $light_seats'
# the catalog row (modalities.input, read 2026-11-27) of the one allowed model that takes text only
text_only_models="zai/glm-5.3"
check "the six UI builders, motion-designer among them, and the seven visual seats sit on a model whose catalog row takes image input" 'for s in react-ui-builder svelte-ui-builder hono-ui-builder web-components-builder extension-builder motion-designer $light_seats; do m=$(grep "^model = " "$out/roles/$s.toml" | sed "s/.*= \"//;s/\"//"); case " $text_only_models " in *" $m "*) echo "$s is on text-only $m"; exit 1;; esac; done'
alloc="$(printf '%s %s %s %s' "$deep_seats" "$glm_seats" "$kimi_seats" "$light_seats" | tr " " "\n")"
bad_count=$(printf '%s\n' "$alloc" | sort | uniq -d | wc -l | tr -d ' ')
check "all 41 current seats are in the four lists exactly once" '[ "$(printf "%s\n" "$alloc" | grep -c .)" -eq 41 ] && [ "$bad_count" = 0 ] && [ "$(ls "$root/agents"/*.md | xargs -n1 basename | sed "s/\.md$//" | sort | tr "\n" " ")" = "$(printf "%s\n" "$alloc" | sort | tr "\n" " ")" ]'
# the five allowed models: four carry seats, and moonshotai/kimi-k3 is allowed and carries none
allowed_models="deepseek/deepseek-v4.1-flash zai/glm-5.3-flash zai/glm-5.3 moonshotai/kimi-k3.1-pro moonshotai/kimi-k3"
roles_models=$(grep -h "^model = " "$out"/roles/*.toml | sed 's/.*= "//;s/"$//' | sort -u | tr '\n' ' ')
check "the four assigned models each appear on a role" '[ "$roles_models" = "deepseek/deepseek-v4.1-flash moonshotai/kimi-k3.1-pro zai/glm-5.3 zai/glm-5.3-flash " ]' "[$roles_models]"
check "moonshotai/kimi-k3 appears on no role" '! grep -q "^model = \"moonshotai/kimi-k3\"" "$out"/roles/*.toml'
check "no role is on anything outside the five allowed models" 'for m in $roles_models; do case " $allowed_models " in *" $m "*) ;; *) echo "outside: $m"; exit 1;; esac; done'
# the replaced MiniMax, Muse Ember, GPT-Sol and 1017 DeepSeek ids, a bare Kimi K3 pin, and Anthropic ones.
# The K3 rule matches 'moonshotai/kimi-k3' followed by the closing quote or end of line, never
# 'kimi-k3.1-pro'. Each is planted below, so the pattern is known to find it
# (the ids are spelled with a bracket or a quote break so a repo-wide search for them finds only code that is live)
old_re='minima[x]/|muse-embe[r]|gpt-6\.2-so[l]|deepseek-v4\.1-flash-101[7]|moonshotai/kimi-k3"|moonshotai/kimi-k3$|anthropic/|claude-(opus|sonnet|haiku|fable)'
grep -rh "^model = " "$out"/roles | grep -Eq "$old_re"; scan=$?
check "no old or Anthropic model id remains in generated roles" '[ "$scan" -eq 1 ]' "grep exit $scan"
for planted in 'mini''max/mini''max-m3.1-flash' 'meta/muse-''ember' 'openai/gpt-6.2-''sol' 'deepseek/deepseek-v4.1-flash-10''17' 'moonshotai/kimi-k3'; do
  check "the old-id scan finds a planted $planted pin" '[ "$(printf "model = \"%s\"\n" "$planted" | grep -Ec "$old_re")" -eq 1 ]'
done
check "the old-id scan does not find Kimi K3.1 Pro or the five allowed models" '[ "$(for m in $allowed_models; do [ "$m" = moonshotai/kimi-k3 ] || printf "model = \"%s\"\n" "$m"; done | grep -Ec "$old_re")" -eq 0 ]'
check "a pin the model takes carries over, one it does not rounds up, and none is invented" 'effort_is planner high && effort_is architecture-reviewer high && effort_is code-reviewer high && effort_is ux-auditor high && effort_is dispatch-auditor high && effort_is toolchain-engineer high && effort_is vercel-perf-optimizer high && effort_is react-ui-builder "" && effort_is test-writer ""'
check "every effort in a role is one its model accepts" 'for f in "$out"/roles/*.toml; do e=$(grep "^model_reasoning_effort" "$f" | sed "s/.*= \"//;s/\"//"); [ -n "$e" ] || continue; m=$(grep "^model = " "$f" | sed "s/.*= \"//;s/\"//"); case "$m:$e" in deepseek/deepseek-v4.1-flash:none|deepseek/deepseek-v4.1-flash:low|deepseek/deepseek-v4.1-flash:high|deepseek/deepseek-v4.1-flash:max|zai/glm-5.3:low|zai/glm-5.3:high|zai/glm-5.3:max|zai/glm-5.3-flash:low|zai/glm-5.3-flash:high|zai/glm-5.3-flash:max|moonshotai/kimi-k3.1-pro:low|moonshotai/kimi-k3.1-pro:high|moonshotai/kimi-k3.1-pro:max|moonshotai/kimi-k3:low|moonshotai/kimi-k3:high|moonshotai/kimi-k3:max) ;; *) echo "$f: $m/$e"; exit 1;; esac; done'
build_lines=$(bash "$build" "$sandbox/lines" 2>&1 | grep "effort '"; rm -rf "$sandbox/lines")
check "the build prints the line for each of the three medium pins, and every line it prints is an adjustment" '! printf "%s\n" "$build_lines" | grep -v "^build-codex: agents/[a-z-]*\.md: effort .* -> .* (.* accepts .*)$" | grep -q . && for s in dispatch-auditor toolchain-engineer vercel-perf-optimizer; do printf "%s\n" "$build_lines" | grep -qxF "build-codex: agents/$s.md: effort '\''medium'\'' -> '\''high'\'' (zai/glm-5.3-flash accepts low, high, max)" || exit 1; done' "$build_lines"
# grep exits 1 for "no match" and 2 for an error: `! grep` would pass on both, so the clean read is
# exit 1 exactly, paired with planted names the same pattern must find
model_re='claude-(opus|sonnet|haiku|fable)|\b(Opus|Sonnet|Haiku|Fable)\b'
grep -rEq "$model_re" "$out"; scan=$?
check "no Claude model name is anywhere in the build" '[ "$scan" -eq 1 ]' "grep exit $scan"
mkdir -p "$sandbox/planted"; printf 'pin claude-opus-5-5\n' > "$sandbox/planted/id"; printf 'ask Sonnet\n' > "$sandbox/planted/word"
check "the Claude model scan finds a planted model id and a planted model word" 'grep -rEl "$model_re" "$sandbox/planted" | wc -l | grep -q "^ *2$"'
# the built ROSTER.md's model section comes from MODEL_TABLE: one row per kind, and every seat is in
# exactly one row, the one on its table model
roster_models=$(awk '/^## Model tiers$/ {on=1; next} on && /^## / {exit} on' "$out/ROSTER.md")
roster_rows=$(printf '%s\n' "$roster_models" | grep '^| ' | grep -v '^| seat kind ')
roster_seat_is() { # <model> <seats...>: each seat is named in one row of the section, and that row is on the model
  local m=$1 s rows; shift
  for s in "$@"; do
    rows=$(printf '%s\n' "$roster_rows" | grep -F "\`$s\`")
    [ "$(printf '%s\n' "$rows" | grep -c .)" -eq 1 ] || { echo "$s is in $(printf '%s\n' "$rows" | grep -c .) rows"; return 1; }
    printf '%s' "$rows" | grep -qF "| \`$m\` |" || { echo "$s is not on $m in ROSTER.md"; return 1; }
  done
}
check "the built ROSTER.md has one model row per seat kind" '[ "$(printf "%s\n" "$roster_rows" | grep -c .)" -eq 4 ]' "$roster_rows"
check "the built ROSTER.md names every seat with exactly its MODEL_TABLE model" 'roster_seat_is deepseek/deepseek-v4.1-flash $deep_seats && roster_seat_is zai/glm-5.3 $glm_seats && roster_seat_is moonshotai/kimi-k3.1-pro $kimi_seats && roster_seat_is zai/glm-5.3-flash $light_seats'
check "the built ROSTER.md lists each model'\''s accepted efforts" 'printf "%s\n" "$roster_rows" | grep -F "\`moonshotai/kimi-k3.1-pro\`" | grep -qF "| \`low\` \`high\` \`max\` |"'
check "the built ROSTER.md names MODEL_TABLE as the source and README for prices" 'printf "%s" "$roster_models" | grep -q "MODEL_TABLE.*scripts/build-codex.sh.*README.*prices"'
check "the built ROSTER.md drops the Claude pricing rationale" '! grep -qE "premium tier|Why full model IDs|Why pinned instead of inherit" "$out/ROSTER.md"'
grep -Eq 'claude-(opus|sonnet|haiku|fable)' "$out/ROSTER.md"; scan=$?
check "the built ROSTER.md holds no Claude model id" '[ "$scan" -eq 1 ]' "grep exit $scan"

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
mutate "a role on an effort its model accepts but its seat does not use fails the check" "planner.toml: model 'moonshotai/kimi-k3.1-pro' / effort 'low' is not the table's" 'edit "s#^model_reasoning_effort = .*#model_reasoning_effort = \"low\"#" roles/planner.toml'
retired='mini''max/mini''max-m3.1-flash'
mutate "a role on a retired model fails the check as outside the five allowed" "code-reviewer.toml: model '$retired' is not one of the five allowed models" 'edit "s#^model = .*#model = \"$retired\"#" roles/code-reviewer.toml'
mutate "a role on a model outside the five allowed fails the check" "code-reviewer.toml: model 'zz/unlisted' is not one of the five allowed models" 'edit "s#^model = .*#model = \"zz/unlisted\"#" roles/code-reviewer.toml'
mutate "a role with an empty description fails the check" "code-reviewer.toml: needs name = file name, a description and developer_instructions" 'edit "s#^description = .*#description = \"\"#" roles/code-reviewer.toml'
mutate "a role file missing fails the check" "role count differs from the seat count" 'rm roles/test-writer.toml'
mutate "a manifest without its hooks key fails the check" "manifest has no hooks" 'jq "del(.hooks)" .codex-plugin/plugin.json > "$sandbox/x" && cp "$sandbox/x" .codex-plugin/plugin.json'
mutate "a manifest path that is not ./ fails the check" "manifest skills path 'skills/' is not a ./ path" 'jq ".skills = \"skills/\"" .codex-plugin/plugin.json > "$sandbox/x" && cp "$sandbox/x" .codex-plugin/plugin.json'
mutate "a skill dropped from the build fails the check" "skills differ from the source: ['lead']" 'rm -rf skills/lead'
mutate "a manual-only skill without its policy file fails the check" "skill reflect: implicit-use policy file does not match the source" 'rm "skills/reflect/"agents/*.yaml'
mutate "a hook command the check cannot read fails the check" "unreadable command" 'edit "s/codex-adapter\\.sh/codex-adaptor.sh/" hooks/hooks.json'
mutate "a hook whose script is not in the tree fails the check" "no hooks/lead-first.sh in the tree" 'rm hooks/lead-first.sh'
mutate "a plugin-root path that resolves in the source but not in the build fails the check" "<plugin-root>/README.md exists in the source but not in the build" 'printf "%s\n" "see <plugin-root>/README.md" >> skills/lead/SKILL.md'
mutate "a ROSTER.md model row moved off its MODEL_TABLE model fails the check" "ROSTER.md: model section is not the one MODEL_TABLE gives" 'edit "s#^\(| Planning and architecture review | .*\)moonshotai/kimi-k3.1-pro#\1zai/glm-5.3#" ROSTER.md'

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
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "GLM 5.3 Flash has no minimal, so a minimal pin builds as low with the build line" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"low\"" "$eout/roles/dispatch-auditor.toml" && printf "%s\n" "$msg" | grep -qxF "build-codex: agents/dispatch-auditor.md: effort '\''minimal'\'' -> '\''low'\'' (zai/glm-5.3-flash accepts low, high, max)"' "exit $c [$msg]"
rm -rf "$eout"; ereset dispatch-auditor
esed 's/^effort: .*$/effort: bogus/' "$esrc/agents/planner.md"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "a pin that is no ReasoningEffort value fails the build and names the model's set" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "agents/planner.md: effort '\''bogus'\'' is not a ReasoningEffort value; moonshotai/kimi-k3.1-pro accepts low, high, max"' "exit $c [$msg]"
check "a failed build leaves no tree" '[ ! -e "$eout" ]'
ereset planner
esed 's/^effort: .*$/effort: max/' "$esrc/agents/planner.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "a pin Kimi does accept is kept" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"max\"" "$eout/roles/planner.toml"' "exit $c"
rm -rf "$eout"; ereset planner
esed 's/^effort: .*$/effort: medium/' "$esrc/agents/code-reviewer.md"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "GLM 5.3 has no medium, so a medium pin builds as high with the build line" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"high\"" "$eout/roles/code-reviewer.toml" && printf "%s\n" "$msg" | grep -qxF "build-codex: agents/code-reviewer.md: effort '\''medium'\'' -> '\''high'\'' (zai/glm-5.3 accepts low, high, max)"' "exit $c [$msg]"
rm -rf "$eout"; ereset code-reviewer
esed 's/^effort: .*$/effort: none/' "$esrc/agents/code-reviewer.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "GLM 5.3 has no none either, so a none pin builds as low" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"low\"" "$eout/roles/code-reviewer.toml"' "exit $c"
rm -rf "$eout"; ereset code-reviewer
esed 's/^model: .*$/&\neffort: xhigh/' "$esrc/agents/stripe-specialist.md"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "a planted xhigh on the DeepSeek group builds as max with the build line" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"max\"" "$eout/roles/stripe-specialist.toml" && printf "%s\n" "$msg" | grep -qxF "build-codex: agents/stripe-specialist.md: effort '\''xhigh'\'' -> '\''max'\'' (deepseek/deepseek-v4.1-flash accepts none, low, high, max)"' "exit $c [$msg]"
rm -rf "$eout"; ereset stripe-specialist
# no accepted value at or above the pin fails the build: drop max from Kimi's set and pin xhigh
esed 's/^effort: .*$/effort: xhigh/' "$esrc/agents/planner.md"
esed 's/^    KIMI: {"low", "high", "max"},$/    KIMI: {"low", "high"},/' "$esrc/scripts/build-codex.sh"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "a pin with no accepted value at or above it fails the build" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "agents/planner.md: effort '\''xhigh'\'' is not one moonshotai/kimi-k3.1-pro accepts (low, high), and none at or above it"' "exit $c [$msg]"
rm -rf "$eout"; ereset planner; cp "$root/scripts/build-codex.sh" "$esrc/scripts/build-codex.sh"
esed 's/^model: .*$/&\neffort: none/' "$esrc/agents/stripe-specialist.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "an explicit none on DeepSeek builds and is kept" '[ "$c" -eq 0 ] && grep -q "^model_reasoning_effort = \"none\"" "$eout/roles/stripe-specialist.toml"' "exit $c"
rm -rf "$eout"; ereset stripe-specialist
# the seat's kind picks its model: a different Claude id in its model: row changes nothing
esed 's/^model: .*$/model: claude-haiku-5-5/' "$esrc/agents/stripe-specialist.md"
bash "$esrc/scripts/build-codex.sh" "$eout" >/dev/null 2>&1; c=$?
check "a seat's Claude model pin does not pick its model" '[ "$c" -eq 0 ] && grep -q "^model = \"deepseek/deepseek-v4.1-flash\"" "$eout/roles/stripe-specialist.toml"' "exit $c"
rm -rf "$eout"; ereset stripe-specialist
# a model dropped from MODEL_EFFORTS no longer matches the allowed set: the build names both and exits 1
esed '/^    GLM_FLASH: {"low"/d' "$esrc/scripts/build-codex.sh"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "an allowed model without a MODEL_EFFORTS row fails the build and says so" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "build-codex: MODEL_EFFORTS lists"' "exit $c [$msg]"
cp "$root/scripts/build-codex.sh" "$esrc/scripts/build-codex.sh"
esed '/^    KIMI_K3: {"low"/d' "$esrc/scripts/build-codex.sh"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "the unassigned allowed model needs its MODEL_EFFORTS row too" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "build-codex: MODEL_EFFORTS lists"' "exit $c [$msg]"
cp "$root/scripts/build-codex.sh" "$esrc/scripts/build-codex.sh"
esed 's#^     {"\*": GLM}),$#     {"*": "zz/other"}),#' "$esrc/scripts/build-codex.sh"
msg=$(bash "$esrc/scripts/build-codex.sh" "$eout" 2>&1); c=$?
check "a MODEL_TABLE kind on a model outside the five fails the build and says so" '[ "$c" -eq 1 ] && printf "%s" "$msg" | grep -q "is on zz/other, which is not an allowed model"' "exit $c [$msg]"
rm -rf "$esrc" "$eout"

# a source ROSTER.md whose model-section anchors moved fails the build and names them, so the Claude
# model table is never shipped as it is
rsrc="$sandbox/rsrc"; mkdir -p "$rsrc"
git -C "$root" ls-files -z | tar -C "$root" --null -T - -cf - | tar -C "$rsrc" -xf -
rout="$sandbox/rout"
roster_anchor_fails() { # <label> <sed edit of ROSTER.md>
  sed "$2" "$root/ROSTER.md" > "$rsrc/ROSTER.md"
  if cmp -s "$rsrc/ROSTER.md" "$root/ROSTER.md"; then report "$1" false "[$2] left ROSTER.md as the source has it"; return; fi
  msg=$(bash "$rsrc/scripts/build-codex.sh" "$rout" 2>&1); c=$?
  report "$1" "$([ "$c" -eq 1 ] && printf '%s' "$msg" | grep -qF "ROSTER.md: the model section needs one '## Model tiers' heading followed by one paragraph starting 'Fable 5 is the premium tier'" && [ ! -e "$rout" ] && echo true || echo false)" "exit $c [$msg]"
}
roster_anchor_fails "a source ROSTER.md without the closing paragraph fails the build and says so" 's/^Fable 5 is the premium tier/The premium tier/'
roster_anchor_fails "a source ROSTER.md without the model heading fails the build and says so" 's/^## Model tiers$/## Models/'
# a heading at any level between the anchors fails too: the swap would drop it from the shipped ROSTER.md
sed 's/^## Model tiers$/&\n### Effort/' "$root/ROSTER.md" > "$rsrc/ROSTER.md"
if cmp -s "$rsrc/ROSTER.md" "$root/ROSTER.md"; then report "a ### heading between the model anchors fails the build and says so" false "the ### edit left ROSTER.md as the source has it"
else
  msg=$(bash "$rsrc/scripts/build-codex.sh" "$rout" 2>&1); c=$?
  report "a ### heading between the model anchors fails the build and says so" "$([ "$c" -eq 1 ] && printf '%s' "$msg" | grep -qF "ROSTER.md: a heading sits between '## Model tiers' and the paragraph starting 'Fable 5 is the premium tier'" && [ ! -e "$rout" ] && echo true || echo false)" "exit $c [$msg]"
fi
# the swap runs to the end of the closing paragraph, not its first line: a hard-wrapped tail is swapped out too
sed 's/^Fable 5 is the premium tier.*$/&\nzz-wrapped-tail pins every seat to claude-opus-5-5./' "$root/ROSTER.md" > "$rsrc/ROSTER.md"
if cmp -s "$rsrc/ROSTER.md" "$root/ROSTER.md"; then report "a hard-wrapped closing paragraph is swapped out whole" false "the wrap edit left ROSTER.md as the source has it"
else
  bash "$rsrc/scripts/build-codex.sh" "$rout" >/dev/null 2>&1; c=$?
  check "a hard-wrapped closing paragraph is swapped out whole" '[ "$c" -eq 0 ] && ! grep -q "zz-wrapped-tail" "$rout/ROSTER.md" && ! grep -q "claude-opus" "$rout/ROSTER.md"' "exit $c"
fi
cp "$root/ROSTER.md" "$rsrc/ROSTER.md"
bash "$rsrc/scripts/build-codex.sh" "$rout" >/dev/null 2>&1; c=$?
check "the same copy with ROSTER.md put back builds" '[ "$c" -eq 0 ]' "exit $c"
rm -rf "$rsrc" "$rout"
rm -rf "$sandbox/leak"; cp -R "$out" "$sandbox/leak"
edit 's/^model_reasoning_effort = .*/model_reasoning_effort = "medium"/' "$sandbox/leak/roles/code-reviewer.toml"
msg=$(bash "$build" --check "$sandbox/leak" 2>&1); c=$?
report "a built role with an effort its model rejects fails the check (zai/glm-5.3 rejects medium)" "$([ "$c" -ne 0 ] && printf '%s' "$msg" | grep -qF "effort 'medium' is not one zai/glm-5.3 accepts (low, high, max)" && echo true || echo false)" "exit $c: $msg"
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
