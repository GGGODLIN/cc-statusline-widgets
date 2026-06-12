#!/usr/bin/env bash
# preview-themes.sh — render wrapper.sh with synthetic stdin across all themes.
# Run directly in your terminal (colors + Nerd Font glyphs render there):
#   bash scripts/preview-themes.sh
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WRAPPER="$REPO/scripts/wrapper.sh"

transcript=$(ls -t "$HOME/.claude/projects"/*/*.jsonl 2>/dev/null | head -1 || true)

mk_input() {
  jq -n --arg t "${transcript:-}" --arg cwd "$REPO" '{
    model: {display_name: "Fable 5"},
    transcript_path: $t,
    session_id: "theme-preview",
    workspace: {current_dir: $cwd},
    cost: {total_cost_usd: 1.23},
    context_window: {
      used_percentage: 62,
      context_window_size: 200000,
      current_usage: {
        input_tokens: 4000,
        cache_creation_input_tokens: 20000,
        cache_read_input_tokens: 100000
      }
    }
  }'
}

run() {  # $1=conf-content $2=cols
  local conf
  conf=$(mktemp)
  printf '%s\n' "$1" > "$conf"
  mk_input | CC_WIDGETS_CONF="$conf" WT_NO_LOG=1 WT_FORCE_COLS="${2:-220}" bash "$WRAPPER"
  rm -f "$conf"
}

for theme in claude-coral catppuccin-mocha nord gruvbox-dark tokyo-night mono; do
  printf '\n\033[1m── %s (pill / fixed)\033[0m\n' "$theme"
  run "WT_THEME=$theme" 220
done

printf '\n\033[1m── claude-coral (lean style)\033[0m\n'
run $'WT_THEME=claude-coral\nWT_STYLE=lean' 220

for w in 200 120 80; do
  printf '\n\033[1m── claude-coral (auto wrap @ width %s)\033[0m\n' "$w"
  run $'WT_THEME=claude-coral\nWT_LAYOUT=auto\nWT_MAX_LINES=4' "$w"
done

printf '\n選好之後把設定寫進 ~/.claude/cc-widgets-theme.conf（範例見 themes/cc-widgets-theme.conf.example），再跑 scripts/install.sh 部署。\n'
