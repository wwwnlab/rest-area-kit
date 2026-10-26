#!/usr/bin/env bash
# rest_area_stop_hook.py の動作確認（ネットワーク・Claude Code は使わない）。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -r "$WORK"' EXIT
export CLAUDE_PROJECT_DIR="$WORK"
unset REST_AREA_HOOK_MIN_STOPS || true

run() { printf '%s' "$1" | "${PY:-python3}" "$HERE/rest_area_stop_hook.py"; echo " [exit=$?]"; }
stop() { printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":%s,"background_tasks":%s,"session_crons":[]}' "$1" "${2:-false}" "${3:-[]}"; }
fail=0
expect() { if [ "$2" = "$3" ]; then echo "OK   $1"; else echo "NG   $1: [$2] != [$3]"; fail=1; fi; }

expect "1回目・2回目は出さない" "$(run "$(stop s1)")$(run "$(stop s1)")" " [exit=0] [exit=0]"
expect "3回目で利用者にだけ一行（notify）" "$(run "$(stop s1)" | grep -c systemMessage)" "1"
expect "同じセッションでは二度と出さない" "$(run "$(stop s1)")" " [exit=0]"
expect "stop_hook_active なら出さない" "$(for i in 1 2 3; do run "$(stop s2 true)"; done | grep -c Message || true)" "0"
expect "バックグラウンドの作業中は出さない" "$(for i in 1 2 3; do run "$(stop s3 false '[{"id":"t","type":"shell","status":"running"}]')"; done | grep -c Message || true)" "0"
expect "サブエージェントでは出さない" "$(run '{"hook_event_name":"Stop","session_id":"s4","agent_id":"a"}')" " [exit=0]"
expect "壊れた入力でも exit 0・出力なし" "$(run 'not json')" " [exit=0]"
expect "不正なセッションIDでは状態を作らない" "$(run '{"hook_event_name":"Stop","session_id":"../../x"}')$(ls "$WORK/.claude/rest-area-hook" | grep -c '\.\.' || true)" " [exit=0]0"
for bad in abc -1 0 999 3.5; do
  sid="bad_$(printf '%s' "$bad" | tr -c 'a-z0-9' '_')"
  o="$(export REST_AREA_HOOK_MIN_STOPS="$bad"; for i in 1 2 3; do run "$(stop "$sid")" 2>&1; done)"
  expect "不正な MIN_STOPS（${bad}）でも例外なし・既定の3回目で表示" "$(printf '%s' "$o" | grep -c -E 'Traceback|Error' || true)$(printf '%s' "$o" | grep -c systemMessage)" "01"
done
d="$WORK/.claude/rest-area-hook"
touch -t 202001010000 "$d/s1.done" "$d/s1.count"
run "$(stop s1)" >/dev/null
expect "表示済みのセッションは、応答のたびに印が新しくなり掃除されない" "$([ -d "$d/s1.done" ] && [ "$(find "$d/s1.done" -mmin -1 | wc -l | tr -d ' ')" = 1 ] && echo kept)" "kept"
touch -t 202001010000 "$d/s2.count"; mkdir -p "$d/old.done"; touch -t 202001010000 "$d/old.done"
run "$(stop s7)" >/dev/null
expect "7日以上使われていない状態は掃除する" "$([ -e "$d/s2.count" ] || [ -e "$d/old.done" ] && echo left || echo pruned)" "pruned"
export REST_AREA_HOOK_MODE=suggest  # 以前の試作の設定が残っていても、notify 以外の出力をしない
out="$(for i in 1 2 3; do run "$(stop s5)"; done)"
expect "Claude への補足・block を出さない（モードの設定は無視）" "$(printf '%s' "$out" | grep -c -E 'additionalContext|"decision"|hookSpecificOutput' || true)$(printf '%s' "$out" | grep -c systemMessage)" "01"
unset REST_AREA_HOOK_MODE
expect "出力は1つの JSON（余計な文字なし）" "$(rm -r "$WORK/.claude"; for i in 1 2; do printf '%s' "$(stop s6)" | "${PY:-python3}" "$HERE/rest_area_stop_hook.py"; done; printf '%s' "$(stop s6)" | "${PY:-python3}" "$HERE/rest_area_stop_hook.py" | python3 -c 'import json,sys; json.load(sys.stdin); print("json")')" "json"
expect "ネットワークの呼び出しがない" "$(grep -c -E 'urllib|http\.client|socket|requests|subprocess' "$HERE/rest_area_stop_hook.py" || true)" "0"
expect "会話の記録を読まない" "$(grep -c -E 'transcript_path|last_assistant_message' "$HERE/rest_area_stop_hook.py" | tr -d ' ')" "1"
[ "$fail" = 0 ] && echo "すべて OK" || { echo "NG あり"; exit 1; }
