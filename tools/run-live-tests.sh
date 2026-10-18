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
ALL="probe history-gate decline-reprompt script-revert import-dock
get-latest-scene get-latest-script get-latest-modified get-latest-checked-out
ignore-check-live file-actions-live moves-live password-expired-live create-changelist submit-roundtrip
special-names history-live shelves-live submit-behind-live resolve-live submit-verdict-live submit-cancel submit-slow-trigger-live
watch-live allwrite-live allwrite-offer-live diff-limits-live plugin-prompt get-latest-cancel ssl-fingerprint-live"
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
# The project sits in a folder of the workspace, with a file beside it, as
# in a team's workspace that holds art sources next to the game. Tests that
# use the second user's workspace get its matching folder.
proj="$P4TEST_WS/game"
export P4TEST_MATE_WS="$P4TEST_MATE_WS/game"
mkdir -p "$proj" "$P4TEST_WS/art" || exit 1
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
# The self-tests run as the plugin: a script beside it that extends it.
cp tests/p4godot_test.gd "$proj/addons/p4godot/" || exit 1
sed 's/^script="p4godot.gd"$/script="p4godot_test.gd"/' "$proj/addons/p4godot/plugin.cfg" > "$work/plugin.cfg" \
	&& mv "$work/plugin.cfg" "$proj/addons/p4godot/plugin.cfg" || exit 1
# project.godot as Godot itself writes it, version tag included: a windowed
# editor rewrites a project.godot that lacks its version's tag the first time
# it opens it (measured, 4.7), and a read-only one then stops on Godot's own
# "Load Errors" dialog - as it does for a team after every Godot upgrade.
godot_features="$("$GODOT" --version 2>/dev/null | cut -d. -f1-2)"
cat > "$proj/project.godot" <<EOF
; Engine configuration file.
; It's best edited using the editor UI and not directly,
; since the parameters that go here are not all obvious.
;
; Format:
;   [section] ; section goes between []
;   param=value ; assign values to parameters

config_version=5

[application]

config/name="p4godot-livetest"
config/features=PackedStringArray("$godot_features")
EOF
# A plugin that doesn't compile can't run any test: each would only wait out
# its timeout and retries.
if command -v timeout >/dev/null 2>&1; then
	timeout 180 "$GODOT" --headless --path "$proj" --check-only \
		--script res://addons/p4godot/p4godot_test.gd > "$work/logs/check.log" 2>&1
else
	"$GODOT" --headless --path "$proj" --check-only \
		--script res://addons/p4godot/p4godot_test.gd > "$work/logs/check.log" 2>&1
fi
if grep -q "SCRIPT ERROR" "$work/logs/check.log"; then
	echo "FAIL: the plugin doesn't compile"
	grep -A1 "SCRIPT ERROR" "$work/logs/check.log"
	exit 1
fi
printf '.godot/\n*.log\n%s\n' "$P4CONFIG" > "$proj/.p4ignore"
printf '%s\n' "$P4CONFIG" > "$P4TEST_WS/.p4ignore"
printf 'extends Node\n' > "$proj/main.gd"
printf 'Art source, outside the Godot project\n' > "$P4TEST_WS/art/readme.txt"
# Files some tests work on: a scene, a script, and an image Godot imports.
mkdir -p "$proj/scenes" "$proj/scripts" "$proj/art" || exit 1
printf '[gd_scene format=3]\n\n[node name="Level" type="Node2D"]\n' > "$proj/scenes/level.tscn"
printf 'extends Node\n\n\nfunc _ready() -> void:\n\tpass\n' > "$proj/scripts/player.gd"
cp docs/images/p4-icon-dark.svg "$proj/art/icon.svg" || exit 1
# Godot's first look at a project rewrites project.godot, writes a .uid for
# each script and imports the assets; a team checks the result in. Done with
# the plugin still off, so it doesn't act yet. Without it, every test's
# editor would fail to write the read-only project.godot at startup and stop
# on Godot's "Load Errors" dialog.
run_import() {
	if command -v timeout >/dev/null 2>&1; then timeout 300 "$@"; else "$@"; fi
}
run_import "$GODOT" --headless --editor --import --path "$proj" > "$work/logs/import.log" 2>&1
[ -f "$proj/art/icon.svg.import" ] || { echo "FAIL: Godot didn't import the test project"; exit 1; }
printf '\n[editor_plugins]\n\nenabled=PackedStringArray("res://addons/p4godot/plugin.cfg")\n' >> "$proj/project.godot"
(
	cd "$proj" || exit 1
	# project.godot always writable, as docs/first-time-setup.md recommends:
	# Godot writes it at every windowed start.
	p4t add -t text+w project.godot >/dev/null &&
		p4t add ../.p4ignore ../art/readme.txt >/dev/null &&
		p4t reconcile -a ./... >/dev/null &&
		p4t submit -d "First check-in of the test project" >/dev/null
) || { echo "FAIL: couldn't submit the test project"; exit 1; }
echo "ok: test project submitted to $P4PORT as $P4USER ($(cd "$proj" && p4t -F %depotFile% files ./... | wc -l | tr -d ' ') files)"

# A second p4d on an SSL port, trusted once and then given a new
# certificate - what an admin replacing the certificate (or something
# intercepting the connection) looks like to a client. Prints the port.
stage_ssl_change() {
	p4d_bin="$(sh tools/p4-test-server.sh fetch)" || return 1
	sslroot="$work/ssl"
	mkdir -p "$sslroot/db" "$sslroot/keys"
	export P4SSLDIR="$sslroot/keys"
	"$p4d_bin" -Gc >/dev/null 2>&1 || return 1
	sslport="ssl:127.0.0.1:$((30000 + $$ % 9000))"
	"$p4d_bin" -r "$sslroot/db" -p "$sslport" > "$sslroot/out" 2>&1 < /dev/null &
	sslpid=$!
	sleep 2
	p4 -p "$sslport" trust -y >/dev/null 2>&1 || return 1
	kill "$sslpid" 2>/dev/null; wait "$sslpid" 2>/dev/null
	rm -f "$sslroot/keys/"*
	"$p4d_bin" -Gc >/dev/null 2>&1 || return 1
	"$p4d_bin" -r "$sslroot/db" -p "$sslport" > "$sslroot/out" 2>&1 < /dev/null &
	sslpid=$!
	sleep 2
	unset P4SSLDIR
	echo "$sslport"
}

# The second user, for staging a teammate's work.
mate() { p4 -p "$P4PORT" -u mate -c mate-ws "$@"; }

# A teammate submits a newer revision of $1 (relative to the project), so
# dev's copy is behind. $2 is the text appended.
stage_behind() {
	mate sync -q "//mate-ws/..." >/dev/null 2>&1
	mate edit "$P4TEST_MATE_WS/$1" >/dev/null 2>&1 &&
		printf '%s' "$2" >> "$P4TEST_MATE_WS/$1" &&
		mate submit -d "A teammate's change to $1" "$P4TEST_MATE_WS/$1" >/dev/null 2>&1
}

run() {
	secs="$1"; shift
	if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
	status=$?
	# On Windows the console godot is a wrapper around the real editor, and
	# timeout stops only the wrapper. Stop what is left of this run's editor
	# - only processes started in this run's own folder, nothing else.
	if [ "$status" = 124 ] && command -v wmic >/dev/null 2>&1; then
		wmic process where "CommandLine like '%$(basename "$work")%' and Name like 'Godot%'" call terminate >/dev/null 2>&1
	fi
	return $status
}

# GUI=1 runs the editor in a real window, for the screenshot tests: each
# saves PNGs into $SHOTS (default: a folder that KEEP=1 leaves behind).
window="--headless"
if [ -n "${GUI:-}" ]; then
	window="--resolution 1600x900"
	SHOTS="${SHOTS:-$work/shots}"
	mkdir -p "$SHOTS"
	export P4GODOT_SHOTS="$SHOTS"
fi

failed=""
for t in $TESTS; do
	log="$work/logs/$t.log"
	arg="--p4-selftest-$t"
	case "$t" in
		password-expired-live)
			# Only an admin can expire a password; the test itself stays dev.
			p4 -p "$P4PORT" -u admin admin resetpassword -u dev >/dev/null || { echo "FAIL: $t (resetpassword)"; failed="$failed $t"; continue; }
			arg="$arg=Pw7-dev-Secret,Pw8-dev-Secret" ;;
		# Get Latest against a workspace a teammate's submit left behind: a
		# scene and a script that reload, a file changed on disk without a
		# checkout (refused), and one checked out (left for a resolve).
		get-latest-scene|get-latest-script|get-latest-modified|get-latest-checked-out)
			case "$t" in
				get-latest-scene) file="scenes/level.tscn"
					extra='
[node name="Teammate" type="Node2D" parent="."]
' ;;
				*) file="scripts/player.gd"; extra='# a teammate was here
' ;;
			esac
			stage_behind "$file" "$extra" || { echo "FAIL: $t (staging)"; failed="$failed $t"; continue; }
			case "$t" in
				get-latest-modified)
					chmod u+w "$proj/$file" && printf '# my unsubmitted change\n' >> "$proj/$file" ;;
				get-latest-checked-out)
					(cd "$proj" && p4t edit "$file" >/dev/null) ;;
			esac
			arg="--p4-selftest-get-latest=res://$file" ;;
		# A project whose project.godot is in Perforce but whose addon isn't:
		# the addon leaves the depot and stays on disk.
		plugin-prompt)
			(cd "$proj" && p4t delete -k "addons/..." >/dev/null &&
				p4t submit -d "Take the addon out of Perforce" >/dev/null) ||
				{ echo "FAIL: $t (staging)"; failed="$failed $t"; continue; } ;;
		ssl-fingerprint-live)
			sslport="$(stage_ssl_change)" || { echo "FAIL: $t (staging)"; failed="$failed $t"; continue; }
			arg="$arg=$sslport" ;;
		# A download big enough to cancel part-way: 40 files of 3 MB, submitted
		# and then synced away again.
		get-latest-cancel)
			(cd "$proj" && mkdir -p big &&
				for i in $(seq 1 40); do head -c 3000000 /dev/urandom > "big/blob$i.bin"; done &&
				p4t add -t binary big/*.bin >/dev/null &&
				p4t submit -d "Big files for the cancel test" >/dev/null &&
				p4t sync -q "big/...#none" >/dev/null) ||
				{ echo "FAIL: $t (staging)"; failed="$failed $t"; continue; } ;;
		# These leave what they checked out opened, by design; reverted below.
		history-gate|decline-reprompt) arg="$arg=res://scenes/level.tscn" ;;
		script-revert) arg="$arg=res://scripts/player.gd" ;;
		import-dock) arg="$arg=res://art/icon.svg" ;;
		submit-slow-trigger-live)
			# The window a slow virus scan or review check opens on a real
			# server: files received, changelist not yet committed.
			sh tools/p4-test-server.sh trigger "$srv" change-content 8 >/dev/null || { echo "FAIL: $t (trigger)"; failed="$failed $t"; continue; }
			arg="$arg=8" ;;
	esac
	# A run that prints no [selftest] line never loaded the plugin (the
	# headless editor sometimes deadlocks in its first scan); go again.
	for attempt in 1 2 3 4; do
		run "${TEST_TIMEOUT:-300}" "$GODOT" $window --editor --path "$proj" -- "$arg" > "$log" 2>&1
		if grep -q "\[selftest\]" "$log"; then break; fi
		sleep 8
	done
	[ "$t" = "submit-slow-trigger-live" ] && sh tools/p4-test-server.sh untrigger "$srv" >/dev/null
	grep "\[selftest\]" "$log" | sed 's/^/    /'
	case "$t" in
		probe) want="\[selftest\] probe status=ok" ;;
		get-latest-scene|get-latest-script|get-latest-modified|get-latest-checked-out) want="\[selftest\] PASS: get-latest" ;;
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
	case "$t" in
		history-gate|decline-reprompt|script-revert|import-dock)
			(cd "$proj" && p4t revert "//$P4CLIENT/..." >/dev/null 2>&1) ;;
		ssl-fingerprint-live)
			[ -n "${sslpid:-}" ] && kill "$sslpid" 2>/dev/null ;;
		plugin-prompt)
			(cd "$proj" && p4t revert "//$P4CLIENT/..." >/dev/null 2>&1; p4t reconcile -a "addons/..." >/dev/null 2>&1 &&
				p4t submit -d "Put the addon back" >/dev/null 2>&1) ;;
		get-latest-cancel)
			(cd "$proj" && p4t sync -q "big/..." >/dev/null 2>&1 && p4t delete "big/..." >/dev/null 2>&1 &&
				p4t submit -d "Remove the cancel test's files" >/dev/null 2>&1; rm -rf big) ;;
		get-latest-scene|get-latest-script|get-latest-modified|get-latest-checked-out)
			(cd "$proj" && p4t revert "//$P4CLIENT/..." >/dev/null 2>&1 && p4t sync -f "$file" >/dev/null 2>&1) ;;
	esac
	left="$(cd "$proj" && p4t -F %depotFile% opened 2>/dev/null)"
	if [ -n "$left" ]; then
		echo "FAIL: $t left files opened:"; echo "$left"
		failed="$failed $t-left-open"
		(cd "$proj" && p4t revert "//$P4CLIENT/..." >/dev/null 2>&1)
	fi
done

if [ -n "$failed" ]; then
	echo
	echo "FAILED:$failed   (KEEP=1 VERBOSE=1 shows the logs)"
	exit 1
fi
echo
echo "All live checks passed."
