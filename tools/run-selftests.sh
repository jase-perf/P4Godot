#!/bin/sh
# Run the checks that need no Perforce server, against a clean install: the
# addon is unpacked from `git archive HEAD` - the same files a release zip
# ships - into a throwaway Godot project. CI runs this; so can you.
#
#   tools/run-selftests.sh [path-to-godot]      (or set GODOT)
#
# On Windows pass the ..._console.exe build; the GUI binary prints nothing.
# Needs `p4` on PATH (exec-quoting runs `p4 -V`). Tests the committed HEAD,
# not uncommitted edits.
cd "$(dirname "$0")/.." || exit 1

GODOT="${1:-${GODOT:-godot}}"
TESTS="parse-ztag sync-report submit-verdict p4-answers save-guards prewrite unchanged-save exec-quoting
diff-align dismiss-dialog build-change-spec fs-menu fstat-summary delete-action
connection-store connection-dialogs progress streamed-exec breaker"

if ! "$GODOT" --version >/dev/null 2>&1; then
	echo "FAIL: can't run Godot at '$GODOT'. Pass its path as the first argument."
	exit 1
fi
if ! p4 -V >/dev/null 2>&1; then
	echo "FAIL: 'p4' isn't on PATH."
	exit 1
fi

work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT
# Godot on Windows wants C:/..., not Git Bash's /tmp/...
if command -v cygpath >/dev/null 2>&1; then work="$(cygpath -m "$work")"; fi
proj="$work/proj"
mkdir -p "$proj" "$work/logs" "$work/config" "$work/data" "$work/cache"

# Keep Godot's editor settings and user:// data out of the real ones, so a
# local run starts as clean as CI does and leaves nothing behind - the
# connection-store test otherwise adds a section for the throwaway project to
# your real connections.cfg. Godot on Windows reads APPDATA and ignores XDG_*
# (measured on 4.7); the XDG_* variables are for Linux and are not yet tested.
export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/data" XDG_CACHE_HOME="$work/cache"
if [ -n "$APPDATA" ] && command -v cygpath >/dev/null 2>&1; then
	APPDATA="$(cygpath -w "$work/config")"
	LOCALAPPDATA="$(cygpath -w "$work/cache")"
	export APPDATA LOCALAPPDATA
fi
# No test here may depend on a server. Pointing p4 at a closed local port
# makes any that does fail quickly instead of passing on a developer's machine.
export P4PORT="127.0.0.1:1"

git archive --format=tar HEAD | tar -x -C "$proj" || exit 1

# The archive is what the Asset Store and the release zip ship. Anything
# beyond the addon folder means .gitattributes stopped stripping it.
stray="$(cd "$proj" && find . -type f ! -path './addons/p4godot/*')"
if [ -n "$stray" ] || [ ! -f "$proj/addons/p4godot/plugin.cfg" ]; then
	echo "FAIL: archive should hold addons/p4godot/ and nothing else. Extra:"
	echo "$stray"
	exit 1
fi
echo "ok: archive holds only addons/p4godot/ ($(find "$proj" -type f | wc -l | tr -d ' ') files)"

# Godot skips warnings under res://addons unless asked, and people do ask.
cat > "$proj/project.godot" <<'EOF'
config_version=5

[application]

config/name="p4godot-selftest"

[debug]

gdscript/warnings/directory_rules={"res://addons": 1}
gdscript/warnings/unused_variable=2
gdscript/warnings/shadowed_variable=2
gdscript/warnings/integer_division=2
gdscript/warnings/unreachable_code=2

[editor_plugins]

enabled=PackedStringArray("res://addons/p4godot/plugin.cfg")
EOF

# `timeout` isn't on a stock macOS; a hung run there has to be stopped by hand.
run() {
	secs="$1"; shift
	if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

failed=""

run 180 "$GODOT" --headless --path "$proj" --check-only \
		--script res://addons/p4godot/p4godot.gd > "$work/logs/check.log" 2>&1
code=$?
if [ "$code" -ne 0 ] || grep -q "SCRIPT ERROR" "$work/logs/check.log"; then
	echo "FAIL: parse/warnings check (exit $code)"
	cat "$work/logs/check.log"
	failed="$failed check"
else
	echo "ok: parse/warnings check"
fi

for t in $TESTS; do
	log="$work/logs/$t.log"
	# The headless editor sometimes deadlocks in its first filesystem scan
	# before plugins load. That run prints no [selftest] line at all, and the
	# cure is to wait and go again. A run that does print one is final.
	for attempt in 1 2 3 4; do
		run 120 "$GODOT" --headless --editor --path "$proj" -- "--p4-selftest-$t" > "$log" 2>&1
		if grep -q "\[selftest\]" "$log"; then break; fi
		sleep 8
	done
	# [[:space:]]* because Godot's lines end in CRLF on Windows.
	if grep -q "\[selftest\] PASS: $t[[:space:]]*\$" "$log" && ! grep -q "\[selftest\] FAIL" "$log"; then
		echo "ok: $t"
	else
		echo "FAIL: $t (attempt $attempt)"
		cat "$log"
		failed="$failed $t"
	fi
done

if [ -n "$failed" ]; then
	echo
	echo "FAILED:$failed"
	exit 1
fi
echo
echo "All checks passed."
