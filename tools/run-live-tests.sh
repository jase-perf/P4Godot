#!/bin/sh
# Run the checks that need a real Perforce server, against a throwaway one
# started on this machine (tools/p4-test-server.sh). Every test runs as "dev",
# an ordinary user with write access and nothing more.
#
#   tools/run-live-tests.sh [path-to-godot] [test ...]      (or set GODOT)
#
# With no test names it runs them all. Tests the working tree, uncommitted
# edits included. On Windows pass the ..._console.exe build of Godot.
# KEEP=1 leaves the server's folder behind (stopped) and prints where it is.
#
# Only run on Windows so far. Known gaps elsewhere: macOS has no `timeout`, so
# a hung editor has to be stopped by hand, and Godot on macOS keeps its editor
# settings under ~/Library, which this script does not redirect.
cd "$(dirname "$0")/.." || exit 1

GODOT="${1:-${GODOT:-godot}}"
[ $# -gt 0 ] && shift
ALL="probe ignore-check-live file-actions-live moves-live password-expired-live create-changelist submit-roundtrip
special-names submit-behind-live resolve-live submit-verdict-live submit-cancel submit-slow-trigger-live
external-scan"
TESTS="${*:-$ALL}"

if ! "$GODOT" --version >/dev/null 2>&1; then
	echo "FAIL: can't run Godot at '$GODOT'. Pass its path as the first argument."
	exit 1
fi

work="$(mktemp -d)" || exit 1
if command -v cygpath >/dev/null 2>&1; then work="$(cygpath -m "$work")"; fi
srv="$work/srv"
cleanup() {
	sh tools/p4-test-server.sh stop "$srv" >/dev/null 2>&1
	if [ -n "${KEEP:-}" ]; then echo "kept $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT
# Not every sh runs the EXIT trap when a signal ends it.
trap 'exit 130' INT TERM HUP

sh tools/p4-test-server.sh start "$srv" || exit 1
. "$srv/env.sh"
proj="$P4TEST_WS"
# Server, user and workspace on the command line, where no stray settings
# file can override them.
p4t() { p4 -p "$P4PORT" -u "$P4USER" -c "$P4CLIENT" "$@"; }
mkdir -p "$work/logs" "$work/config" "$work/cache"

# Godot's editor settings and user:// data stay out of the real ones.
export XDG_CONFIG_HOME="$work/config" XDG_DATA_HOME="$work/config" XDG_CACHE_HOME="$work/cache"
if [ -n "$APPDATA" ] && command -v cygpath >/dev/null 2>&1; then
	APPDATA="$(cygpath -w "$work/config")"
	LOCALAPPDATA="$(cygpath -w "$work/cache")"
	export APPDATA LOCALAPPDATA
fi

# A small project, submitted by dev the way a team's first check-in would be.
cp -r addons "$proj"/ || exit 1
cat > "$proj/project.godot" <<'EOF'
config_version=5

[application]

config/name="p4godot-livetest"

[editor_plugins]

enabled=PackedStringArray("res://addons/p4godot/plugin.cfg")
EOF
printf '.godot/\n*.log\n%s\n' "$P4CONFIG" > "$proj/.p4ignore"
printf 'extends Node\n' > "$proj/main.gd"
(
	cd "$proj" || exit 1
	p4t add .p4ignore project.godot main.gd >/dev/null &&
		p4t reconcile -a addons/... >/dev/null &&
		p4t submit -d "First check-in of the test project" >/dev/null
) || { echo "FAIL: couldn't submit the test project"; exit 1; }
echo "ok: test project submitted to $P4PORT as $P4USER ($(cd "$proj" && p4t -F %depotFile% files ./... | wc -l | tr -d ' ') files)"

run() {
	secs="$1"; shift
	if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

failed=""
for t in $TESTS; do
	log="$work/logs/$t.log"
	arg="--p4-selftest-$t"
	case "$t" in
		password-expired-live)
			# Only an admin can expire a password; the test itself stays dev.
			p4 -p "$P4PORT" -u admin admin resetpassword -u dev >/dev/null || { echo "FAIL: $t (resetpassword)"; failed="$failed $t"; continue; }
			arg="$arg=Pw7-dev-Secret,Pw8-dev-Secret" ;;
		submit-slow-trigger-live)
			# The window a slow virus scan or review check opens on a real
			# server: files received, changelist not yet committed.
			sh tools/p4-test-server.sh trigger "$srv" change-content 8 >/dev/null || { echo "FAIL: $t (trigger)"; failed="$failed $t"; continue; }
			arg="$arg=8" ;;
	esac
	# A run that prints no [selftest] line never loaded the plugin (the
	# headless editor sometimes deadlocks in its first scan); go again.
	for attempt in 1 2 3 4; do
		run 300 "$GODOT" --headless --editor --path "$proj" -- "$arg" > "$log" 2>&1
		if grep -q "\[selftest\]" "$log"; then break; fi
		sleep 8
	done
	[ "$t" = "submit-slow-trigger-live" ] && sh tools/p4-test-server.sh untrigger "$srv" >/dev/null
	grep "\[selftest\]" "$log" | sed 's/^/    /'
	case "$t" in
		probe) want="\[selftest\] probe status=ok" ;;
		*) want="\[selftest\] PASS: $t" ;;
	esac
	# A PASS line may carry a note after the name; Godot's lines end in CRLF
	# on Windows.
	if grep -Eq "$want([[:space:]]|\$)" "$log" && ! grep -q "\[selftest\] FAIL" "$log"; then
		echo "ok: $t"
	else
		echo "FAIL: $t (attempt $attempt)"
		[ -n "${VERBOSE:-}" ] && cat "$log"
		failed="$failed $t"
	fi
	left="$(cd "$proj" && p4t -F %depotFile% opened 2>/dev/null)"
	if [ -n "$left" ]; then
		echo "FAIL: $t left files opened:"; echo "$left"
		failed="$failed $t-left-open"
		(cd "$proj" && p4t revert ./... >/dev/null 2>&1)
	fi
done

if [ -n "$failed" ]; then
	echo
	echo "FAILED:$failed   (KEEP=1 VERBOSE=1 shows the logs)"
	exit 1
fi
echo
echo "All live checks passed."
