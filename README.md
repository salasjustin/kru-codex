<picture>
  <source media="(prefers-color-scheme: dark)" srcset="brand/kru-header-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="brand/kru-header-light.svg">
  <img alt="kru" src="brand/kru-header-light.svg">
</picture>

*(said “crew”)*

**kru for Codex.** Your engineering department, as a Codex plugin: kru's skills, its specialist seats as agent roles, and its hooks, built for Codex and the models you run it on.

This repo tracks [kru](https://github.com/ap-justin/kru), the Claude Code plugin, as its `upstream` remote. Nothing is ported by hand: `scripts/build-codex.sh` generates the Codex plugin from kru's own files, so a merge from upstream plus a rebuild brings in every new skill and seat.

## Install

You need bash, Python 3.11 or later, and `jq` (the hooks use it at run time).

```bash
git clone https://github.com/salasjustin/kru-codex && cd kru-codex
bash scripts/build-codex.sh --install ~/.codex
```

The install puts the plugin under `~/.codex/plugins/cache/kru/kru/local` and the seat roles under `~/.codex/agents`. It leaves `config.toml` alone and prints the two lines that turn the plugin on:

```toml
[plugins."kru@kru"]
enabled = true
```

Then approve kru's hooks in Codex. The approval is tied to the plugin's files, so approve them again after every install that changed the build; until you do, Codex skips them.

### In a Sky environment

To give another repo's Sky runs kru in Codex, put this `refresh` in that environment's `env.yaml`. Sky runs it before every run: the first run clones kru-codex (public) into `$HOME/.sky/kru-codex`, every run fast-forwards it, and each installs into the run's Codex home, `$HOME/.sky/codex`:

```yaml
refresh: |
  [ -d "$HOME/.sky/kru-codex/.git" ] || git clone https://github.com/salasjustin/kru-codex "$HOME/.sky/kru-codex"
  git -C "$HOME/.sky/kru-codex" pull --ff-only
  bash "$HOME/.sky/kru-codex/scripts/build-codex.sh" --install "$HOME/.sky/codex"
```

Then turn it on with the secret `SKY_CODEX_PLUGINS=kru@kru`: `sky secret set <env> SKY_CODEX_PLUGINS`.

For an environment that already exists, set the refresh without reprovisioning it (save the script as `refresh.sh`):

```bash
sky env set-refresh <env> @refresh.sh
```

A `refresh` change never rebuilds the environment and is allowed while agents exist, so this is the way to install kru-codex in a busy environment. A `setup` change is refused there with `agents_exist`. No `setup` line is needed: the refresh does the first install and every update, so a merge to kru-codex (and, through the hourly sync, every kru release) reaches the next run.

The refresh has 120 seconds by default. If the plugin is not installed afterwards, the run posts a `runner.warning` and goes on without kru. Sky's README has the rest: [*Per-run refresh*](https://github.com/salasjustin/sky#per-run-refresh) and the Plugins bullet under [*Codex runs*](https://github.com/salasjustin/sky#codex-runs).

The image needs bash, Python 3.11 or later (the build reads TOML with `tomllib`), `git`, and `jq` for the hooks at run time.

Other commands:

```bash
bash scripts/build-codex.sh /tmp/kru-codex           # build the plugin tree without installing
bash scripts/build-codex.sh --check /tmp/kru-codex   # the checks verify runs on a build
bash scripts/verify.sh                               # every check, the Codex build included
```

## What you get

- **119 skills**, called as `$kru:<name>`. Start with `$kru:lead`, which scopes the work and routes it to the right seat. The 32 skills kru keeps manual-only run only when you call them by name.
- **41 seats** as Codex agent roles, which the lead starts with `spawn_agent`. Seats that only review run in a read-only sandbox.
- **kru's hooks**: the lead gate, the handoff check, the brainstorm lock, the dispatch log and the store sync, run through one adapter (`hooks/codex-adapter.sh`) so the rules stay the same as in kru.

## Models

Every seat runs on one of five allowed models routed through AI Gateway, never a Claude model and never any other. `MODEL_TABLE` in `scripts/build-codex.sh` is the assignment source: four seat kinds, each on one model, and a new seat from upstream fails the build until it has a place in the table. `moonshotai/kimi-k3` is allowed and takes no seat.

| group | seats | model | price, USD per 1M in / out | efforts accepted |
|---|---|---|---|---|
| Deep engineering and UI builders | 30: auth, payments, accounting, data, platform and long-horizon builders, plus `react-ui-builder`, `svelte-ui-builder`, `hono-ui-builder`, `web-components-builder`, `extension-builder`, `motion-designer` | `deepseek/deepseek-v4.1-flash` | `$0.30` / `$1.20` | `none low high max` |
| Test writer and code reviewer | 2: `code-reviewer`, `test-writer` | `zai/glm-5.3` | `$1.40` / `$4.40` | `low high max` |
| Planning and architecture review | 2: `planner`, `architecture-reviewer` | `moonshotai/kimi-k3.1-pro` | `$2.00` / `$10.00` | `low high max` |
| Visual review and lighter repeated work | 7: `conversion-copywriter`, `ux-auditor`, `visual-reviewer`, `accessibility-reviewer`, `dispatch-auditor`, `toolchain-engineer`, `vercel-perf-optimizer` | `zai/glm-5.3-flash` | `$0.15` / `$0.50` | `low high max` |

A seat's `effort:` carries over as `model_reasoning_effort`. No allowed model accepts `medium`, so where a model does not take the pin the build rounds it up to the nearest value it does take (`medium` becomes `high`) and prints a line naming the seat, the pin, the value used and the set. A pin that is not a `ReasoningEffort` value, or one with nothing accepted at or above it, fails the build. Prices and supported efforts are from the Gateway catalog as of Nov 27, 2026. The choice and its evidence: `codex/PORTING.md` → *Models*.

## What is missing

- `$kru:reflect` and `$kru:text-fix` start a nested Claude Code session, so in Codex they say they need one and stop.
- A seat's tool list does not carry over; the review seats get a read-only sandbox instead.
- Hook messages still name Claude Code's tools (`Read`, `Grep`) and `/kru:` commands.
- kru's plugin settings screen has no counterpart: export the same `KRU_*` variables instead.
- The build has not yet run in a live Codex session.

## Keeping up with kru

An hourly workflow (`.github/workflows/sync-upstream.yml`) does this for you. It fetches kru's `main` and, if there is anything new, merges it, runs `scripts/verify.sh`, and pushes the merge to `main`. When the merge conflicts or verify fails, it pushes nothing, opens an issue titled `Upstream sync blocked` (or comments on the open one) with the upstream sha, the failed step and the last 80 lines of its output, and fails the run. The next successful sync closes that issue. To sync at once, run *sync-upstream* from the Actions tab.

To do it by hand:

```bash
git fetch upstream && git merge upstream/main
bash scripts/verify.sh && bash scripts/build-codex.sh --install ~/.codex
```

This README is the one file that differs from kru's. `.gitattributes` keeps it on merges; turn that on once per clone with `git config merge.ours.driver true`. Everything Codex-specific lives in `codex/`, `scripts/build-codex*.sh` and `hooks/codex-adapter*`, which upstream never touches.

`codex/PORTING.md` has the full layout, every rewrite rule, the hook mapping and the Codex source line behind each.

## License

Same as kru: see `LICENSE` and `NOTICE`.
