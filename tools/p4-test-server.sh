#!/bin/sh
# A throwaway Perforce server on this machine, for tests that need a real one.
#
#   tools/p4-test-server.sh fetch            download the pinned p4d into .cache/
#   tools/p4-test-server.sh start <dir>      create and start a server in <dir>
#   tools/p4-test-server.sh stop <dir>       stop it (the files stay; delete <dir>)
#   tools/p4-test-server.sh trigger <dir> <type> <seconds>
#                                            make every submit wait at that
#                                            trigger type, e.g. change-content
#   tools/p4-test-server.sh untrigger <dir>  remove that wait again
#
# `start` leaves <dir>/env.sh. Source it and `p4` talks to the new server as
# "dev", an ordinary user with write access and nothing more - the access a
# P4Godot user has. The plugin must never need more, so tests run as dev.
#
#   admin   super user; only this script uses it
#   dev     ordinary user, workspace dev-ws at <dir>/ws/dev on stream //game/main
#   mate    a second ordinary user, workspace mate-ws at <dir>/ws/mate
#
# Each user's password is Pw7-<user>-Secret. The server listens on 127.0.0.1
# only and holds nothing but test data.
#
# Needs `p4` on PATH and, for `fetch`, curl and sha256sum (or shasum).
# Tested on Windows (Git Bash); CI also runs it on Linux. Not yet run on macOS.
set -u
CALLER="$(pwd)"
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"

RELEASE="r26.1"
BASE="https://ftp.perforce.com/perforce/$RELEASE"
# Not ".p4config": a file of that name in any folder above the test folder
# would override the settings below, environment variables included, and
# point these commands at a real server.
CONFIG_NAME=".p4config-p4godot-test"

case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*)
		PLATFORM="windows-x86_64"; URL_PATH="bin.ntx64/p4d.exe"; EXE="p4d.exe" ;;
	Darwin)
		if [ "$(uname -m)" = "arm64" ]; then
			PLATFORM="macos-arm64"; URL_PATH="bin.macosx12arm64/p4d"
		else
			PLATFORM="macos-x86_64"; URL_PATH="bin.macosx1015x86_64/p4d"
		fi
		EXE="p4d" ;;
	*)
		PLATFORM="linux-x86_64"; URL_PATH="bin.linux26x86_64/p4d"; EXE="p4d" ;;
esac
P4D="$REPO/.cache/p4d/$RELEASE/$PLATFORM/$EXE"

root=""
port=""
launched=""

pid_alive() {
	if command -v tasklist >/dev/null 2>&1; then
		tasklist //FI "PID eq $1" 2>/dev/null | grep -q " $1 "
	else
		kill -0 "$1" 2>/dev/null
	fi
}

kill_daemon() {
	pid="$(cat "$root/p4d.pid" 2>/dev/null)"
	[ -n "$pid" ] || return 0
	waited=0
	while pid_alive "$pid" && [ "$waited" -lt "${1:-0}" ]; do
		sleep 0.1
		waited=$((waited + 1))
	done
	if pid_alive "$pid"; then
		if command -v taskkill >/dev/null 2>&1; then taskkill //F //PID "$pid" >/dev/null 2>&1
		else kill -9 "$pid" 2>/dev/null; fi
	fi
}

die() {
	echo "p4-test-server: $*" >&2
	# A failed or interrupted `start` must not leave its p4d running.
	[ -n "$launched" ] && kill_daemon 0
	exit 1
}

# p4 and p4d on Windows want C:/..., not Git Bash's /c/...
native() {
	if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# <dir> as the caller meant it (this script has changed directory since),
# with symlinks resolved: macOS temp folders sit behind /var -> /private/var,
# and p4 compares the workspace root with the real path.
as_given() {
	case "$1" in
		/*|?:*) echo "$1" ;;
		*) echo "$CALLER/$1" ;;
	esac
}

resolve_dir() {
	real="$(cd "$(as_given "$1")" 2>/dev/null && pwd -P)"
	[ -n "$real" ] || return 1
	native "$real"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() {
	# A copy already here was checked when it was downloaded (it is only
	# moved into place after that).
	if [ -x "$P4D" ]; then return 0; fi
	mkdir -p "$(dirname "$P4D")" || die "can't create $(dirname "$P4D")"
	echo "fetch $BASE/$URL_PATH" >&2
	curl -fsSL -o "$P4D.part" "$BASE/$URL_PATH" || die "download failed"
	# Checked against the SHA256SUMS Perforce publishes beside each binary,
	# not a hash pinned here: Perforce rebuilds a release in place for each
	# patch (r26.1's p4d changed on 2026-10-07), which broke a pinned hash.
	sums="$(curl -fsSL "$BASE/$(dirname "$URL_PATH")/SHA256SUMS")" || die "can't download SHA256SUMS"
	want="$(printf '%s\n' "$sums" | tr -d '\r' | awk -v f="$(basename "$URL_PATH")" '$2 == f || $2 == "*" f { print $1 }')"
	got="$(sha256_of "$P4D.part")"
	if [ -z "$want" ] || [ "$got" != "$want" ]; then
		rm -f "$P4D.part"
		die "checksum mismatch for $URL_PATH: Perforce's SHA256SUMS says '$want', got $got"
	fi
	chmod +x "$P4D.part" && mv "$P4D.part" "$P4D" || die "can't install $P4D"
}

password() { echo "Pw7-$1-Secret"; }

# Keep p4 away from the developer's own tickets, trust file and settings.
# P4CHARSET and P4IGNORE are set, not unset: on Windows an unset variable
# falls back to the registry (`p4 set`).
isolate() {
	export P4TICKETS="$root/tickets" P4TRUST="$root/trust" P4ENVIRO="$root/enviro"
	export P4CONFIG="$CONFIG_NAME" P4CHARSET=none P4IGNORE=.p4ignore
	unset P4PASSWD
}

# `p4` as the named user on this server. Server and user go on the command
# line, where nothing can override them.
as() {
	who="$1"; shift
	p4 -p "$port" -u "$who" -c "$who-ws" "$@"
}

ok() {
	out="$("$@" 2>&1)" || die "'$*' failed: $out"
}

add_user() {
	user="$1"
	printf 'User:\t%s\nEmail:\t%s@test\nFullName:\t%s\n' "$user" "$user" "$user" \
		| as admin user -f -i >/dev/null || die "can't create user $user"
	printf '%s\n%s\n' "$(password "$user")" "$(password "$user")" \
		| as admin passwd "$user" >/dev/null || die "can't set $user's password"
	password "$user" | as "$user" login >/dev/null || die "can't log in as $user"
	mkdir -p "$root/ws/$user"
	# noallwrite + noclobber is what a new P4V workspace gets.
	printf 'Client:\t%s-ws\nOwner:\t%s\nRoot:\t%s\nOptions:\tnoallwrite noclobber nocompress unlocked nomodtime normdir\nSubmitOptions:\tsubmitunchanged\nLineEnd:\tlocal\nStream:\t//game/main\n' \
		"$user" "$user" "$root/ws/$user" | as "$user" client -i >/dev/null \
		|| die "can't create $user's workspace"
	printf 'P4PORT=%s\nP4USER=%s\nP4CLIENT=%s-ws\n' "$port" "$user" "$user" \
		> "$root/ws/$user/$CONFIG_NAME"
}

start() {
	[ -n "${1:-}" ] || die "usage: start <dir>"
	command -v p4 >/dev/null 2>&1 || die "'p4' isn't on PATH"
	fetch
	mkdir -p "$(as_given "$1")" || die "can't create $1"
	root="$(resolve_dir "$1")" || die "can't open $1"
	[ ! -e "$root/db" ] || die "$root already holds a server; stop it and delete the folder"
	mkdir -p "$root/db" "$root/ws"
	isolate
	trap 'die "interrupted"' INT TERM HUP

	ok "$P4D" -r "$root/db" -xu
	# A password an admin sets is otherwise born expired on a 2026.1 server.
	ok "$P4D" -r "$root/db" "-cset dm.user.resetpassword=0"

	# Any port can be taken or reserved (Hyper-V and Docker reserve ranges on
	# Windows), so try a few. p4d exits at once when it can't listen. An
	# answer on the port isn't enough - another server may be listening
	# there - so our own p4d must also still be running. (A new server
	# doesn't reveal its root folder to a user who hasn't logged in, so that
	# can't be compared.)
	seed=$$
	tries=0
	while [ -z "$port" ] && [ "$tries" -lt 10 ]; do
		tries=$((tries + 1))
		try="127.0.0.1:$((20000 + (seed * 7 + tries * 613) % 20000))"
		rm -f "$root/p4d.pid"
		launched=1
		"$P4D" -r "$root/db" -L "$root/db/log" -p "$try" "--pid-file=$root/p4d.pid" \
			> "$root/daemon.out" 2>&1 < /dev/null &
		waited=0
		while [ "$waited" -lt 150 ]; do
			if grep -q "failed" "$root/daemon.out" 2>/dev/null; then break; fi
			if p4 -p "$try" -u admin info >/dev/null 2>&1 && [ -s "$root/p4d.pid" ]; then
				# Give a p4d that lost the port to someone else time to say so.
				sleep 0.5
				if pid_alive "$(cat "$root/p4d.pid")" \
						&& ! grep -q "failed" "$root/daemon.out" 2>/dev/null; then
					port="$try"
				fi
				break
			fi
			sleep 0.2
			waited=$((waited + 1))
		done
		[ -n "$port" ] || kill_daemon 0
	done
	[ -n "$port" ] || die "p4d didn't start: $(cat "$root/daemon.out")"

	# The first user to set a password becomes the super user.
	printf '%s\n%s\n' "$(password admin)" "$(password admin)" | as admin passwd >/dev/null \
		|| die "can't set admin's password"
	password admin | as admin login >/dev/null || die "can't log in as admin"
	printf 'Protections:\n\twrite user * * //...\n\tsuper user admin * //...\n' \
		| as admin protect -i >/dev/null || die "can't write the protections table"
	as admin depot -o -t stream game | as admin depot -i >/dev/null || die "can't create depot game"
	as admin stream -o -t mainline //game/main | as admin stream -i >/dev/null \
		|| die "can't create stream //game/main"

	add_user dev
	add_user mate

	cat > "$root/env.sh" <<EOF
# Source this: p4 then talks to the throwaway server in $root as "dev".
export P4PORT="$port" P4USER=dev P4CLIENT=dev-ws
export P4TICKETS="$root/tickets" P4TRUST="$root/trust" P4ENVIRO="$root/enviro"
export P4CONFIG="$CONFIG_NAME" P4CHARSET=none P4IGNORE=.p4ignore
unset P4PASSWD
export P4TEST_ROOT="$root" P4TEST_WS="$root/ws/dev" P4TEST_MATE_WS="$root/ws/mate"
EOF
	echo "$port" > "$root/port"
	launched=""
	trap - INT TERM HUP
	echo "started $port in $root (source $root/env.sh)"
}

load() {
	[ -n "${1:-}" ] || die "name the test server's folder"
	root="$(resolve_dir "$1")" || { root=""; die "no test server in '$1'"; }
	[ -f "$root/port" ] || die "no test server in '$1'"
	port="$(cat "$root/port")"
	isolate
}

stop() {
	load "${1:-}"
	as admin admin stop >/dev/null 2>&1
	# p4d writes its last journal records after it stops answering; deleting
	# the folder before the process ends races with those writes.
	kill_daemon 100
	echo "stopped $port"
}

# Every submit then waits <seconds> at the named trigger type. change-content
# fires after the files are sent and before the changelist is committed -
# the window a slow virus scan or review check opens on a real server.
trigger() {
	load "${1:-}"
	[ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: trigger <dir> <type> <seconds>"
	sleeper="$(native "$(command -v sleep)")"
	printf 'Triggers:\n\tsleep %s //... "%s %s"\n' "$2" "$sleeper" "$3" \
		| as admin triggers -i >/dev/null || die "can't install the trigger"
	echo "every submit now waits $3 s at $2"
}

untrigger() {
	load "${1:-}"
	printf 'Triggers:\n' | as admin triggers -i >/dev/null || die "can't clear the triggers"
	echo "triggers cleared"
}

case "${1:-}" in
	fetch) fetch && echo "$P4D" ;;
	start) start "${2:-}" ;;
	stop) stop "${2:-}" ;;
	trigger) trigger "${2:-}" "${3:-}" "${4:-}" ;;
	untrigger) untrigger "${2:-}" ;;
	*) die "usage: $0 fetch | start <dir> | stop <dir> | trigger <dir> <type> <seconds> | untrigger <dir>" ;;
esac
