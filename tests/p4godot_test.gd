@tool
extends "p4godot.gd"

## The headless self-tests. Not part of the addon: the test runners copy this
## file into addons/p4godot/ of a throwaway project and point that copy's
## plugin.cfg at it, so it runs as the plugin, with every member of the real
## one in reach. See CONTRIBUTING.md.

# ---------------------------------------------------------------------------
# CLI self-tests (headless smoke tests; harmless no-ops in normal use)
#
#   godot --headless --editor --path <project> -- --p4-selftest-<name>=res://<file>
#
# --p4-selftest-checkout / --p4-selftest-reload exercise _do_checkout()/
# _reload_path() directly. --p4-selftest-simulate-edit performs a REAL
# commit_action() - the same thing a user edit fires - to regression-test the
# signal hookup itself; combine with --p4-selftest-auto-answer=confirm|decline
# to drive the dialog's resolution path. --p4-selftest-save-checkout and
# --p4-selftest-save-rescue exercise the save-time paths: pre-write checkout
# via _apply_changes(), and the failed-save rescue dialog via scene_saved.
#
# Harness notes (verified the hard way): clear open_scenes/current_scene in
# .godot/editor/editor_layout.cfg before every headless run (restoring real
# scenes at boot hangs the headless editor), expect Main::start to auto-open
# the project's main scene when the session is empty, and expect the process
# to linger after quit() once scene tabs were opened - kill it from the
# harness after output stops; assert on the log lines, not the exit code.
# ---------------------------------------------------------------------------

func _run_cli_self_test_if_requested() -> void:
	var has_selftest_arg := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--p4-selftest-"):
			has_selftest_arg = true
		if arg.begins_with("--p4-selftest-auto-answer="):
			_selftest_auto_answer = arg.substr("--p4-selftest-auto-answer=".length())
	if not has_selftest_arg:
		return
	_selftest_mode = true
	# The focus-in / filesystem_changed scan would otherwise fire in the
	# middle of whatever a test is doing and reconcile the workspace behind
	# its back, which makes every live test's result depend on what else was
	# lying around. The external-scan test turns it back on for itself.
	if detect_external_checkbox:
		detect_external_checkbox.set_pressed_no_signal(false)
	# Identity detection is async now - resolve it before dispatching so tests
	# exercise the plugin's steady state, not its boot race.
	await _ensure_identity()

	for arg in OS.get_cmdline_user_args():
		if arg == "--p4-selftest-parse-ztag":
			# Server-independent: feed a canned tagged blob (CRLF line endings, a
			# blank-line record separator, and a multi-line desc continuation) to
			# _parse_ztag and assert the structure it recovers.
			var blob := "... action edit\r\n... change default\r\n\r\n" \
					+ "... change 123\r\n... desc first line\r\nsecond line\r\n... user bob\r\n"
			var recs := _parse_ztag({"exit_code": 0, "output": [blob]})
			_log("[selftest] ztag records: %d" % recs.size())
			var basic_ok := false
			if recs.size() == 2:
				_log("[selftest] rec0 action=%s change=%s" % [recs[0].get("action", "?"), recs[0].get("change", "?")])
				var desc_lines := String(recs[1].get("desc", "")).split("\n").size()
				_log("[selftest] rec1 change=%s desc-lines=%d" % [recs[1].get("change", "?"), desc_lines])
				basic_ok = recs[0].get("action") == "edit" and recs[0].get("change") == "default" \
						and recs[1].get("change") == "123" and desc_lines == 2
				if not basic_ok:
					_log("[selftest] FAIL: parse-ztag field mismatch")
			else:
				_log("[selftest] FAIL: parse-ztag expected 2 records")

			# A refused file, copied from what the server really prints: a bare
			# message line, then a "... " detail line whose first word is a
			# depot path, then the NEXT record with no blank line between.
			# Treating that detail line as a field used to open a bogus record
			# and swallow the following record's fields, which lost a file
			# from the reconcile preview and left a phantom "1 edit" the dock
			# could never open.
			var refused_blob := "//depot/proj/locked.tscn - can't edit exclusive file already opened\n" \
					+ "... //depot/proj/locked.tscn - also opened by bob@bob_ws\n" \
					+ "... depotFile //depot/proj/level.gd\n" \
					+ "... clientFile C:\\ws\\proj\\level.gd\n... action edit\n... type text\n\n" \
					+ "... depotFile //depot/proj/new.txt\n" \
					+ "... clientFile C:\\ws\\proj\\new.txt\n... action add\n... type text\n\n"
			var rrecs := _parse_ztag({"exit_code": 0, "output": [refused_blob]})
			var actions: Array = []
			for r in rrecs:
				actions.append(r.get("action", "<none>"))
			_log("[selftest] refusal blob -> %d record(s), actions=%s" % [rrecs.size(), actions])
			var kept_edit: bool = rrecs.size() == 2 \
					and rrecs[0].get("action", "") == "edit" \
					and rrecs[0].get("depotFile", "") == "//depot/proj/level.gd" \
					and rrecs[1].get("action", "") == "add"
			# No message text may leak into a record as a field name.
			var clean_keys := true
			for r in rrecs:
				for k in r.keys():
					if not _is_ztag_key(String(k)):
						clean_keys = false
						_log("[selftest] leaked field name: %s" % k)

			# A refusal on its own has to produce NO records. As a record it
			# carries no `action`, and the dock counted that as an edit - the
			# phantom "1 file to edit" that came back after every reconcile
			# and that clicking Reconcile could never clear.
			var only_refusal := "//depot/proj/locked.tscn - can't edit exclusive file already opened\n" \
					+ "... //depot/proj/locked.tscn - also opened by bob@bob_ws\n"
			var orecs := _parse_ztag({"exit_code": 0, "output": [only_refusal]})
			_log("[selftest] refusal-only blob -> %d record(s)" % orecs.size())
			var no_phantom: bool = orecs.is_empty()

			var refused := _refusals({"exit_code": 0, "output": [refused_blob]})
			_log("[selftest] refusals: count=%d locked=%s" % [refused.count, refused.locked])
			var refusal_ok: bool = int(refused.count) == 1 and bool(refused.locked) \
					and refused.lines.size() == 2
			if not no_phantom:
				_log("[selftest] FAIL: parse-ztag - a refusal became a phantom record")
			elif not clean_keys:
				_log("[selftest] FAIL: parse-ztag - message text leaked into a record")
			elif basic_ok and kept_edit and refusal_ok and no_phantom and clean_keys:
				_log("[selftest] PASS: parse-ztag")
			elif not kept_edit:
				_log("[selftest] FAIL: parse-ztag - a p4 message corrupted the record stream")
			elif not refusal_ok:
				_log("[selftest] FAIL: parse-ztag - refusal detection")
			get_tree().quit()
			return
		if arg == "--p4-selftest-sync-report":
			# Server-independent: the `p4 sync` output shapes whose records say
			# the wrong thing, copied from what a 2025.2 server really printed.
			# It asserts on the two user-facing strings as well as the parsers,
			# because the parsers were never where a lie would reach the user.
			#
			# (a) A refused overwrite. `sync -n` predicts nothing, and the
			# failing sync prints a perfectly normal `action updated` record for
			# the file alongside "Can't clobber writable file <path>", exiting
			# 1. Counting records reports that file as downloaded when the
			# user's own version is still sitting there.
			var clobber_blob := "//d/proj/nope.txt - no such file(s).\n" \
					+ "... depotFile //d/proj/.p4ignore\n" \
					+ "... clientFile C:\\ws\\proj\\.p4ignore\n" \
					+ "... rev 3\n... action updated\n... fileSize 14625\n" \
					+ "... totalFileSize 25044\n... totalFileCount 2\n... change 3132\n\n" \
					+ "Can't clobber writable file C:\\ws\\proj\\.p4ignore\n" \
					+ "... depotFile //d/proj/level.tscn\n" \
					+ "... clientFile C:\\ws\\proj\\level.tscn\n" \
					+ "... rev 2\n... action updated\n... fileSize 10419\n\n"
			var cres := {"exit_code": 1, "output": [clobber_blob]}
			var crecs := _parse_ztag(cres)
			var csum := _summarize_sync(crecs)
			var cnotes := _sync_notes(cres)
			var no_reload := {"reloaded": [], "orphaned": []}
			var creport := _get_latest_report(csum, cnotes, no_reload, [], 1)
			_log("[selftest] clobber blob -> %d record(s), %d changed, clobbered=%s, problems=%s"
					% [crecs.size(), csum.updates, cnotes.clobbered, cnotes.problems])
			_log("[selftest] clobber report: %s" % creport.replace("\n", " | "))
			# The report must count ONE download, not two, and must name the
			# file it could not write. "problems" must stay empty: the tagged
			# lines are fields, and "no such file(s)" is nothing to act on.
			var clobber_ok: bool = crecs.size() == 2 and int(csum.updates) == 2 \
					and cnotes.clobbered.size() == 1 \
					and String(cnotes.clobbered[0]) == "C:\\ws\\proj\\.p4ignore" \
					and cnotes.problems.is_empty() \
					and creport.contains("downloaded 1 file(s)") \
					and not creport.contains("downloaded 2 file(s)") \
					and creport.contains("would not overwrite") \
					and creport.contains("C:\\ws\\proj\\.p4ignore")

			# (b) A file you have checked out that is behind the server. p4
			# emits NO record for it, only messages, so counting records makes a
			# sync with real work to do look like "already up to date".
			var opened_blob := "//d/proj/.p4ignore#3 - is opened and not being changed\n" \
					+ "... //d/proj/.p4ignore - must resolve #2,#3 before submitting\n"
			var ores := {"exit_code": 0, "output": [opened_blob]}
			var osum := _summarize_sync(_parse_ztag(ores))
			var onotes := _sync_notes(ores)
			var has_work: bool = _get_latest_has_work(osum, onotes)
			var empty_notes := _sync_notes({"exit_code": 0, "output": ["... - file(s) up-to-date.\n"]})
			var idle_is_idle: bool = not _get_latest_has_work(
					_summarize_sync([]), empty_notes)
			_log("[selftest] opened-behind blob -> %d to write, opened_behind=%d, has_work=%s, idle-blob has_work=%s"
					% [osum.names.size(), onotes.opened_behind, has_work, not idle_is_idle])
			var opened_ok: bool = osum.names.is_empty() and int(onotes.opened_behind) == 1 \
					and onotes.problems.is_empty() and has_work and idle_is_idle

			# (c) sync's action vocabulary is its own: `added` is a file that
			# wasn't on disk yet, `deleted` one being removed from disk - not
			# reconcile's "open for add" / "open for delete". totalFileSize is
			# deliberately NOT the sum of the fileSizes, so summing and reading
			# the total can be told apart.
			var mixed_blob := "... depotFile //d/proj/new.png\n" \
					+ "... clientFile C:\\ws\\proj\\new.png\n" \
					+ "... rev 1\n... action added\n... fileSize 2048\n" \
					+ "... totalFileSize 999999\n... totalFileCount 3\n... change 9\n\n" \
					+ "... depotFile //d/proj/gone.tscn\n" \
					+ "... clientFile C:\\ws\\proj\\gone.tscn\n" \
					+ "... rev 1\n... action deleted\n... fileSize 0\n\n" \
					+ "... depotFile //d/proj/level.gd\n" \
					+ "... clientFile C:\\ws\\proj\\level.gd\n" \
					+ "... rev 4\n... action updated\n... fileSize 1024\n\n"
			var msum := _summarize_sync(_parse_ztag({"exit_code": 0, "output": [mixed_blob]}))
			_log("[selftest] mixed blob -> %d new, %d changed, %d removed, %s, first=%s, deleted=%s"
					% [msum.adds, msum.updates, msum.deletes, _human_bytes(int(msum.bytes)),
					"" if msum.names.is_empty() else msum.names[0], msum.deleted_names])
			var mixed_ok: bool = int(msum.adds) == 1 and int(msum.updates) == 1 \
					and int(msum.deletes) == 1 and int(msum.bytes) == 3072 \
					and msum.names.size() == 3 \
					and String(msum.names[0]).ends_with("gone.tscn") \
					and msum.deleted_names.size() == 1 \
					and String(msum.deleted_names[0]).ends_with("gone.tscn")

			# (d) The confirmation carries every warning the user gets before a
			# project-wide download, and none of it was reachable by a test
			# while it lived inside the dialog call. Two open files here: one
			# being rewritten (its tab reloads, unsaved work is lost) and one
			# being deleted (its tab CANNOT reload, and saving it would put the
			# file back into the depot).
			var open_files := {"C:\\ws\\proj\\level.gd": true, "C:\\ws\\proj\\gone.tscn": true}
			var confirm := _get_latest_confirm_text(msum, {"opened_behind": 2}, open_files)
			_log("[selftest] confirm text: %s" % confirm.replace("\n", " | "))
			var confirm_ok: bool = confirm.contains("didn't save is lost") \
					and confirm.contains("C:\\ws\\proj\\level.gd") \
					and confirm.contains("CAREFUL") \
					and confirm.contains("put the file back") \
					and confirm.contains("C:\\ws\\proj\\gone.tscn") \
					and confirm.contains("checked out that are behind the server") \
					and confirm.contains("remove 1 from your project folder")

			# (e) p4 writes its messages to stderr and its records to stdout,
			# and OS.execute merges both into one blob, so a message can land
			# mid-record. That leaves a record with no clientFile and a
			# clientFile with a newline in it. Silently dropping those would
			# take a real file out of the download list and out of the reload
			# set with it, so they are counted and the user is told the list may
			# be short.
			var torn_blob := "... depotFile //d/proj/a.tscn\n" \
					+ "//d/proj/b.gd#3 - is opened and not being changed\n" \
					+ "... //d/proj/b.gd - must resolve #2,#3 before submitting\n" \
					+ "... clientFile C:\\ws\\proj\\a.tscn\n"
			var tsum := _summarize_sync(_parse_ztag({"exit_code": 0, "output": [torn_blob]}))
			var tconfirm := _get_latest_confirm_text(tsum, {"opened_behind": 0}, {})
			_log("[selftest] torn blob -> %d usable, %d unreadable" % [tsum.names.size(), tsum.malformed])
			var torn_ok: bool = int(tsum.malformed) > 0 \
					and tconfirm.contains("couldn't be read")

			# (f) The two after-the-fact outcomes the user has to act on by
			# hand: a tab left open on a deleted file, and a file that now needs
			# the two versions combined. Both are reported from data the records
			# don't carry, so both need asserting.
			var orphan_reload := {"reloaded": [], "orphaned": ["res://gone.tscn"]}
			var quiet_notes := {"clobbered": [], "opened_behind": 0, "problems": [],
					"nothing_in_depot": false}
			var handwork := _get_latest_report(msum, quiet_notes, orphan_reload,
					["res://player.gd"], 0)
			_log("[selftest] hand-work report: %s" % handwork.replace("\n", " | "))
			var handwork_ok: bool = handwork.contains("res://gone.tscn") \
					and handwork.contains("WITHOUT saving") \
					and handwork.contains("res://player.gd") \
					and handwork.contains("Resolve") \
					and handwork.contains("removed 1 file(s)")

			# (g) A sync that failed for a reason p4 didn't explain must not
			# read as success.
			var silent_fail := _get_latest_report(_summarize_sync([]), quiet_notes,
					no_reload, [], 1)
			_log("[selftest] silent-failure report: %s" % silent_fail.replace("\n", " | "))
			var silent_ok: bool = silent_fail.contains("didn't say why")

			# (h) `sync -s` refusing to overwrite a file whose contents changed
			# without a checkout - the macOS/Linux "saved over a read-only file"
			# case. Copied from a 2025.2 server: one message per file, NO record,
			# exit code 0. Read as "nothing to say", that is a project silently
			# left behind the server; read as a download, it is a lie.
			var modified_blob := "//d/proj/.p4ignore#3 - can't update modified file " \
					+ "C:\\ws\\proj\\.p4ignore\n" \
					+ "//d/proj/project.godot#5 - can't update modified file " \
					+ "C:\\ws\\proj\\project.godot\n" \
					+ "... depotFile //d/proj/level.gd\n" \
					+ "... clientFile C:\\ws\\proj\\level.gd\n" \
					+ "... rev 4\n... action updated\n... fileSize 1024\n\n"
			var mres := {"exit_code": 0, "output": [modified_blob]}
			var mnotes := _sync_notes(mres)
			var mdone := _summarize_sync(_parse_ztag(mres))
			var mreport := _get_latest_report(mdone, mnotes, no_reload, [], 0)
			var mconfirm := _get_latest_confirm_text(mdone, mnotes, {})
			var only_modified := _sync_notes({"exit_code": 0, "output": [
					"//d/proj/.p4ignore#3 - can't update modified file C:\\ws\\proj\\.p4ignore\n"]})
			# The third refusal: the server adds a file where an untracked one of
			# the same name already sits. Reconcile is the wrong advice for it.
			var enotes := _sync_notes({"exit_code": 0, "output": [
					"//d/proj/notes.md#1 - can't overwrite existing file C:\\ws\\proj\\notes.md\n"]})
			var ereport := _get_latest_report(_summarize_sync([]), enotes, no_reload, [], 0)
			_log("[selftest] existing-file report: %s" % ereport.replace("\n", " | "))
			# A success p4 reports in words in the middle of tagged output must not
			# be listed under "Perforce also said" (seen after a cancelled sync).
			var wordy := _sync_notes({"exit_code": 0, "output": [
					"... depotFile //d/proj/a.png\n... clientFile C:\\ws\\proj\\a.png\n... rev 2\n" \
					+ "... action added\n... fileSize 9\n\n" \
					+ "//d/proj/a.png.import#1 - added as C:\\ws\\proj\\a.png.import\n" \
					+ "//d/proj/odd.txt#1 - some message nobody anticipated\n"]})
			var existing_ok: bool = wordy.problems.size() == 1 \
					and String(wordy.problems[0]).contains("nobody anticipated") \
					and enotes.existing.size() == 1 and enotes.problems.is_empty() \
					and enotes.modified.is_empty() \
					and ereport.contains("C:\\ws\\proj\\notes.md") \
					and ereport.contains("Move or rename") and not ereport.contains("Reconcile")
			_log("[selftest] modified blob -> modified=%s, clobbered=%s, problems=%s, %d record(s)"
					% [mnotes.modified, mnotes.clobbered, mnotes.problems, mdone.names.size()])
			_log("[selftest] modified report: %s" % mreport.replace("\n", " | "))
			var modified_ok: bool = mnotes.modified.size() == 2 \
					and String(mnotes.modified[0]) == "C:\\ws\\proj\\.p4ignore" \
					and mnotes.clobbered.is_empty() and mnotes.problems.is_empty() \
					and mdone.names.size() == 1 \
					and mreport.contains("downloaded 1 file(s)") \
					and mreport.contains("would not overwrite 2 file(s)") \
					and mreport.contains("C:\\ws\\proj\\project.godot") \
					and mreport.contains("Reconcile") \
					and mconfirm.contains("will NOT be downloaded") \
					and mconfirm.contains("C:\\ws\\proj\\.p4ignore") \
					and only_modified.modified.size() == 1 \
					and not _get_latest_has_work(_summarize_sync([]), only_modified) \
					and existing_ok

			if clobber_ok and opened_ok and mixed_ok and confirm_ok and torn_ok \
					and handwork_ok and silent_ok and modified_ok:
				_log("[selftest] PASS: sync-report")
			elif not modified_ok:
				_log("[selftest] FAIL: sync-report - a file safe sync refused to overwrite wasn't reported")
			elif not clobber_ok:
				_log("[selftest] FAIL: sync-report - a refused overwrite read as a successful download")
			elif not opened_ok:
				_log("[selftest] FAIL: sync-report - a checked-out file behind the server read as nothing to do")
			elif not mixed_ok:
				_log("[selftest] FAIL: sync-report - wrong counts for sync's own actions")
			elif not confirm_ok:
				_log("[selftest] FAIL: sync-report - the confirmation dropped a data-loss warning")
			elif not torn_ok:
				_log("[selftest] FAIL: sync-report - an unreadable record was dropped silently")
			elif not handwork_ok:
				_log("[selftest] FAIL: sync-report - the report didn't name the work left to do by hand")
			else:
				_log("[selftest] FAIL: sync-report - an unexplained failure read as success")
			get_tree().quit()
			return
		if arg == "--p4-selftest-unchanged-save":
			# Server-independent: a failed safe-save's leftover .tmp vs the disk
			# file. Same text modulo CRLF -> unchanged (and the tmp is deleted);
			# different text -> changed; binary extension gets no CRLF tolerance.
			var base := OS.get_cache_dir().path_join("p4_unchg_test.tscn")
			var tmp := base + "1234.tmp"
			var f := FileAccess.open(base, FileAccess.WRITE)
			f.store_string("line1\r\nline2\r\n")
			f.close()
			f = FileAccess.open(tmp, FileAccess.WRITE)
			f.store_string("line1\nline2\n")
			f.close()
			var same := _failed_write_was_unchanged(base)
			var tmp_deleted := not FileAccess.file_exists(tmp)
			f = FileAccess.open(tmp, FileAccess.WRITE)
			f.store_string("line1\nlineX\n")
			f.close()
			var diff_detected := not _failed_write_was_unchanged(base)
			var bin_base := OS.get_cache_dir().path_join("p4_unchg_test.res")
			var bin_tmp := bin_base + "1234.tmp"
			f = FileAccess.open(bin_base, FileAccess.WRITE)
			f.store_string("line1\r\nline2\r\n")
			f.close()
			f = FileAccess.open(bin_tmp, FileAccess.WRITE)
			f.store_string("line1\nline2\n")
			f.close()
			var bin_strict := not _failed_write_was_unchanged(bin_base)
			for leftover in [base, tmp, bin_base, bin_tmp]:
				DirAccess.remove_absolute(leftover)
			_log("[selftest] unchanged=%s tmp-deleted=%s diff-detected=%s bin-strict=%s"
					% [same, tmp_deleted, diff_detected, bin_strict])
			if same and tmp_deleted and diff_detected and bin_strict:
				_log("[selftest] PASS: unchanged-save")
			else:
				_log("[selftest] FAIL: unchanged-save")
			get_tree().quit()
			return
		if arg == "--p4-selftest-dismiss-dialog":
			# Server-independent. The no-op-save dismissal must hide (1) a bare
			# AcceptDialog whose dialog_text mentions the file and (2) a
			# Load-Errors-shaped dialog (empty dialog_text, error lines in a
			# RichTextLabel child) once every line is covered - and must leave
			# (3) a mixed dialog with an uncovered line, and ConfirmationDialogs
			# (all of the plugin's own dialogs), untouched.
			_selftest_auto_answer = "confirm" # resolves case 3's fallback alert
			var gui := EditorInterface.get_base_control()
			var ours := ConfirmationDialog.new()
			ours.dialog_text = "Check out level.tscn?"
			gui.add_child(ours)
			ours.visible = true

			var bare := AcceptDialog.new()
			bare.dialog_text = "Unable to write to file 'C:\\ws\\level.tscn', file in use, locked or lacking permissions."
			gui.add_child(bare)
			bare.visible = true
			_queue_error_dialog_dismissal("res://level.tscn")
			while _error_dismiss_running:
				await get_tree().process_frame
			var bare_hidden := not bare.visible
			bare.queue_free()

			var loaderr := AcceptDialog.new()
			var rtl := RichTextLabel.new()
			rtl.text = " Unable to write to file 'C:\\ws\\level.tscn', file in use, locked or lacking permissions.\n" \
					+ " Unable to write to file 'C:\\ws\\level\\tileset\\tileset.tres', file in use, locked or lacking permissions."
			loaderr.add_child(rtl)
			gui.add_child(loaderr)
			loaderr.visible = true
			_queue_error_dialog_dismissal("res://level.tscn")
			_queue_error_dialog_dismissal("res://level/tileset/tileset.tres")
			while _error_dismiss_running:
				await get_tree().process_frame
			var loaderr_hidden := not loaderr.visible
			loaderr.queue_free()

			var mixed := AcceptDialog.new()
			var rtl2 := RichTextLabel.new()
			rtl2.text = " Unable to write to file 'C:\\ws\\level.tscn', file in use, locked or lacking permissions.\n" \
					+ " Unable to write to file 'C:\\ws\\other.tscn', file in use, locked or lacking permissions."
			mixed.add_child(rtl2)
			gui.add_child(mixed)
			mixed.visible = true
			_queue_error_dialog_dismissal("res://level.tscn")
			while _error_dismiss_running:
				await get_tree().process_frame
			var mixed_untouched: bool = mixed.visible
			var ours_untouched: bool = ours.visible
			mixed.queue_free()
			ours.queue_free()

			# A real failure for a DIFFERENT file whose name merely ends with
			# the registered one must stay up. Matching the bare file name
			# anywhere in the line dismissed this, hiding a genuine error.
			var lookalike := AcceptDialog.new()
			lookalike.dialog_text = "Unable to write to file 'C:\\ws\\sublevel.tscn', file in use, locked or lacking permissions."
			gui.add_child(lookalike)
			lookalike.visible = true
			_queue_error_dialog_dismissal("res://level.tscn")
			while _error_dismiss_running:
				await get_tree().process_frame
			var lookalike_untouched: bool = lookalike.visible
			lookalike.queue_free()

			_log("[selftest] bare-hidden=%s loaderr-hidden=%s mixed-untouched=%s ours-untouched=%s lookalike-untouched=%s"
					% [bare_hidden, loaderr_hidden, mixed_untouched, ours_untouched, lookalike_untouched])
			if bare_hidden and loaderr_hidden and mixed_untouched and ours_untouched \
					and lookalike_untouched:
				_log("[selftest] PASS: dismiss-dialog")
			else:
				_log("[selftest] FAIL: dismiss-dialog")
			get_tree().quit()
			return
		if arg == "--p4-selftest-prewrite":
			# Server-independent: the pre-write-pass helpers on a real temp
			# file - the writable flip both ways, the CRLF-tolerant unchanged
			# classification, real-change detection, and backup restore.
			var target := OS.get_cache_dir().path_join("p4_prewrite_test.tscn")
			var f2 := FileAccess.open(target, FileAccess.WRITE)
			f2.store_string("node A\r\nnode B\r\n")
			f2.close()
			var ro_ok := _set_file_writable(target, false)
			var locked := FileAccess.open(target, FileAccess.READ_WRITE) == null
			var backup := _prewrite_backup_path("res://p4_prewrite_test.tscn")
			var copied := DirAccess.copy_absolute(target, backup) == OK
			var rw_ok := _set_file_writable(target, true)
			var unlocked := FileAccess.open(target, FileAccess.READ_WRITE) != null
			f2 = FileAccess.open(target, FileAccess.WRITE)
			f2.store_string("node A\nnode B\n") # the editor's rewrite: same content, LF
			f2.close()
			var same := _contents_match(FileAccess.get_file_as_bytes(target),
					FileAccess.get_file_as_bytes(backup), "tscn")
			f2 = FileAccess.open(target, FileAccess.WRITE)
			f2.store_string("node A\nnode CHANGED\n")
			f2.close()
			var diff_detected := not _contents_match(FileAccess.get_file_as_bytes(target),
					FileAccess.get_file_as_bytes(backup), "tscn")
			var restored := DirAccess.copy_absolute(backup, target) == OK \
					and FileAccess.get_file_as_bytes(target) == FileAccess.get_file_as_bytes(backup)
			_set_file_writable(target, true)
			DirAccess.remove_absolute(target)
			DirAccess.remove_absolute(backup)
			_log("[selftest] ro=%s locked=%s copied=%s rw=%s unlocked=%s same=%s diff=%s restored=%s"
					% [ro_ok, locked, copied, rw_ok, unlocked, same, diff_detected, restored])
			if ro_ok and locked and copied and rw_ok and unlocked and same and diff_detected and restored:
				_log("[selftest] PASS: prewrite")
			else:
				_log("[selftest] FAIL: prewrite")
			get_tree().quit()
			return
		if arg == "--p4-selftest-special-names":
			# Live and DESTRUCTIVE (four real submits): files named with @ # %
			# through the plugin's add, submit, checkout, diff, move and delete
			# paths. Refuses to run unless nothing is opened.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: special-names - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			var dir := "res://p4g_special_names_test"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
			var names := ["icon@2x.txt", "take#1.txt", "50%.txt"]
			var ok := true
			for n: String in names:
				var fw := FileAccess.open(ProjectSettings.globalize_path(dir.path_join(n)), FileAccess.WRITE)
				fw.store_string("special name %s\n" % n)
				fw.close()
				await _add_path(dir.path_join(n))
				var added := String((await _fetch_fstat_record(dir.path_join(n))).get("action", "")) == "add"
				_log("[selftest] add %s -> %s" % [n, added])
				ok = ok and added
			await _submit_changelist("default", [], "P4Godot selftest: special file names")
			var edit_res := dir.path_join("icon@2x.txt")
			var co: Dictionary = await _do_checkout(edit_res)
			var fw2 := FileAccess.open(ProjectSettings.globalize_path(edit_res), FileAccess.WRITE)
			fw2.store_string("special name icon@2x.txt\nchanged\n")
			fw2.close()
			var diff := await _p4_exec(["diff", "-dul", ProjectSettings.globalize_path(edit_res)])
			var diff_ok := int(diff.exit_code) == 0 and _diff_has_changes(String(diff.output[0]))
			var depot := _diff_depot_path(String(diff.output[0]), "")
			var have := await _p4_exec(["print", "-q", depot + "#have"])
			var print_ok := int(have.exit_code) == 0 and String(have.output[0]).contains("special name")
			await _p4_exec_logged(["revert", ProjectSettings.globalize_path(edit_res)])
			_log("[selftest] checkout=%s diff=%s print-have=%s" % [co.ok, diff_ok, print_ok])
			ok = ok and co.ok and diff_ok and print_ok
			var old_res := dir.path_join("take#1.txt")
			var new_res := dir.path_join("take#2.txt")
			DirAccess.rename_absolute(ProjectSettings.globalize_path(old_res), ProjectSettings.globalize_path(new_res))
			await _p4_record_move(old_res, new_res, false)
			var moved := String((await _fetch_fstat_record(new_res)).get("action", "")) == "move/add"
			_log("[selftest] move take#1 -> take#2: %s" % moved)
			ok = ok and moved
			await _submit_changelist("default", [], "P4Godot selftest: special names move")
			for n: String in ["icon@2x.txt", "take#2.txt", "50%.txt"]:
				await _p4_exec_logged(["delete", ProjectSettings.globalize_path(dir.path_join(n))])
			await _submit_changelist("default", [], "P4Godot selftest: special names cleanup")
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			for n: String in ["icon@2x.txt", "take#2.txt", "50%.txt"]:
				var st := await _fetch_fstat_record(dir.path_join(n))
				ok = ok and String(st.get("headAction", "")) == "delete"
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
			_log("[selftest] opened-after=%d" % left)
			_log("[selftest] %s: special-names" % ("PASS" if ok and left == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-breaker":
			# Live, read-only: point at an unroutable server once (one ~21 s
			# connect timeout), then check that save-path and status calls return
			# instantly while connection probes still try.
			var saved_port := _override_port
			_override_port = "10.255.255.1:1666"
			var first := await _p4_exec(["-ztag", "fstat", "C:/nothing"])
			var tripped := _server_unreachable()
			var t0 := Time.get_ticks_msec()
			var sync_r := _p4_exec_sync(["fstat", "C:/nothing"])
			var async_r := await _p4_exec(["-ztag", "opened"])
			var fast_ms := Time.get_ticks_msec() - t0
			var skipped: bool = String(sync_r.output[0]).contains("skipped") \
					and String(async_r.output[0]).contains("skipped")
			_override_port = saved_port
			_unreachable_until_msec = 0
			_log("[selftest] first-exit=%d tripped=%s skipped=%s fast=%dms" % [int(first.exit_code), tripped, skipped, fast_ms])
			_log("[selftest] %s: breaker" % ("PASS" if tripped and skipped and fast_ms < 1000 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-dial":
			# Server-independent: the save path's connect check. An unroutable
			# address must fail in about the deadline, not p4's ~21 s; a closed
			# local port fails at once; a listening one passes.
			var parse_ok: bool = _p4port_host_and_port("ssl:p4.example.com:1666") == {"host": "p4.example.com", "port": 1666} \
					and _p4port_host_and_port("tcp6:[::1]:1667") == {"host": "::1", "port": 1667} \
					and _p4port_host_and_port("perforce:1666") == {"host": "perforce", "port": 1666} \
					and _p4port_host_and_port("1666") == {"host": "localhost", "port": 1666} \
					and _p4port_host_and_port("ssl:1666") == {"host": "localhost", "port": 1666} \
					and _p4port_host_and_port("ssl64:10.0.0.5:2000") == {"host": "10.0.0.5", "port": 2000} \
					and _p4port_host_and_port("rsh:p4d -r /x -i").is_empty() \
					and _p4port_host_and_port("").is_empty() \
					and _p4port_host_and_port("host:notaport").is_empty() \
					and _p4port_host_and_port("host:70000").is_empty()
			var server := TCPServer.new()
			var listen_port := 0
			for candidate in range(47100, 47200):
				if server.listen(candidate, "127.0.0.1") == OK:
					listen_port = candidate
					break
			var t0 := Time.get_ticks_msec()
			var open_ok := listen_port != 0 and _tcp_dialable("127.0.0.1:%d" % listen_port, 2000)
			var open_ms := Time.get_ticks_msec() - t0
			server.stop()
			t0 = Time.get_ticks_msec()
			var closed_ok := listen_port != 0 and not _tcp_dialable("127.0.0.1:%d" % listen_port, 2000)
			var closed_ms := Time.get_ticks_msec() - t0
			t0 = Time.get_ticks_msec()
			var dead_ok := not _tcp_dialable("10.255.255.1:1666", 2000)
			var dead_ms := Time.get_ticks_msec() - t0
			var unparsed_ok := _tcp_dialable("rsh:p4d -i", 2000)
			# End to end: a save-path command against the unroutable address
			# comes back "skipped" in about the deadline and trips the breaker.
			var saved_port := _override_port
			var saved_dial := _dial_port
			_override_port = "10.255.255.1:1666"
			_dial_port = _override_port
			_last_contact_msec = 0
			# The startup probe may have tripped the breaker already, which would
			# skip the command before the check under test runs.
			_unreachable_until_msec = 0
			t0 = Time.get_ticks_msec()
			var sync_r := _p4_exec_sync(["fstat", "C:/nothing"])
			var save_ms := Time.get_ticks_msec() - t0
			var save_ok: bool = String(sync_r.output[0]).contains("skipped") and _server_unreachable() \
					and save_ms >= 1500 and save_ms < 3000
			_override_port = saved_port
			_dial_port = saved_dial
			_unreachable_until_msec = 0
			_log("[selftest] parse=%s open=%s(%dms) closed=%s(%dms) unroutable=%s(%dms) unparsed=%s save-path=%s(%dms)" \
					% [parse_ok, open_ok, open_ms, closed_ok, closed_ms, dead_ok, dead_ms, unparsed_ok, save_ok, save_ms])
			_log("[selftest] %s: dial" % ("PASS" if parse_ok and open_ok and closed_ok and dead_ok \
					and dead_ms < 3000 and unparsed_ok and save_ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-probe":
			# Live, read-only: log what the connection probe decides. Run it with
			# P4TICKETS pointing at an empty file to see the logged-out path.
			var status: String = await _probe_connection()
			_log("[selftest] probe status=%s" % status)
			get_tree().quit()
			return
		if arg == "--p4-selftest-exec-quoting":
			# Needs a local p4 binary, no server. Pins the shell quoting helpers,
			# then runs `p4 -V` through the spec-on-stdin shell path with a temp
			# file in a directory whose name has a space and an ampersand (and,
			# on Windows, through the absolute "C:/Program Files/..." p4 if present).
			var sh_ok := _sh_quote("it's") == "'it'\\''s'"
			var cmd_ok := _cmd_quote("a b") == "\"a b\"" and _cmd_quote("ab") == "ab" \
					and _cmd_quote("x&y") == "\"x&y\""
			var esc := _os_args(PackedStringArray(["$V `x` \"q\" \\"]))
			var os_ok := esc[0] == ("$V `x` \"q\" \\" if OS.get_name() == "Windows"
					else "\\$V \\`x\\` \\\"q\\\" \\\\")
			# Perforce path escaping: local paths escaped, depot paths and flags
			# untouched, `add` gets raw names plus -f.
			var pe_ok := _escape_path_args(PackedStringArray(["-ztag", "fstat", "C:/p/icon@2x.png"])) \
					== PackedStringArray(["-ztag", "fstat", "C:/p/icon%402x.png"]) \
				and _escape_path_args(PackedStringArray(["edit", "-c", "12", "/home/u/50%.txt"])) \
					== PackedStringArray(["edit", "-c", "12", "/home/u/50%25.txt"]) \
				and _escape_path_args(PackedStringArray(["add", "C:/p/take#1.txt"])) \
					== PackedStringArray(["add", "-f", "C:/p/take#1.txt"]) \
				and _escape_path_args(PackedStringArray(["add", "C:/p/plain.txt"])) \
					== PackedStringArray(["add", "C:/p/plain.txt"]) \
				and _escape_path_args(PackedStringArray(["print", "-q", "//d/x%40y#have"])) \
					== PackedStringArray(["print", "-q", "//d/x%40y#have"]) \
				and _escape_path_args(PackedStringArray(["reconcile", "C:/My Game/..."])) \
					== PackedStringArray(["reconcile", "-f", "C:/My Game/..."]) \
				and _escape_path_args(PackedStringArray(["-ztag", "reconcile", "-n", "C:/p/take#1.txt"])) \
					== PackedStringArray(["-ztag", "reconcile", "-f", "-n", "C:/p/take#1.txt"]) \
				and _p4_escape_path("/a/*%@#") == "/a/%2A%25%40%23"
			_log("[selftest] path-escaping=%s" % pe_ok)
			os_ok = os_ok and pe_ok
			var odd_dir := ProjectSettings.globalize_path("user://p4 selftest & quoting")
			DirAccess.make_dir_recursive_absolute(odd_dir)
			var stdin_file := odd_dir.path_join("in put.txt")
			var fw := FileAccess.open(stdin_file, FileAccess.WRITE)
			fw.store_string("ignored\n")
			fw.close()
			var bins := [_p4_cmd()]
			if OS.get_name() == "Windows" and FileAccess.file_exists("C:/Program Files/Perforce/p4.exe"):
				bins.append("C:/Program Files/Perforce/p4.exe")
			var runs_ok := true
			for b: String in bins:
				var out := []
				var code := _p4_execute_with_stdin(b, PackedStringArray(["-V"]), stdin_file, out)
				var ran := code == 0 and not out.is_empty() and String(out[0]).contains("Perforce")
				_log("[selftest] stdin-exec bin=%s exit=%d ran=%s" % [b, code, ran])
				runs_ok = runs_ok and ran
			DirAccess.remove_absolute(stdin_file)
			DirAccess.remove_absolute(odd_dir)
			_log("[selftest] sh=%s cmd=%s os-args=%s stdin-runs=%s bin=%s" % [sh_ok, cmd_ok, os_ok, runs_ok, _p4_bin])
			if sh_ok and cmd_ok and os_ok and runs_ok and not _p4_bin.is_empty():
				_log("[selftest] PASS: exec-quoting")
			else:
				_log("[selftest] FAIL: exec-quoting")
			get_tree().quit()
			return
		if arg == "--p4-selftest-save-guards":
			# Server-independent, on real files under user:// (never the project):
			# 1. _finish_prewrite_pass leaves an LF-only rewrite in place (no
			#    copy-back that would move the mtime) and makes it read-only.
			# 2. The reimport guard flips read-only .import files writable, then
			#    re-locks an unchanged one (keeping Godot's LF bytes) and reports a
			#    changed one, leaving it writable.
			var dir := "user://p4_selftest_guards"
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
			var put := func(res: String, text: String) -> void:
				var gp := ProjectSettings.globalize_path(res)
				_set_file_writable(gp, true)
				var fw := FileAccess.open(gp, FileAccess.WRITE)
				fw.store_string(text)
				fw.close()
			var is_rw := func(res: String) -> bool:
				return FileAccess.open(ProjectSettings.globalize_path(res), FileAccess.READ_WRITE) != null
			var body := "[remap]\r\n\r\nimporter=\"texture\"\r\n"
			# 1. Pre-write finish, unchanged content.
			var scene := dir + "/a.tscn"
			put.call(scene, "node A\r\n")
			var scene_g := ProjectSettings.globalize_path(scene)
			var backup := _prewrite_backup_path(scene)
			DirAccess.copy_absolute(scene_g, backup)
			_prewrite_managed[scene] = backup
			put.call(scene, "node A\n") # the editor's LF rewrite
			_finish_prewrite_pass()
			var pw_kept := FileAccess.get_file_as_string(scene_g) == "node A\n"
			var pw_locked: bool = not is_rw.call(scene)
			var pw_backup_gone := not FileAccess.file_exists(backup)
			# 2. Reimport guard.
			var same_res := dir + "/same.png"
			var changed_res := dir + "/changed.png"
			put.call(same_res + ".import", body)
			put.call(changed_res + ".import", body)
			_set_file_writable(ProjectSettings.globalize_path(same_res + ".import"), false)
			_set_file_writable(ProjectSettings.globalize_path(changed_res + ".import"), false)
			var both := PackedStringArray([same_res, changed_res])
			_on_resources_reimporting(both)
			var ri_unlocked: bool = is_rw.call(same_res + ".import") and is_rw.call(changed_res + ".import")
			put.call(same_res + ".import", body.replace("\r\n", "\n"))
			put.call(changed_res + ".import", body.replace("\r\n", "\n") + "uid=\"uid://abc\"\n")
			var changed := _classify_reimported(both)
			var ri_same_locked: bool = not is_rw.call(same_res + ".import")
			var ri_same_lf := FileAccess.get_file_as_string(
					ProjectSettings.globalize_path(same_res + ".import")) == body.replace("\r\n", "\n")
			var ri_changed: bool = changed.size() == 1 \
					and changed[0] == ProjectSettings.globalize_path(changed_res + ".import") \
					and is_rw.call(changed_res + ".import")
			var ri_drained := _reimport_backups.is_empty()
			# 3. Move/delete sidecars.
			var sidecars_ok := _sidecars_of("res://a.png") == ["res://a.png.import", "res://a.png.uid"]
			for f in DirAccess.get_files_at(ProjectSettings.globalize_path(dir)):
				_set_file_writable(ProjectSettings.globalize_path(dir.path_join(f)), true)
				DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(f)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
			_log("[selftest] pw-kept=%s pw-locked=%s pw-backup-gone=%s ri-unlocked=%s ri-same-locked=%s ri-same-lf=%s ri-changed=%s ri-drained=%s sidecars=%s"
					% [pw_kept, pw_locked, pw_backup_gone, ri_unlocked, ri_same_locked, ri_same_lf,
					ri_changed, ri_drained, sidecars_ok])
			if pw_kept and pw_locked and pw_backup_gone and ri_unlocked and ri_same_locked \
					and ri_same_lf and ri_changed and ri_drained and sidecars_ok:
				_log("[selftest] PASS: save-guards")
			else:
				_log("[selftest] FAIL: save-guards")
			get_tree().quit()
			return
		if arg == "--p4-selftest-list-opened":
			# Live (needs the server): exercise the opened + where + changes
			# pipeline and the depot->res mapping end to end.
			var model := await _query_pending_model()
			_log("[selftest] available=%s changelists=%d" % [model.available, model.changelists.size()])
			for cl in model.changelists:
				_log("[selftest] CL %s: %d file(s) - %s" % [cl.change, cl.files.size(), cl.desc])
				for f in cl.files:
					_log("[selftest] opened: %s (%s) cl=%s" % [f.res_path, f.action, f.change])
			get_tree().quit()
			return
		if arg == "--p4-selftest-tree":
			# Live: refresh and walk the built Tree (items exist in memory even
			# headless) to confirm _rebuild_tree populated CLs and file rows.
			while _refresh_inflight: # let the initial _build_dock refresh settle
				await get_tree().process_frame
			await _refresh_changelists()
			var root := tree.get_root()
			var cl_count := 0
			var file_count := 0
			var cl_item: TreeItem = root.get_first_child() if root else null
			while cl_item != null:
				cl_count += 1
				var f_item := cl_item.get_first_child()
				while f_item != null:
					file_count += 1
					f_item = f_item.get_next()
				cl_item = cl_item.get_next()
			_log("[selftest] tree changelists=%d files=%d" % [cl_count, file_count])
			get_tree().quit()
			return
		if arg == "--p4-selftest-context-menu":
			# Server-independent: log the per-row menu item labels.
			_populate_context_menu({"type": "file", "res_path": "res://x.gd", "change": "default"})
			_log("[selftest] file-menu: %s" % _selftest_menu_labels())
			_populate_context_menu({"type": "cl", "change": "default", "file_count": 2})
			_log("[selftest] default-cl(2): %s" % _selftest_menu_labels())
			_populate_context_menu({"type": "cl", "change": "123", "desc": "wip", "file_count": 3})
			_log("[selftest] numbered-cl(3): %s" % _selftest_menu_labels())
			_populate_context_menu({"type": "cl", "change": "124", "desc": "empty", "file_count": 0})
			_log("[selftest] numbered-cl(0): %s" % _selftest_menu_labels())
			get_tree().quit()
			return
		if arg == "--p4-selftest-fs-menu":
			# Server-independent: folder filtering + the FileSystem-dock action set.
			var fs_files := _fs_files_only(PackedStringArray(
					["res://a.gd", "res://sub/", "res://scenes/b.tscn"]))
			_log("[selftest] fs files kept: %s" % [fs_files])
			var labels: Array = []
			for action in _fs_context_actions():
				labels.append(String(action.label))
			_log("[selftest] fs-menu: %s" % " | ".join(labels))
			var ok := fs_files.size() == 2 and ("res://a.gd" in fs_files) \
					and not ("res://sub/" in fs_files) and labels.size() == 6
			_log("[selftest] %s: fs-menu" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-fstat-summary":
			# Server-independent: the human status line from a canned fstat record.
			var rec := {"depotFile": "//depot/a.gd", "haveRev": "3", "headRev": "5",
					"action": "edit", "otherOpen0": "bob@bob_ws"}
			var line := _fstat_summary_line("res://a.gd", rec)
			_log("[selftest] summary: %s" % line)
			var untracked := _fstat_summary_line("res://b.gd", {})
			_log("[selftest] untracked: %s" % untracked)
			var ok := line.contains("//depot/a.gd#3") and line.contains("out of date") \
					and line.contains("opened for edit") and line.contains("bob@bob_ws") \
					and untracked.contains("not in Perforce")
			_log("[selftest] %s: fstat-summary" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-delete-action":
			# Server-independent: the delete-recording decision per fstat state,
			# plus the recursive-scope helper for folder ops.
			var cases := {
				"untracked": [{}, "none"],
				"tracked": [{"depotFile": "//d/a", "headRev": "3"}, "reconcile"],
				"opened-add": [{"depotFile": "//d/a", "action": "add"}, "revert"],
				"moved-here": [{"depotFile": "//d/b", "action": "move/add", "movedFile": "//d/a"}, "unmove"],
				"moved-away": [{"depotFile": "//d/a", "action": "move/delete", "movedFile": "//d/b"}, "reconcile"],
				"opened-edit": [{"depotFile": "//d/a", "action": "edit", "headRev": "3"}, "reconcile"],
				"gone-at-head": [{"depotFile": "//d/a", "headAction": "delete"}, "none"],
			}
			var all_ok := true
			for case_name in cases:
				var got := _delete_action_for(cases[case_name][0])
				var want := String(cases[case_name][1])
				var matched := got == want
				all_ok = all_ok and matched
				_log("[selftest] delete-action %s: got=%s want=%s %s"
						% [case_name, got, want, "OK" if matched else "MISMATCH"])
			var scope_ok := _as_recursive("C:/p/dir") == "C:/p/dir/..." \
					and _as_recursive("C:/p/dir/") == "C:/p/dir/..."
			_log("[selftest] as-recursive: %s" % ("OK" if scope_ok else "BAD"))
			all_ok = all_ok and scope_ok
			_log("[selftest] %s: delete-action" % ("PASS" if all_ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-reconcile-preview":
			# Live, non-destructive (reconcile -n).
			var preview := await _reconcile_preview()
			_log("[selftest] reconcile preview: %d change(s)" % preview.size())
			get_tree().quit()
			return
		if arg == "--p4-selftest-revert-unchanged-preview":
			# Live, non-destructive (revert -a -n); also checks clientFile->res.
			var preview := await _revert_unchanged_preview()
			_log("[selftest] revert-unchanged preview: %d file(s)" % preview.size())
			for rec in preview:
				_log("[selftest]   -> %s" % _local_to_res(String(rec.get("clientFile", ""))))
			get_tree().quit()
			return
		if arg == "--p4-selftest-revert-unchanged-skip":
			# Live, non-destructive: verify open-editor files are split out of the
			# revert set so their unsaved in-memory edits are protected.
			var preview := await _revert_unchanged_preview()
			var open_files := _open_editor_files()
			_log("[selftest] open editor files: %d" % open_files.size())
			var revertable := 0
			var skipped := 0
			for rec in preview:
				var res := _local_to_res(String(rec.get("clientFile", "")))
				if not res.is_empty() and open_files.has(res):
					skipped += 1
					_log("[selftest] skip (open): %s" % res)
				else:
					revertable += 1
			_log("[selftest] revert-unchanged: preview=%d revertable=%d skipped=%d"
					% [preview.size(), revertable, skipped])
			get_tree().quit()
			return
		if arg == "--p4-selftest-diff-align":
			# Server-independent: hunk parsing, side-by-side row alignment
			# (pairing + filler), and the intraline changed-span trim.
			var old_lines := PackedStringArray(["a", "b", "c", "d"])
			var new_lines := PackedStringArray(["a", "B2", "c", "x", "d"])
			var sample := "--- //depot/f\t2026-01-01\n+++ C:\\w\\f\t2026-01-01\n" \
					+ "@@ -1,4 +1,5 @@\n a\n-b\n+B2\n c\n+x\n d\n"
			var rows := _align_diff(old_lines, new_lines, _parse_unified_hunks(sample))
			var kinds: Array = []
			for r: Dictionary in rows:
				kinds.append(r.kind)
			var span := _intraline_span("-0.08553267", "-0.085532665")
			# Collapse: 10 ctx, 1 add, 10 ctx -> gap(7), 3 ctx, add, 3 ctx, gap(7).
			var many: Array = []
			for k in 10:
				many.append({"kind": "ctx", "old_line": k + 1, "new_line": k + 1,
						"left": "l", "right": "l"})
			many.append({"kind": "add", "old_line": 0, "new_line": 11,
					"left": "", "right": "n"})
			for k in 10:
				many.append({"kind": "ctx", "old_line": k + 11, "new_line": k + 12,
						"left": "l", "right": "l"})
			var collapsed := _collapse_context(many)
			var col_kinds: Array = []
			for r in collapsed:
				col_kinds.append(r.kind)
			var ok: bool = kinds == ["ctx", "pair", "ctx", "add", "ctx"] \
					and rows[1].left == "b" and rows[1].right == "B2" \
					and rows[3].old_line == 0 and rows[3].right == "x" \
					and span[0] == Vector2i(10, 11) and span[1] == Vector2i(10, 12) \
					and _diff_depot_path(sample, "?") == "//depot/f" \
					and col_kinds == ["gap", "ctx", "ctx", "ctx", "add",
							"ctx", "ctx", "ctx", "gap"] \
					and int(collapsed[0].count) == 7 and int(collapsed[8].count) == 7
			_log("[selftest] rows: %s  span: %s  collapsed: %s" % [str(kinds), str(span), str(col_kinds)])
			_log("[selftest] %s: diff-align" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-diff="):
			# Live, read-only: run p4 diff -du and report change detection.
			var path := arg.substr("--p4-selftest-diff=".length())
			var result := await _p4_exec(["diff", "-dul", ProjectSettings.globalize_path(path)])
			var text := "" if result.output.is_empty() else String(result.output[0])
			_log("[selftest] diff '%s': has_changes=%s" % [path, _diff_has_changes(text)])
			get_tree().quit()
			return
		if arg == "--p4-selftest-build-change-spec":
			# Server-independent: replace a spec's Description, keep its Files.
			var template := "Change:\t123\n\nUser:\tbob\n\nDescription:\n\told line\n\nFiles:\n\t//depot/a\t# edit\n"
			var extracted := _extract_spec_description(template)
			var edited := _replace_spec_description(template, "new desc\nsecond")
			_log("[selftest] extracted-desc=%s" % extracted.replace("\n", "|"))
			var ok := extracted == "old line" and edited.contains("new desc") \
					and edited.contains("second") and edited.contains("//depot/a") \
					and not edited.contains("old line")
			_log("[selftest] %s: build-change-spec" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-p4-answers":
			# Server-independent: the readers of p4's answers to diff, add,
			# revert, login and passwd, fed text copied from a 2026.1 server.
			var hdr := "--- //game/main/a.txt\t2026-10-07 18:28:00.000000000 -0700\n" \
					+ "+++ C:/ws\\a.txt\t2026-10-07 18:28:00.000000000 -0700\n"
			var diff_ok: bool = \
					_diff_verdict(hdr + "@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n", 0) == "changed" \
					and _diff_verdict(hdr + "(... files differ ...)\n", 0) == "changed" \
					and _diff_verdict(hdr, 0) == "same" \
					and _diff_verdict("new.txt - file(s) not on client.\n", 0) == "new" \
					and _diff_verdict("a.txt - file(s) not opened on this client.\n", 0) == "unknown" \
					and _diff_verdict("", 0) == "unknown" \
					and _diff_verdict(hdr, 1) == "unknown" \
					and String(_diff_have_check([{"depotFile": "//d/a.txt", "headType": "text+k", "fileSize": "40"}]).verdict) == "ok" \
					and String(_diff_have_check([{}, {"headType": "utf16", "fileSize": "10"}]).verdict) == "ok" \
					and String(_diff_have_check([{"headType": "binary+F", "fileSize": "40"}]).verdict) == "binary" \
					and String(_diff_have_check([{"headType": "ubinary"}]).verdict) == "binary" \
					and _diff_have_check([{"headType": "text", "fileSize": str(DIFF_MAX_BYTES + 1)}]) \
						== {"verdict": "too big", "size": DIFF_MAX_BYTES + 1} \
					and String(_diff_have_check([{"headType": "text", "fileSize": str(DIFF_MAX_BYTES)}]).verdict) == "ok" \
					and String(_diff_have_check([]).verdict) == "unknown" \
					and String(_diff_have_check([{"desc": "x"}]).verdict) == "unknown"
			var changed_text := "******* WARNING P4PORT IDENTIFICATION HAS CHANGED! *******\n" \
					+ "It is possible that someone is intercepting your connection\n" \
					+ "to the Perforce P4PORT '127.0.0.1:2199'\n" \
					+ "If this is not a scheduled key change, then you should contact\n" \
					+ "your Perforce administrator.\n" \
					+ "The fingerprint for the mismatched key sent to your client is\n" \
					+ "0C:34:FA:41:1D:0F:DC:41:35:CD:36:86:5D:C0:43:77:9D:AD:CF:C2\n" \
					+ "To allow connection use the 'p4 trust' command.\n"
			var trust_list := "other.host:1666 11:22:33:44:55:66:77:88:99:00:11:22:33:44:55:66:77:88:99:00\r\n" \
					+ "127.0.0.1:2199 B7:E3:77:F3:D2:19:F5:68:07:6F:B2:65:7B:45:A9:DA:BE:C0:53:69\r\n"
			var trust_ok: bool = _fingerprint_change_in(changed_text) == {"address": "127.0.0.1:2199",
						"new": "0C:34:FA:41:1D:0F:DC:41:35:CD:36:86:5D:C0:43:77:9D:AD:CF:C2"} \
					and _fingerprint_change_in("Connect to server failed.\n") == {"address": "", "new": ""} \
					and _trusted_fingerprint_for(trust_list, "127.0.0.1:2199") \
						== "B7:E3:77:F3:D2:19:F5:68:07:6F:B2:65:7B:45:A9:DA:BE:C0:53:69" \
					and _trusted_fingerprint_for(trust_list, "127.0.0.1:21") == "" \
					and _trusted_fingerprint_for(trust_list, "") == ""
			var add_ok: bool = \
					_add_outcome("//game/main/q.txt#1 - opened for add\n", 0) == "added" \
					and _add_outcome("//game/main/q.txt#1 - currently opened for add\n", 0) == "added" \
					and _add_outcome("//game/main/x.log#1 - opened for add\n" \
						+ "C:/ws\\x.log - ignored file can't be added.\n", 1) == "ignored" \
					and _add_outcome("//game/main/a.txt - can't add existing file\n", 0) == "tracked" \
					and _add_outcome("//game/main/b.txt - can't add (already opened for edit)\n" \
						+ "... //game/main/b.txt - warning: add of existing file\n", 0) == "tracked" \
					and _add_outcome("", 0) == "failed" \
					and _add_outcome("Connect to server failed; check $P4PORT.\n", 1) == "failed"
			var rule_ok: bool = \
					_ignore_rule_in("C:/ws\\x.log ignored by C:/ws\\.p4ignore:1:*.log\n") \
						== "C:/ws\\.p4ignore:1:*.log" \
					and _ignore_rule_in("C:/ws\\a.txt not ignored\n") == ""
			var where_ok: bool = _where_maps({"exit_code": 0, "output": ["... depotFile //game/main/a\n... clientFile //ws/a\n... path C:/ws\\a\n\n"]}) \
					and not _where_maps({"exit_code": 0, "output": ["... depotFile //game/main/.godot/x\n... clientFile //ws/.godot/x\n... path C:/ws\\.godot\\x\n... unmap \n\n"]}) \
					and not _where_maps({"exit_code": 0, "output": ["C:/elsewhere/x - file(s) not in client view.\n"]}) \
					and not _where_maps({"exit_code": 1, "output": ["... depotFile //game/main/a\n\n"]})
			var revert_ok: bool = where_ok and \
					_revert_did_something("//game/main/a.txt#1 - was edit, reverted\n", 0) \
					and _revert_did_something("//game/main/q.txt#none - was add, abandoned\n", 0) \
					and _revert_did_something("//game/main/b.txt#1 - was move/delete, reverted\n" \
						+ "//game/main/b3.txt#none - was move/add, deleted\n", 0) \
					and not _revert_did_something("//game/main/b.txt#1 - has been moved, not reverted\n", 0) \
					and not _revert_did_something("b.txt - file(s) not opened on this client.\n", 0) \
					and not _revert_did_something("", 0) \
					and not _revert_did_something("//game/main/a.txt#1 - was edit, reverted\n", 1)
			var expired := {"exit_code": 1, "output": ["Your password has expired, please change your password.\n"]}
			var dead := {"exit_code": 1, "output": ["Perforce password (P4PASSWD) invalid or unset.\n"]}
			var pw_ok: bool = _looks_like_password_expired(expired) \
					and not _looks_like_login_error(expired) \
					and not _looks_like_password_expired(dead) \
					and _looks_like_login_error(dead) \
					and not _looks_like_password_expired({"exit_code": 0, "output": ["Your password has expired"]}) \
					and _passwd_answer("Enter old password: \r\nEnter new password: \r\n" \
						+ "Password should be at least 8 characters in length.\r\n") \
						== "Password should be at least 8 characters in length." \
					and _passwd_answer("Enter old password: \r\nEnter new password: \r\n" \
						+ "Re-enter new password: \r\nPassword updated.\r\n") == "Password updated."
			var moved_recs := [
				{"clientFile": "//ws/gfx/hero.png", "path": "C:/ws\\gfx\\hero.png", "action": "move/add",
					"fromFile": "//game/main/art/hero.png"},
				{"clientFile": "//ws/gfx/new.txt", "path": "C:/ws\\gfx\\new.txt", "action": "add"},
				{"depotFile": "//game/main/x", "action": "edit"},
				{},
			]
			var move_ok: bool = _moved_paths_in(moved_recs) \
						== PackedStringArray(["C:/ws\\gfx\\hero.png", "C:/ws\\gfx\\new.txt"]) \
					and _moved_paths_in([]).is_empty() \
					and _is_case_only_rename("res://Hero.png", "res://hero.png", true) \
					and not _is_case_only_rename("res://Hero.png", "res://hero.png", false) \
					and not _is_case_only_rename("res://Hero.png", "res://Hero.png", true) \
					and not _is_case_only_rename("res://Hero.png", "res://art/hero.png", true)
			var behind_ok: bool = _out_of_date_in([
						{"depotFile": "//d/current", "headRev": "3", "haveRev": "3", "action": "edit"},
						{"depotFile": "//d/behind", "headRev": "4", "haveRev": "3", "action": "edit"},
						{"depotFile": "//d/merge", "headRev": "4", "haveRev": "4", "action": "edit", "unresolved": ""},
						{"depotFile": "//d/new", "action": "add"},
						{"depotFile": "//d/readd", "headRev": "2", "haveRev": "none", "action": "add"},
						{"depotFile": "//d/moved", "headRev": "2", "haveRev": "1", "action": "move/add"},
						{"depotFile": "//d/gone", "headRev": "5", "haveRev": "2", "action": "delete"},
						{"desc": "try"}, {},
						{"depotFile": "//d/moved-away", "headRev": "5", "haveRev": "2", "action": "move/delete"},
					]) == ["//d/behind", "//d/merge", "//d/moved-away"] \
					and _out_of_date_in([]).is_empty()
			var all_added := _add_summary_text({"added": ["res://a", "res://b"], "ignored": [],
					"tracked": [], "failed": []})
			var mixed := _add_summary_text({"added": ["res://a"], "ignored": ["res://x.log"],
					"tracked": ["res://t1", "res://t2"], "failed": []})
			var summary_ok: bool = all_added.is_empty() \
					and mixed.begins_with("Marked 1 of 4 files for add.") \
					and mixed.contains("ignore rules (1):\n    res://x.log") \
					and mixed.contains("(2):\n    res://t1\n    res://t2") \
					and not mixed.contains("Refused")
			var waiting := _unresolved_in([
				{"clientFile": "C:/elsewhere/b.txt", "fromFile": "//d/b.txt", "resolveType": "content",
					"contentResolveType": "3waytext"},
				{"clientFile": "C:/elsewhere/a.bin", "fromFile": "//d/a.bin", "resolveType": "content",
					"contentResolveType": "2wayraw"},
				{"clientFile": "C:/elsewhere/b.txt", "fromFile": "//d/b.txt", "resolveType": "filetype"},
				{"fromFile": "//d/none"}, {},
			])
			var resolve_ok: bool = waiting.size() == 2 \
					and String(waiting[0].res_path) == "C:/elsewhere/a.bin" and bool(waiting[0].binary) \
					and not bool(waiting[0].special) \
					and String(waiting[1].res_path) == "C:/elsewhere/b.txt" and not bool(waiting[1].binary) \
					and bool(waiting[1].special) \
					and _resolve_outcome("C:/ws\\a.txt - merging //d/a.txt#2\nDiff chunks: 1 yours + 1 theirs + 0 both + 0 conflicting\n//ws/a.txt - merge from //d/a.txt\n", 0) == "combined" \
					and _resolve_outcome("C:/ws\\a.txt - merging //d/a.txt#2\nDiff chunks: 0 yours + 0 theirs + 0 both + 1 conflicting\n//ws/a.txt - resolve skipped.\n", 0) == "skipped" \
					and _resolve_outcome("C:/ws\\a.txt - vs //d/a.txt#2\n//ws/a.txt - ignored //d/a.txt\n", 0) == "mine" \
					and _resolve_outcome("C:/ws\\a.bin - vs //d/a.bin#2\n//ws/a.bin - copy from //d/a.bin\n", 0) == "theirs" \
					and _resolve_outcome("//ws/a.txt - merge from //d/a.txt\n", 1) == "failed" \
					and _resolve_outcome("No file(s) to resolve.\n", 0) == "failed" \
					and _is_godot_text_resource("res://a/Main.TSCN") and not _is_godot_text_resource("res://a.gd")
			var names_ok: bool = _ignore_file_names("", true) == PackedStringArray([".p4ignore"]) \
					and _ignore_file_names("P4IGNORE=.p4ignore\n", true) == PackedStringArray([".p4ignore"]) \
					and _ignore_file_names("P4IGNORE=p4ignore.txt;.p4ignore (set)\r\n", true) \
						== PackedStringArray(["p4ignore.txt", ".p4ignore"]) \
					and _ignore_file_names("P4IGNORE=C:\\Users\\me\\ignore.txt (config 'C:\\x\\.p4config')\n", true) \
						== PackedStringArray(["C:\\Users\\me\\ignore.txt"]) \
					and _ignore_file_names("P4IGNORE=.p4ignore:.gitignore\n", false) \
						== PackedStringArray([".p4ignore", ".gitignore"])
			_log("[selftest] diff=%s add=%s rule=%s revert=%s password=%s move=%s behind=%s add-summary=%s ignore-names=%s resolve=%s trust=%s" \
					% [diff_ok, add_ok, rule_ok, revert_ok, pw_ok, move_ok, behind_ok, summary_ok, names_ok, resolve_ok, trust_ok])
			_log("[selftest] %s: p4-answers" % ("PASS" if diff_ok and add_ok and rule_ok \
					and revert_ok and pw_ok and move_ok and behind_ok and summary_ok and names_ok \
					and resolve_ok and trust_ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-file-actions-live":
			# Live and DESTRUCTIVE (two real submits; use a throwaway server):
			# Diff vs Depot, Mark for Add and Revert on the files where p4 answers
			# with a refusal and exit 0. Needs "*.log" in the P4IGNORE file and
			# nothing opened.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: file-actions-live - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			var dir := "res://p4g_file_actions_test"
			var dir_g := ProjectSettings.globalize_path(dir)
			DirAccess.make_dir_recursive_absolute(dir_g)
			for n: String in ["plain.txt", "moved.txt", "ignored.log", "fresh.txt"]:
				var fw := FileAccess.open(dir_g.path_join(n), FileAccess.WRITE)
				fw.store_string("one\ntwo\n")
				fw.close()
			if not await _p4_path_ignored(dir_g.path_join("ignored.log")):
				_log("[selftest] FAIL: file-actions-live - '*.log' isn't ignored here; add it to the P4IGNORE file")
				get_tree().quit()
				return
			await _p4_exec_logged(["add", dir_g.path_join("plain.txt"), dir_g.path_join("moved.txt")])
			await _submit_changelist("default", [], "P4Godot selftest: file actions")
			var ok := _last_submit_outcome == "submitted"

			# Diff: changed on disk, not checked out.
			var plain := dir.path_join("plain.txt")
			var plain_g := dir_g.path_join("plain.txt")
			_set_file_writable(plain_g, true)
			var fw2 := FileAccess.open(plain_g, FileAccess.WRITE)
			fw2.store_string("one\nTWO\n")
			fw2.close()
			var bare := await _p4_exec(["diff", "-dul", plain_g])
			var control: bool = String(bare.output[0]).contains("not opened on this client")
			_selftest_shown.clear()
			diff_window.hide()
			await _diff_path(plain)
			var diff_ok: bool = diff_window.visible and _selftest_shown.is_empty() \
					and not _diff_change_blocks.is_empty()
			diff_window.hide()
			_log("[selftest] diff of a changed, unopened file: window=%s (without -f p4 says 'not opened': %s)" \
					% [diff_ok, control])
			await _p4_exec(["sync", "-f", plain_g])
			_selftest_shown.clear()
			await _diff_path(plain)
			var same_ok: bool = not diff_window.visible and _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("is identical")
			_selftest_shown.clear()
			await _diff_path(dir.path_join("fresh.txt"))
			var new_ok: bool = not diff_window.visible and _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("isn't on the Perforce server yet")
			_log("[selftest] diff of an unchanged file says identical: %s; of an untracked file says not on server: %s" \
					% [same_ok, new_ok])
			ok = ok and control and diff_ok and same_ok and new_ok

			# Mark for Add: ignored, already tracked, and a plain new file.
			_selftest_shown.clear()
			await _add_path(dir.path_join("ignored.log"))
			var ign_ok: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("ignore rules") \
					and String(_selftest_shown[0]).contains("*.log") \
					and _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty()
			_selftest_shown.clear()
			await _add_path(plain)
			var tracked_ok: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("already in Perforce")
			_selftest_shown.clear()
			await _add_path(dir.path_join("fresh.txt"))
			var fresh_ok: bool = _selftest_shown.is_empty() \
					and String((await _fetch_fstat_record(dir.path_join("fresh.txt"))).get("action", "")) == "add"
			_log("[selftest] add: ignored file explained=%s tracked file explained=%s new file added quietly=%s" \
					% [ign_ok, tracked_ok, fresh_ok])
			ok = ok and ign_ok and tracked_ok and fresh_ok

			# Revert: an add, then a move from each half, then nothing to revert.
			_selftest_shown.clear()
			await _revert_path(dir.path_join("fresh.txt"))
			var add_rev_ok: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).begins_with("Throw away your changes") \
					and _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty() \
					and FileAccess.file_exists(dir_g.path_join("fresh.txt"))
			var move_ok := true
			for half: String in ["moved.txt", "moved2.txt"]:
				await _p4_exec_logged(["edit", dir_g.path_join("moved.txt")])
				await _p4_exec_logged(["move", dir_g.path_join("moved.txt"), dir_g.path_join("moved2.txt")])
				var bare_rev := await _p4_exec(["revert", dir_g.path_join("moved.txt")])
				var refused: bool = String(bare_rev.output[0]).contains("has been moved, not reverted") \
						and _parse_ztag(await _p4_exec(["-ztag", "opened"])).size() == 2
				_selftest_shown.clear()
				await _revert_path(dir.path_join(half))
				var undone: bool = _selftest_shown.size() == 1 \
						and String(_selftest_shown[0]).begins_with("Undo the move of '%s' to '%s'?" \
							% [dir.path_join("moved.txt"), dir.path_join("moved2.txt")]) \
						and _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty() \
						and FileAccess.file_exists(dir_g.path_join("moved.txt")) \
						and not FileAccess.file_exists(dir_g.path_join("moved2.txt"))
				_log("[selftest] revert a move through %s: undone=%s (plain p4 revert of the old half refuses: %s)" \
						% [half, undone, refused])
				move_ok = move_ok and undone and refused
			# Revert on a file that isn't checked out: nothing to do when it
			# matches, and an offer to put it back when it was changed or deleted.
			_selftest_shown.clear()
			await _revert_path(plain)
			var idle_ok: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("nothing to throw away")
			_set_file_writable(plain_g, true)
			var fw3 := FileAccess.open(plain_g, FileAccess.WRITE)
			fw3.store_string("scribbled\n")
			fw3.close()
			_selftest_shown.clear()
			await _revert_path(plain)
			var restored: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("changed on your computer without being checked out") \
					and FileAccess.get_file_as_string(plain_g).replace("\r", "") == "one\ntwo\n"
			_set_file_writable(plain_g, true)
			DirAccess.remove_absolute(plain_g)
			_selftest_shown.clear()
			await _diff_path(plain)
			var gone_diff_ok: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("isn't on your computer any more")
			_selftest_shown.clear()
			await _revert_path(plain)
			var undeleted: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("was deleted from your computer") \
					and FileAccess.file_exists(plain_g)
			_log("[selftest] revert: add=%s moves=%s unopened: same explained=%s changed put back=%s deleted put back=%s; diff of a deleted file explained=%s" \
					% [add_rev_ok, move_ok, idle_ok, restored, undeleted, gone_diff_ok])
			ok = ok and add_rev_ok and move_ok and idle_ok and restored and undeleted and gone_diff_ok

			# An external diff tool (P4DIFF) must not turn a change into "identical".
			_set_file_writable(plain_g, true)
			var fw4 := FileAccess.open(plain_g, FileAccess.WRITE)
			fw4.store_string("one\nTWO\n")
			fw4.close()
			OS.set_environment("P4DIFF", "echo")
			var fooled := await _p4_exec(["diff", "-f", "-dul", plain_g])
			_selftest_shown.clear()
			diff_window.hide()
			await _diff_path(plain)
			var tool_ok: bool = diff_window.visible and _selftest_shown.is_empty() \
					and _diff_verdict(String(fooled.output[0]), int(fooled.exit_code)) == "same"
			diff_window.hide()
			OS.unset_environment("P4DIFF")
			await _p4_exec(["sync", "-f", plain_g])
			_log("[selftest] diff with P4DIFF set still shows the change: %s" % tool_ok)
			ok = ok and tool_ok

			# Mark for Add on several files reports once.
			_selftest_shown.clear()
			await _ctx_add(PackedStringArray([dir.path_join("fresh.txt"), dir.path_join("ignored.log"), plain]))
			var many_ok: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).begins_with("Marked 1 of 3 files for add.")
			await _p4_exec_logged(["revert", dir_g.path_join("fresh.txt")])
			_log("[selftest] add of three files gives one summary: %s" % many_ok)
			ok = ok and many_ok

			# An asset moved with its .import, then undone: both go back.
			for n: String in ["pic.dat", "pic.dat.import"]:
				var fwp := FileAccess.open(dir_g.path_join(n), FileAccess.WRITE)
				fwp.store_string(n + "\n")
				fwp.close()
			await _p4_exec_logged(["add", dir_g.path_join("pic.dat"), dir_g.path_join("pic.dat.import")])
			await _submit_changelist("default", [], "P4Godot selftest: file actions asset")
			for n: String in ["pic.dat", "pic.dat.import"]:
				DirAccess.rename_absolute(dir_g.path_join(n), dir_g.path_join(n.replace("pic", "pic2")))
			await _handle_fs_move(dir.path_join("pic.dat"), dir.path_join("pic2.dat"), false)
			var both_moved: bool = _parse_ztag(await _p4_exec(["-ztag", "opened"])).size() == 4
			_selftest_shown.clear()
			await _revert_path(dir.path_join("pic.dat"))
			var side_ok: bool = both_moved and _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("pic.dat.import, which Godot keeps beside it") \
					and _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty() \
					and FileAccess.file_exists(dir_g.path_join("pic.dat.import")) \
					and not FileAccess.file_exists(dir_g.path_join("pic2.dat.import"))
			_log("[selftest] undo of a moved asset takes its .import back too: %s" % side_ok)
			ok = ok and side_ok

			# Undoing a move must not overwrite a new file at the old path.
			DirAccess.rename_absolute(dir_g.path_join("moved.txt"), dir_g.path_join("moved4.txt"))
			await _handle_fs_move(dir.path_join("moved.txt"), dir.path_join("moved4.txt"), false)
			var squat := FileAccess.open(dir_g.path_join("moved.txt"), FileAccess.WRITE)
			squat.store_string("a new file with the old name\n")
			squat.close()
			_selftest_shown.clear()
			await _revert_path(dir.path_join("moved4.txt"))
			var kept: bool = _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("Undoing the move would overwrite it") \
					and FileAccess.get_file_as_string(dir_g.path_join("moved.txt")) == "a new file with the old name\n" \
					and _parse_ztag(await _p4_exec(["-ztag", "opened"])).size() == 2
			DirAccess.remove_absolute(dir_g.path_join("moved.txt"))
			await _revert_path(dir.path_join("moved4.txt"))
			kept = kept and _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty()
			_log("[selftest] undo of a move refuses to overwrite a new file at the old path: %s" % kept)
			ok = ok and kept

			# Deleting a file that was moved: the old path ends up opened for
			# delete and nothing comes back on disk.
			DirAccess.rename_absolute(dir_g.path_join("moved.txt"), dir_g.path_join("moved3.txt"))
			await _handle_fs_move(dir.path_join("moved.txt"), dir.path_join("moved3.txt"), false)
			DirAccess.remove_absolute(dir_g.path_join("moved3.txt"))
			await _handle_fs_delete(dir.path_join("moved3.txt"), false)
			var now_open := _parse_ztag(await _p4_exec(["-ztag", "opened"]))
			var del_ok: bool = now_open.size() == 1 \
					and String(now_open[0].get("action", "")) == "delete" \
					and String(now_open[0].get("depotFile", "")).ends_with("/moved.txt") \
					and not FileAccess.file_exists(dir_g.path_join("moved.txt")) \
					and not FileAccess.file_exists(dir_g.path_join("moved3.txt"))
			_log("[selftest] delete of a moved file: old path opened for delete, nothing restored=%s" % del_ok)
			ok = ok and del_ok
			await _p4_exec_logged(["revert", dir_g.path_join("moved.txt")])

			await _p4_exec_logged(["delete", plain_g, dir_g.path_join("moved.txt"),
					dir_g.path_join("pic.dat"), dir_g.path_join("pic.dat.import")])
			await _submit_changelist("default", [], "P4Godot selftest: file actions cleanup")
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			for n: String in ["ignored.log", "fresh.txt"]:
				DirAccess.remove_absolute(dir_g.path_join(n))
			DirAccess.remove_absolute(dir_g)
			_log("[selftest] opened-after=%d" % left)
			_log("[selftest] %s: file-actions-live" % ("PASS" if ok and left == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-ignore-check-live":
			# Live (no submits): the startup check that .godot/ is ignored.
			# Needs a tracked res://.p4ignore holding the line ".godot/", the
			# P4IGNORE environment variable set to .p4ignore, and nothing opened.
			var ig_g := ProjectSettings.globalize_path("res://.p4ignore")
			var original := FileAccess.get_file_as_string(ig_g)
			if not original.contains(".godot/") or OS.get_environment("P4IGNORE") != ".p4ignore" \
					or not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: ignore-check-live - needs '.godot/' in a tracked .p4ignore, P4IGNORE=.p4ignore, nothing opened")
				get_tree().quit()
				return
			_selftest_shown.clear()
			var fine: bool = await _check_godot_cache_ignored(true) == "ignored" and _selftest_shown.is_empty()

			# The rule is missing: declined leaves the file alone, accepted adds it.
			await _do_checkout("res://.p4ignore")
			var stripped := FileAccess.open(ig_g, FileAccess.WRITE)
			stripped.store_string(original.replace(".godot/", "# rule removed by the selftest"))
			stripped.close()
			await _p4_exec_logged(["revert", "-k", ig_g])
			_set_file_writable(ig_g, false)
			_selftest_auto_answer = "cancel"
			var declined: bool = await _check_godot_cache_ignored(true) == "declined" \
					and not FileAccess.get_file_as_string(ig_g).contains(".godot/\n") \
					and _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty()
			_selftest_auto_answer = "confirm"
			_selftest_shown.clear()
			var added: bool = await _check_godot_cache_ignored(true) == "added" \
					and _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("Add the line " + char(96) + ".godot/" + char(96) + " to '.p4ignore' now?") \
					and FileAccess.get_file_as_string(ig_g).ends_with(".godot/\n") \
					and await _p4_path_ignored(ProjectSettings.globalize_path("res://.godot/editor/x"))
			var opened_edit := _parse_ztag(await _p4_exec(["-ztag", "opened"]))
			added = added and opened_edit.size() == 1 and String(opened_edit[0].get("action", "")) == "edit"
			await _p4_exec_logged(["revert", ig_g])
			_log("[selftest] rule present: quiet=%s; rule missing: declined leaves it=%s, accepted checks out and adds it=%s" \
					% [fine, declined, added])

			# P4IGNORE names another file: the project's .p4ignore is out of
			# force, and the rule goes into the file that is read.
			OS.set_environment("P4IGNORE", "p4g-other-ignore.txt")
			var other_g := ProjectSettings.globalize_path("res://p4g-other-ignore.txt")
			_selftest_shown.clear()
			var replaced: bool = await _check_godot_cache_ignored(true) == "added" \
					and _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("to 'p4g-other-ignore.txt' now?") \
					and String(_selftest_shown[0]).contains("aren't applied here") \
					and FileAccess.get_file_as_string(other_g).ends_with(".godot/\n")
			var opened_add := _parse_ztag(await _p4_exec(["-ztag", "opened"]))
			replaced = replaced and opened_add.size() == 1 and String(opened_add[0].get("action", "")) == "add"
			await _p4_exec_logged(["revert", other_g])
			DirAccess.remove_absolute(other_g)
			OS.set_environment("P4IGNORE", ".p4ignore")
			_log("[selftest] P4IGNORE names another file: said so and added the rule there=%s" % replaced)
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			var restored: bool = FileAccess.get_file_as_string(ig_g).replace("\r", "") == original.replace("\r", "")
			_log("[selftest] opened-after=%d .p4ignore-restored=%s" % [left, restored])
			_log("[selftest] %s: ignore-check-live" % ("PASS" if fine and declined and added \
					and replaced and restored and left == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-resolve-live":
			# Live and DESTRUCTIVE (use tools/run-live-tests.sh: it needs the
			# second user "mate" with workspace mate-ws at $P4TEST_MATE_WS).
			# A teammate submits newer versions of three files checked out
			# here: one that combines cleanly, one where both changed the same
			# line, one binary. Submit must lead into resolving them, and each
			# answer must leave the content it promised.
			_selftest_auto_answer = "confirm"
			var mate_dir := OS.get_environment("P4TEST_MATE_WS")
			if mate_dir.is_empty() or not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: resolve-live - needs P4TEST_MATE_WS and nothing opened")
				get_tree().quit()
				return
			var r_names := ["p4g_resolve_a_clean.txt", "p4g_resolve_b_clash.txt", "p4g_resolve_c_pic.bin"]
			var eight := "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"
			var r_add := PackedStringArray(["add"])
			for n: String in r_names:
				var g := ProjectSettings.globalize_path("res://" + n)
				var fw := FileAccess.open(g, FileAccess.WRITE)
				fw.store_string(eight if n.ends_with(".txt") else "binary base")
				fw.close()
				r_add.append(g)
			await _p4_exec_logged(r_add)
			await _p4_exec_logged(["reopen", "-t", "binary", ProjectSettings.globalize_path("res://" + r_names[2])])
			await _submit_changelist("default", [], "P4Godot selftest: resolve seed")
			var mate := PackedStringArray(["-u", "mate", "-c", "mate-ws"])
			await _p4_exec(mate + PackedStringArray(["sync", "//mate-ws/..."]))
			var mate_text := [eight.replace("l1\n", "l1 mate\n"), eight.replace("l4\n", "l4 mate\n"), "binary from mate"]
			var mine_text := [eight.replace("l8\n", "l8 dev\n"), eight.replace("l4\n", "l4 dev\n"), "binary from dev"]
			var mate_args := PackedStringArray(["submit", "-d", "mate got there first"])
			for i in 3:
				var theirs := mate_dir.path_join(r_names[i])
				await _p4_exec(mate + PackedStringArray(["edit", theirs]))
				var fm := FileAccess.open(theirs, FileAccess.WRITE)
				fm.store_string(mate_text[i])
				fm.close()
				# Checked out here BEFORE the teammate submits: this workspace's
				# revision is then the old one.
				await _do_checkout("res://" + r_names[i])
				var fd := FileAccess.open(ProjectSettings.globalize_path("res://" + r_names[i]), FileAccess.WRITE)
				fd.store_string(mine_text[i])
				fd.close()
			var mate_sub := await _p4_exec(mate + mate_args)
			var staged: bool = String(mate_sub.output[0]).contains("submitted")

			# Submit -> "Combine Now" -> a.clean: combine. b.clash: combine is
			# refused, then keep mine. c.pic: no combine offered; take theirs.
			_selftest_option_picks = [0, 0, 0, 1]
			_selftest_shown.clear()
			_last_submit_outcome = ""
			await _submit_changelist("default", [], "P4Godot selftest: not sent, resolved instead")
			var read := func(n: String) -> String:
				return FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://" + n)).replace("\r", "")
			var a_text: String = read.call(r_names[0])
			var combined_ok: bool = a_text.contains("l1 mate\n") and a_text.contains("l8 dev\n")
			var mine_ok: bool = read.call(r_names[1]) == mine_text[1]
			var theirs_ok: bool = read.call(r_names[2]) == mate_text[2]
			var asked := "\n".join(_selftest_shown)
			var told_ok: bool = asked.contains("Perforce won't take this submit yet. These 3 files") \
					and asked.contains("changed the same lines of 'res://%s'" % r_names[1]) \
					and asked.contains("This kind of file can't be combined") \
					and asked.contains("take your teammate's version")
			var none_left: bool = _unresolved_in(_parse_ztag(await _p4_exec(["-ztag", "resolve", "-n"]))).is_empty() \
					and _selftest_option_picks.is_empty() and _last_submit_outcome == ""
			_log("[selftest] staged=%s combined keeps both=%s clash kept mine=%s binary took theirs=%s dialogs=%s nothing left=%s" \
					% [staged, combined_ok, mine_ok, theirs_ok, told_ok, none_left])

			# The panel's model marks a waiting file and stops marking a resolved one.
			await _do_checkout("res://main.gd")
			var model: Dictionary = await _query_pending_model()
			var marked := 0
			for cl in model.changelists:
				for mf in cl.files:
					if bool(mf.unresolved):
						marked += 1
			await _p4_exec_logged(["revert", ProjectSettings.globalize_path("res://main.gd")])
			await _submit_changelist("default", [], "P4Godot selftest: resolved and submitted")
			var sent: bool = _last_submit_outcome == "submitted"
			_log("[selftest] panel marks no resolved file as waiting=%s; submit after resolving went through=%s" \
					% [marked == 0, sent])
			var r_del := PackedStringArray(["delete"])
			for n: String in r_names:
				r_del.append(ProjectSettings.globalize_path("res://" + n))
			await _p4_exec_logged(r_del)
			await _submit_changelist("default", [], "P4Godot selftest: resolve cleanup")
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] opened-after=%d" % left)
			_log("[selftest] %s: resolve-live" % ("PASS" if staged and combined_ok and mine_ok \
					and theirs_ok and told_ok and none_left and marked == 0 and sent and left == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-submit-behind-live":
			# Live and DESTRUCTIVE (use tools/run-live-tests.sh: it needs the
			# second user "mate" with workspace mate-ws at $P4TEST_MATE_WS).
			# A teammate submits a newer version of a file this workspace has
			# checked out; Submit must name the file and send nothing.
			_selftest_auto_answer = "confirm"
			var mate_ws := OS.get_environment("P4TEST_MATE_WS")
			if mate_ws.is_empty() or not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: submit-behind-live - needs P4TEST_MATE_WS and nothing opened")
				get_tree().quit()
				return
			var names := ["p4godot_behind_shared.txt", "p4godot_behind_mine.txt"]
			for n: String in names:
				var fw := FileAccess.open(ProjectSettings.globalize_path("res://" + n), FileAccess.WRITE)
				fw.store_string("first\n")
				fw.close()
				await _p4_exec_logged(["add", ProjectSettings.globalize_path("res://" + n)])
			await _submit_changelist("default", [], "P4Godot selftest: behind seed")
			var as_mate := PackedStringArray(["-u", "mate", "-c", "mate-ws"])
			var theirs := mate_ws.path_join(names[0])
			await _p4_exec(as_mate + PackedStringArray(["sync", "//mate-ws/..."]))
			await _p4_exec(as_mate + PackedStringArray(["edit", theirs]))
			var fm := FileAccess.open(theirs, FileAccess.WRITE)
			fm.store_string("first\nmate\n")
			fm.close()
			var mate_sub := await _p4_exec(as_mate + PackedStringArray(["submit", "-d", "mate got there first", theirs]))
			var staged: bool = String(mate_sub.output[0]).contains("submitted")
			for n: String in names:
				await _do_checkout("res://" + n)
			var changes_before := _parse_ztag(await _p4_exec(["-ztag", "changes", "-s", "pending", "-c", _p4_client])).size()
			_selftest_shown.clear()
			_last_submit_outcome = ""
			_selftest_auto_answer = "cancel" # "Not Now" to combining; resolve-live says yes
			await _submit_changelist("default", [], "P4Godot selftest: must not be sent")
			_selftest_auto_answer = "confirm"
			var changes_after := _parse_ztag(await _p4_exec(["-ztag", "changes", "-s", "pending", "-c", _p4_client])).size()
			var told := "" if _selftest_shown.is_empty() else String(_selftest_shown[0])
			var ok: bool = staged and _selftest_shown.size() == 1 \
					and told.begins_with("Perforce won't take this submit yet. This file changed") \
					and told.contains(names[0]) and not told.contains(names[1]) \
					and _last_submit_outcome == "" and changes_before == changes_after \
					and _parse_ztag(await _p4_exec(["-ztag", "opened"])).size() == 2
			_log("[selftest] teammate submitted first=%s; submit refused up front naming only that file=%s; no changelist created=%s" \
					% [staged, _selftest_shown.size() == 1 and told.contains(names[0]) and not told.contains(names[1]),
					changes_before == changes_after])
			# Once their version is fetched, the panel marks that file - and only
			# that file - as waiting, and its menu offers Resolve.
			await _safe_sync(PackedStringArray([_project_scope()]))
			var behind_model: Dictionary = await _query_pending_model()
			var marked: Array = []
			for cl in behind_model.changelists:
				for mf in cl.files:
					if bool(mf.unresolved):
						marked.append(String(mf.res_path))
			_populate_context_menu({"type": "file", "res_path": "res://" + names[0],
					"change": "default", "unresolved": true})
			var with_item := _selftest_menu_labels()
			_populate_context_menu({"type": "file", "res_path": "res://" + names[1],
					"change": "default", "unresolved": false})
			var marks_ok: bool = marked == ["res://" + names[0]] \
					and with_item.begins_with("Resolve... | Open") \
					and not _selftest_menu_labels().contains("Resolve")
			_log("[selftest] panel marks only the file that needs resolving, and offers Resolve on it: %s" % marks_ok)
			ok = ok and marks_ok
			for n: String in names:
				await _p4_exec_logged(["revert", ProjectSettings.globalize_path("res://" + n)])
			await _p4_exec(["sync", "-s", _project_scope()])
			for n: String in names:
				await _p4_exec_logged(["delete", ProjectSettings.globalize_path("res://" + n)])
			await _submit_changelist("default", [], "P4Godot selftest: behind cleanup")
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] opened-after=%d" % left)
			_log("[selftest] %s: submit-behind-live" % ("PASS" if ok and left == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-moves-live":
			# Live and DESTRUCTIVE (three real submits; use a throwaway server):
			# moves recorded through _handle_fs_move the way the FileSystem dock
			# reports them - after the files have already moved on disk. Covers
			# the case content-matching loses (a binary moved and changed), an
			# asset with its .import, a file only opened for add, a folder, and a
			# rename that only changes case. Needs nothing opened.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: moves-live - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			await _probe_connection()
			var dir := "res://p4g_moves_test"
			var dir_g := ProjectSettings.globalize_path(dir)
			DirAccess.make_dir_recursive_absolute(dir_g.path_join("art/sub"))
			var noise := PackedByteArray()
			noise.resize(4096)
			for i in range(0, noise.size(), 8):
				noise.encode_s64(i, randi() << 32 | randi())
			var seeded := {"blob.bin": noise, "art/hero.png": "png\n".to_utf8_buffer(),
					"art/hero.png.import": "import\n".to_utf8_buffer(),
					"art/sub/deep.txt": "deep\n".to_utf8_buffer(), "Name.txt": "name\n".to_utf8_buffer()}
			var add_args := PackedStringArray(["add"])
			for n: String in seeded:
				var fw := FileAccess.open(dir_g.path_join(n), FileAccess.WRITE)
				fw.store_buffer(seeded[n])
				fw.close()
				add_args.append(dir_g.path_join(n))
			await _p4_exec_logged(add_args)
			await _submit_changelist("default", [], "P4Godot selftest: moves seed")
			var ok := _last_submit_outcome == "submitted"

			# 1. A binary moved AND changed. Content matching can't pair it.
			var blob_old := dir_g.path_join("blob.bin")
			var blob_new := dir_g.path_join("blob_moved.bin")
			DirAccess.rename_absolute(blob_old, blob_new)
			_set_file_writable(blob_new, true)
			var fa := FileAccess.open(blob_new, FileAccess.READ_WRITE)
			fa.seek_end()
			fa.store_buffer(noise.slice(0, 64))
			fa.close()
			_set_file_writable(blob_new, false)
			var guess := await _p4_exec(["reconcile", "-n", "-M", blob_old, blob_new])
			var guess_lost: bool = not String(guess.output[0]).contains("move/add")
			await _handle_fs_move(dir.path_join("blob.bin"), dir.path_join("blob_moved.bin"), false)
			var blob_rec := await _fetch_fstat_record(dir.path_join("blob_moved.bin"))
			var blob_ok: bool = String(blob_rec.get("action", "")) == "move/add" \
					and String(blob_rec.get("movedFile", "")).ends_with("/blob.bin") \
					and not _selftest_is_read_only(blob_new)
			_log("[selftest] moved+changed binary: move/add=%s writable=%s (reconcile -M would have cut its history: %s)" \
					% [String(blob_rec.get("action", "")) == "move/add", not _selftest_is_read_only(blob_new), guess_lost])
			ok = ok and blob_ok and guess_lost

			# 2. An asset and its .import, both read-only and unopened.
			DirAccess.rename_absolute(dir_g.path_join("art/hero.png"), dir_g.path_join("art/hero2.png"))
			DirAccess.rename_absolute(dir_g.path_join("art/hero.png.import"), dir_g.path_join("art/hero2.png.import"))
			await _handle_fs_move(dir.path_join("art/hero.png"), dir.path_join("art/hero2.png"), false)
			var side_rec := await _fetch_fstat_record(dir.path_join("art/hero2.png.import"))
			var asset_ok: bool = String((await _fetch_fstat_record(dir.path_join("art/hero2.png"))).get("action", "")) == "move/add" \
					and String(side_rec.get("action", "")) == "move/add" \
					and not _selftest_is_read_only(dir_g.path_join("art/hero2.png.import"))
			_log("[selftest] asset with .import: both move/add and writable=%s" % asset_ok)
			ok = ok and asset_ok

			# 3. A file only opened for add becomes an add at the new path.
			var fresh := FileAccess.open(dir_g.path_join("fresh.txt"), FileAccess.WRITE)
			fresh.store_string("fresh\n")
			fresh.close()
			await _p4_exec_logged(["add", dir_g.path_join("fresh.txt")])
			DirAccess.rename_absolute(dir_g.path_join("fresh.txt"), dir_g.path_join("fresh2.txt"))
			await _handle_fs_move(dir.path_join("fresh.txt"), dir.path_join("fresh2.txt"), false)
			var add_ok: bool = String((await _fetch_fstat_record(dir.path_join("fresh2.txt"))).get("action", "")) == "add" \
					and (await _fetch_fstat_record(dir.path_join("fresh.txt"))).get("action", "") == ""
			_log("[selftest] file opened for add: plain add at the new path=%s" % add_ok)
			ok = ok and add_ok

			# 4. A folder, with a moved file, an untracked file and a subfolder.
			var stray := FileAccess.open(dir_g.path_join("art/untracked.txt"), FileAccess.WRITE)
			stray.store_string("stray\n")
			stray.close()
			DirAccess.rename_absolute(dir_g.path_join("art"), dir_g.path_join("gfx"))
			await _handle_fs_move(dir.path_join("art"), dir.path_join("gfx"), true)
			var deep := await _fetch_fstat_record(dir.path_join("gfx/sub/deep.txt"))
			var chained := await _fetch_fstat_record(dir.path_join("gfx/hero2.png"))
			var folder_ok: bool = String(deep.get("action", "")) == "move/add" \
					and String(chained.get("action", "")) == "move/add" \
					and String(chained.get("movedFile", "")).ends_with("/art/hero.png") \
					and not (await _fetch_fstat_record(dir.path_join("gfx/untracked.txt"))).has("action") \
					and not _selftest_is_read_only(dir_g.path_join("gfx/sub/deep.txt"))
			_log("[selftest] folder: files move/add, earlier move chained to the original=%s" % folder_ok)
			ok = ok and folder_ok

			# 4b. A file a teammate holds an exclusive lock on can't be moved.
			# Nothing may be left opened for it, and the user must be told.
			var mate_ws := OS.get_environment("P4TEST_MATE_WS")
			var lock_ok := true
			if mate_ws.is_empty():
				_log("[selftest] exclusive-lock move: SKIPPED (no P4TEST_MATE_WS; run through tools/run-live-tests.sh)")
			else:
				var lock_g := dir_g.path_join("locked.txt")
				var fl := FileAccess.open(lock_g, FileAccess.WRITE)
				fl.store_string("locked\n")
				fl.close()
				await _p4_exec_logged(["add", "-t", "text+l", lock_g])
				var lock_change := await _create_selftest_change("P4Godot selftest: lock seed", lock_g)
				await _p4_exec_logged(["submit", "-c", lock_change])
				var as_mate := PackedStringArray(["-u", "mate", "-c", "mate-ws"])
				var mate_lock := mate_ws.path_join("p4g_moves_test/locked.txt")
				await _p4_exec(as_mate + PackedStringArray(["sync", "//mate-ws/..."]))
				await _p4_exec(as_mate + PackedStringArray(["edit", mate_lock]))
				var open_before := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
				DirAccess.rename_absolute(lock_g, dir_g.path_join("locked2.txt"))
				_selftest_shown.clear()
				await _handle_fs_move(dir.path_join("locked.txt"), dir.path_join("locked2.txt"), false)
				var open_after := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
				lock_ok = open_before == open_after and _selftest_shown.size() == 2 \
						and String(_selftest_shown[1]).begins_with("Perforce didn't record the move of") \
						and String(_selftest_shown[1]).contains("exclusive lock")
				DirAccess.rename_absolute(dir_g.path_join("locked2.txt"), lock_g)
				await _p4_exec(as_mate + PackedStringArray(["revert", mate_lock]))
				_log("[selftest] exclusively locked file: move refused, explained, nothing left opened=%s" % lock_ok)
			ok = ok and lock_ok

			# 4c. A file in a numbered changelist moves inside that changelist,
			# and its unopened sidecar joins it there.
			for n: String in ["num.dat", "num.dat.import"]:
				var fn := FileAccess.open(dir_g.path_join(n), FileAccess.WRITE)
				fn.store_string(n + "\n")
				fn.close()
			await _p4_exec_logged(["add", dir_g.path_join("num.dat"), dir_g.path_join("num.dat.import")])
			var seed_change := await _create_selftest_change("P4Godot selftest: numbered seed", dir_g.path_join("num.dat"))
			await _p4_exec_logged(["reopen", "-c", seed_change, dir_g.path_join("num.dat.import")])
			await _p4_exec_logged(["submit", "-c", seed_change])
			var work_change := await _create_selftest_change("P4Godot selftest: numbered work", "")
			await _do_checkout(dir.path_join("num.dat"), work_change)
			for n: String in ["num.dat", "num.dat.import"]:
				DirAccess.rename_absolute(dir_g.path_join(n), dir_g.path_join(n.replace("num", "num2")))
			await _handle_fs_move(dir.path_join("num.dat"), dir.path_join("num2.dat"), false)
			var in_change := _parse_ztag(await _p4_exec(["-ztag", "opened", "-c", work_change]))
			var numbered_ok: bool = in_change.size() == 4
			_log("[selftest] move inside changelist %s: both halves of the file and of its sidecar stay there=%s (%d of 4)" \
					% [work_change, numbered_ok, in_change.size()])
			ok = ok and numbered_ok
			await _p4_exec_logged(["reopen", "-c", "default", _as_recursive(dir_g)])
			await _p4_exec_logged(["change", "-d", work_change])

			# 5. A rename that only changes case is refused with an explanation.
			var folds := _server_folds_case
			DirAccess.rename_absolute(dir_g.path_join("Name.txt"), dir_g.path_join("name.txt"))
			_selftest_shown.clear()
			var before := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			await _handle_fs_move(dir.path_join("Name.txt"), dir.path_join("name.txt"), false)
			var after := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			var case_ok: bool = not folds or (before == after and _selftest_shown.size() == 1 \
					and String(_selftest_shown[0]).contains("differ only in capital letters"))
			_log("[selftest] case-only rename (server folds case=%s): refused and explained=%s" % [folds, case_ok])
			ok = ok and case_ok
			DirAccess.rename_absolute(dir_g.path_join("name.txt"), dir_g.path_join("Name.txt"))
			if not folds:
				await _p4_exec_logged(["revert", dir_g.path_join("Name.txt"), dir_g.path_join("name.txt")])

			await _submit_changelist("default", [], "P4Godot selftest: moves")
			var log_text := await _p4_exec(["filelog", "-m1", blob_new])
			var history_ok: bool = _last_submit_outcome == "submitted" \
					and String(log_text.output[0]).contains("moved from")
			_log("[selftest] after submit the binary's history says 'moved from': %s" % history_ok)
			ok = ok and history_ok
			await _p4_exec_logged(["delete", _as_recursive(dir_g)])
			await _submit_changelist("default", [], "P4Godot selftest: moves cleanup")
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			DirAccess.remove_absolute(dir_g.path_join("gfx/untracked.txt"))
			_log("[selftest] opened-after=%d" % left)
			_log("[selftest] %s: moves-live" % ("PASS" if ok and left == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-password-expired-live="):
			# Live: --p4-selftest-password-expired-live=<current>,<new>. Run it
			# after an admin ran "p4 admin resetpassword -u <this user>". Checks
			# that the first refused command leads to the change-password
			# prompts, that a wrong current password is reported and asked
			# again, and that commands work afterwards.
			var parts := arg.substr("--p4-selftest-password-expired-live=".length()).split(",")
			if parts.size() != 2:
				_log("[selftest] FAIL: password-expired-live - pass <current>,<new>")
				get_tree().quit()
				return
			_selftest_auto_answer = "confirm"
			_login_declined = false
			_selftest_typed = ["not-the-password", parts[1], parts[1], parts[0], parts[1], "a-typo",
					parts[0], parts[1], parts[1]]
			_selftest_shown.clear()
			var before := await _p4_exec(["-ztag", "opened"])
			var refused: bool = _looks_like_password_expired(before)
			var waited := 0
			while (_login_prompt_active or _selftest_shown.size() < 2) and waited < 1200:
				await get_tree().process_frame
				waited += 1
			var after := await _p4_exec(["-ztag", "opened"])
			var told: bool = _selftest_shown.size() == 2 \
					and String(_selftest_shown[0]).contains("Password invalid") \
					and String(_selftest_shown[1]).contains("didn't match")
			var log_clean: bool = log_box != null and log_box.text.contains("passwd") \
					and not log_box.text.contains(parts[0]) and not log_box.text.contains(parts[1])
			_log("[selftest] refused-first=%s alerts=%s typed-left=%d works-after=%s log-holds-no-password=%s" \
					% [refused, told, _selftest_typed.size(), int(after.exit_code) == 0, log_clean])
			_log("[selftest] %s: password-expired-live" % ("PASS" if refused and told and log_clean \
					and _selftest_typed.is_empty() and int(after.exit_code) == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-submit-roundtrip":
			# Live and DESTRUCTIVE (two real submits): adds res://p4godot_submit_test.txt
			# through the default-changelist submit path with a description full of
			# shell metacharacters, checks the depot recorded it byte-for-byte, then
			# submits its deletion. Refuses to run unless nothing is opened.
			_selftest_auto_answer = "confirm"
			var opened := _parse_ztag(await _p4_exec(["-ztag", "opened"]))
			if not opened.is_empty():
				_log("[selftest] FAIL: submit-roundtrip - %d file(s) already opened; needs a clean workspace" % opened.size())
				get_tree().quit()
				return
			var test_res := "res://p4godot_submit_test.txt"
			var test_g := ProjectSettings.globalize_path(test_res)
			var fw := FileAccess.open(test_g, FileAccess.WRITE)
			fw.store_string("P4Godot submit selftest %d\n" % Time.get_unix_time_from_system())
			fw.close()
			await _p4_exec_logged(["add", test_g])
			var desc := "P4Godot selftest: \"quotes\" $VER `ticks` & ^ %PATH% 'single' trailing\\"
			await _submit_changelist("default", [], desc)
			var ch := _parse_ztag(await _p4_exec(["-ztag", "changes", "-m1", "-s", "submitted", test_g]))
			var num := "" if ch.is_empty() else String(ch[0].get("change", ""))
			var recorded := ""
			if not num.is_empty():
				var d := _parse_ztag(await _p4_exec(["-ztag", "describe", "-s", num]))
				recorded = "" if d.is_empty() else String(d[0].get("desc", "")).strip_edges()
			var desc_ok := recorded == desc
			_log("[selftest] add submitted as %s; desc recorded=[%s] match=%s" % [num, recorded, desc_ok])
			await _p4_exec_logged(["delete", test_g])
			await _submit_changelist("default", [], "P4Godot selftest: cleanup of p4godot_submit_test.txt")
			var st := _parse_ztag(await _p4_exec(["-ztag", "fstat", test_g]))
			var head_action := "" if st.is_empty() else String(st[0].get("headAction", ""))
			var left_open := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] cleanup headAction=%s opened-after=%d" % [head_action, left_open])
			if desc_ok and head_action == "delete" and left_open == 0:
				_log("[selftest] PASS: submit-roundtrip")
			else:
				_log("[selftest] FAIL: submit-roundtrip")
			get_tree().quit()
			return
		if arg == "--p4-selftest-submit-verdict":
			# Server-independent: the pieces that decide what a user is told
			# after a submit that didn't plainly succeed. Blobs are copied from
			# a 2025.2 server (2026-10-02). The point of all of it: "the command
			# failed" and "nothing was sent" are different claims, and only the
			# server can back the second one.
			#
			# `describe` puts a blank line after the description, so the status
			# sits in what _parse_ztag sees as a second record.
			var pending_blob := "... change 3148\n... user jase\n... client ws\n... time 1790968052\n" \
					+ "... desc a description\n\n... status pending\n... changeType public\n" \
					+ "... depotFile0 //d/proj/a.txt\n... action0 add\n... type0 text\n... rev0 1\n\n"
			var renamed_blob := "... change 3150\n... user jase\n... client ws\n... time 1790968053\n" \
					+ "... desc a description\n\n... status submitted\n... changeType public\n" \
					+ "... path //d/proj/*\n... oldChange 3148\n... depotFile0 //d/proj/a.txt\n\n"
			var p_status := _describe_status({"exit_code": 0, "output": [pending_blob]})
			var r_status := _describe_status({"exit_code": 0, "output": [renamed_blob]})
			# A renumbered changelist answers "no such changelist" under its old
			# number - with exit code 0.
			var gone_status := _describe_status({"exit_code": 0,
					"output": ["3148 - no such changelist.\n"]})
			var dead_status := _describe_status({"exit_code": 1, "output": [
					"Perforce client error:\n\tConnect to server failed; check $P4PORT.\n"]})
			_log("[selftest] describe: pending=%s renamed=%s gone=%s dead=%s"
					% [p_status, r_status, gone_status, dead_status])
			var describe_ok: bool = p_status.status == "pending" and p_status.change == "3148" \
					and r_status.status == "submitted" and r_status.change == "3150" \
					and gone_status.status == "missing" and dead_status.status == "unknown"

			# The submit's own output. Trigger chatter follows the line that
			# matters, and a failed submit also contains the word "Change".
			var ok_out := {"exit_code": 0, "output": ["Submitting change 3148.\nLocking 1 files ...\n" \
					+ "add //d/proj/a.txt#1\nChange 3148 submitted.\n/usr/bin/python3.9\n"]}
			var renamed_out := {"exit_code": 0, "output": ["Submitting change 3148.\n" \
					+ "Change 3148 renamed change 3150 and submitted.\nCalled subprocess with PID: 4\n"]}
			var refused_out := {"exit_code": 1, "output": ["Submitting change 3148.\n" \
					+ "//d/proj/a.txt - must sync/resolve #5 before submitting\n" \
					+ "Out of date files must be resolved or reverted.\n" \
					+ "Submit failed -- fix problems above then use 'p4 submit -c 3148'.\n"]}
			var dropped_out := {"exit_code": 1, "output": ["Submitting change 3148.\n" \
					+ "Perforce client error:\n\tTCP receive exceeded maximum configured duration of 600 seconds.\n"]}
			var silent_out := {"exit_code": 1, "output": [""]}
			var parse_ok: bool = _submitted_change_in(ok_out) == "3148" \
					and _submitted_change_in(renamed_out) == "3150" \
					and _submitted_change_in(refused_out) == "" \
					and _submitted_change_in(dropped_out) == ""
			# Only a refusal the server itself wrote counts as an answer. Text
			# nobody anticipated, an SSL failure, and a refusal line followed by
			# a network error all have to be treated as "may have been lost".
			var odd_out := {"exit_code": 1, "output": ["Perforce client error:\n\tsomething new\n"]}
			var ssl_out := {"exit_code": 1, "output": ["SSL receive failed.\n"]}
			var both_out := {"exit_code": 1, "output": ["Submit failed -- fix problems above.\n" \
					+ "TCP send failed.\n"]}
			var lost_ok: bool = not _submit_connection_lost(refused_out) \
					and _submit_connection_lost(dropped_out) \
					and _submit_connection_lost(silent_out) \
					and _submit_connection_lost(odd_out) \
					and _submit_connection_lost(ssl_out) \
					and _submit_connection_lost(both_out)
			# `change -i` can create the changelist and still exit non-zero.
			var created_ok: bool = _created_change_in({"exit_code": 1, "output": [
					"Change 3151 created with 1 open file(s).\nsome trigger said no\n"]}) == "3151" \
					and _created_change_in({"exit_code": 1, "output": [
					"Error in change specification.\nChange 12 unknown.\n"]}) == ""
			lost_ok = lost_ok and created_ok
			_log("[selftest] submitted-as: ok=%s renamed=%s refused='%s' dropped='%s'; lost: refused=%s dropped=%s silent=%s"
					% [_submitted_change_in(ok_out), _submitted_change_in(renamed_out),
					_submitted_change_in(refused_out), _submitted_change_in(dropped_out),
					_submit_connection_lost(refused_out), _submit_connection_lost(dropped_out),
					_submit_connection_lost(silent_out)])

			# `monitor show`: a working answer always lists our own `monitor`
			# command, so "no records" must read as can't-tell, never as "no
			# submit running" - that reading turns an unknown into "not sent".
			var mon_idle := {"exit_code": 0, "output": [
					"... id 41474\n... status R\n... user jase\n... time 00:00:00\n... command monitor\n\n"]}
			var mon_busy := {"exit_code": 0, "output": [
					"... id 41470\n... status R\n... user jase\n... time 00:01:10\n... command submit\n\n" \
					+ "... id 41474\n... status R\n... user jase\n... time 00:00:00\n... command monitor\n\n"]}
			var mon_other := {"exit_code": 0, "output": [
					"... id 41470\n... status R\n... user bob\n... time 00:01:10\n... command submit\n\n" \
					+ "... id 41474\n... status R\n... user jase\n... time 00:00:00\n... command monitor\n\n"]}
			var mon_off := {"exit_code": 1, "output": ["Monitor not currently enabled.\n"]}
			var mon_empty := {"exit_code": 0, "output": [""]}
			var monitor_ok: bool = _monitor_submit_running(mon_idle, "jase") == 0 \
					and _monitor_submit_running(mon_busy, "jase") == 1 \
					and _monitor_submit_running(mon_other, "jase") == 0 \
					and _monitor_submit_running({"exit_code": 0, "output": [
					"... id 7\n... status R\n... user jase\n... time 00:00:09\n... command dm-CommitSubmit\n\n"]},
					"jase") == 1 \
					and _monitor_submit_running(mon_off, "jase") == -1 \
					and _monitor_submit_running(mon_empty, "jase") == -1
			_log("[selftest] monitor: idle=%d busy=%d other-user=%d off=%d empty=%d"
					% [_monitor_submit_running(mon_idle, "jase"), _monitor_submit_running(mon_busy, "jase"),
					_monitor_submit_running(mon_other, "jase"), _monitor_submit_running(mon_off, "jase"),
					_monitor_submit_running(mon_empty, "jase")])

			# A submit stopped while a file was part-way up cannot be finished by
			# the server, whatever its process list goes on showing. That is what
			# lets a cancel be reported at once, with no special access. Stopped
			# BETWEEN files it proves nothing: the server may hold everything.
			var cut := P4Progress.new()
			cut.feed("progress (total): C:\\ws\\a.bin (type 1 units 3) - 0 of 100")
			cut.feed("progress (done): C:\\ws\\a.bin (type 1 units 3) - 100 of 100")
			var between_files := cut.in_flight()
			cut.feed("progress (total): C:\\ws\\b.bin (type 1 units 3) - 0 of 100")
			cut.feed("progress (update): C:\\ws\\b.bin (type 1 units 3) - 40 of 100")
			var mid_file := cut.in_flight()
			_log("[selftest] in flight: between files=%d, mid-file=%d, nothing reported=%d"
					% [between_files, mid_file, P4Progress.new().in_flight()])
			# After a cut upload only a COMMIT counts as the server still working;
			# its leftover `submit` entry does not.
			var committing := {"exit_code": 0, "output": [
					"... id 7\n... status R\n... user jase\n... time 00:00:09\n... command dm-CommitSubmit\n\n"]}
			monitor_ok = monitor_ok and between_files == 0 and mid_file == 1 \
					and P4Progress.new().in_flight() == 0 \
					and _monitor_submit_running(mon_busy, "jase", true) == 0 \
					and _monitor_submit_running(committing, "jase", true) == 1

			# What the user reads. Only a checked "not submitted" may say
			# nothing was sent; "unknown" must not, and must say not to resubmit.
			var t_sub := _submit_outcome_text("submitted", "3148", "3150", "TCP receive failed", true)
			var t_not := _submit_outcome_text("not_submitted", "3148", "", "must sync/resolve", false)
			var t_not_lost := _submit_outcome_text("not_submitted", "3148", "", "TCP receive failed", true)
			var t_unk := _submit_outcome_text("unknown", "3148", "", "TCP receive failed", true)
			_log("[selftest] unknown text: %s" % t_unk.replace("\n", " | "))
			var text_ok: bool = t_sub.contains("submitted as change 3150") \
					and t_not.contains("Nothing was sent") and t_not.contains("changelist 3148") \
					and t_not.contains("must sync/resolve") \
					and t_not_lost.contains("nothing was sent") and t_not_lost.contains("dropped") \
					and not t_unk.to_lower().contains("nothing was sent") \
					and t_unk.contains("can't tell") and t_unk.contains("Don't submit again") \
					and t_unk.contains("empty panel") and not t_unk.contains("never arrived") \
					and t_unk.contains("3148")

			if describe_ok and parse_ok and lost_ok and monitor_ok and text_ok:
				_log("[selftest] PASS: submit-verdict")
			elif not describe_ok:
				_log("[selftest] FAIL: submit-verdict - misread a changelist's status")
			elif not parse_ok:
				_log("[selftest] FAIL: submit-verdict - misread the submit's own output")
			elif not lost_ok:
				_log("[selftest] FAIL: submit-verdict - a refusal and a dropped connection were confused")
			elif not monitor_ok:
				_log("[selftest] FAIL: submit-verdict - misread what the server is running")
			else:
				_log("[selftest] FAIL: submit-verdict - the outcome text claims more than was checked")
			get_tree().quit()
			return
		if arg == "--p4-selftest-progress":
			# Server-independent: the progress tracker against lines copied from a
			# 2025.2 client and server (2026-10-02), and the cleanup after a
			# cancelled sync against real files in a scratch folder.
			#
			# (a) A parallel submit: kilobyte units, two files interleaved, one of
			# them reporting "done" with no "update" before it.
			var t := P4Progress.new()
			t.total_files = 2
			t.total_bytes = 3000000
			t.sizes = {"c:/ws/a.bin": 1500000, "c:/ws/b.bin": 1500000}
			var answer_line := not t.feed("Change 3171 submitted.")
			t.feed("progress (total): C:\\ws\\a.bin (type 1 units 3) - 0 of 1464")
			t.feed("progress (total): C:\\ws\\b.bin (type 1 units 3) - 0 of 1464")
			t.feed("progress (update): C:\\ws\\b.bin (type 1 units 3) - 732 of 1464")
			var half_b := t.bytes_done()
			var mid_text := _progress_detail_text(t, 83.0)
			t.feed("progress (done): C:\\ws\\a.bin (type 1 units 3) - 1464 of 1464")
			var after_a := t.files_done
			# A repeated "done" must not count twice.
			t.feed("progress (done): C:\\ws\\a.bin (type 1 units 3) - 1464 of 1464")
			_log("[selftest] kb: half-b=%d bytes, files after a=%d (repeat: %d), fraction=%.3f, text=%s"
					% [half_b, after_a, t.files_done, t.fraction(), mid_text])
			var kb_ok: bool = answer_line and half_b == 750000 and after_a == 1 \
					and t.files_done == 1 and absf(t.fraction() - 0.75) < 0.001 \
					and t.is_done("C:/ws/a.bin") and not t.is_done("C:\\ws\\b.bin") \
					and mid_text == "0 of 2 files  -  732 KB of 2.9 MB  -  1:23"

			# (b) Delta Transfer on submit: units 5 ("deltas"), "17 of 22". The
			# position is a fraction of the file, the size is what we knew.
			var d := P4Progress.new()
			d.total_files = 1
			d.total_bytes = 24000000
			d.sizes = {"c:/ws/big.bin": 24000000}
			d.feed("progress (total): C:\\ws\\big.bin (type 1 units 5) - 0 of 22")
			d.feed("progress (update): C:\\ws\\big.bin (type 1 units 5) - 11 of 22")
			var delta_half := d.bytes_done()
			d.feed("--- rpc msgs/size in+out 2+2/0mb+0mb himarks 318788/64836 snd/rcv .000s/.011s")
			d.feed("--- rpc msgs/size in+out 28+9/6mb+0mb himarks 318788/64836 snd/rcv .000s/.899s")
			d.feed("---   locks read/write 0/1 rows get+pos+scan put+del 0+0+0 1+0")
			d.feed("progress (done): C:\\ws\\big.bin (type 1 units 5) - 22 of 22")
			var delta_summary := _transfer_summary(d)
			_log("[selftest] delta: half=%d, delta files=%d, network=%d MB, summary=%s"
					% [delta_half, d.delta_files, d.network_mb, delta_summary])
			var delta_ok: bool = delta_half == 12000000 and d.delta_files == 1 \
					and d.network_mb == 6 and d.files_done == 1 \
					and delta_summary.contains("About 6 MB crossed the network") \
					and delta_summary.contains("Delta Transfer")

			# (c) A Delta Transfer SYNC reports nothing for the file. Without
			# finish() the bar would stop short of the end for good.
			var s := P4Progress.new()
			s.total_files = 2
			s.total_bytes = 25000000
			s.feed("progress (total): C:\\ws\\small.gd (type 2 units 3) - 0 of 976")
			s.feed("progress (done): C:\\ws\\small.gd (type 2 units 3) - 976 of 976")
			var before_finish := s.fraction()
			var idle_text := _progress_detail_text(P4Progress.new(), 7.0)
			s.finish()
			# A parallel transfer's tracking line reads 0 MB: say nothing about
			# the network instead of "0 MB crossed".
			s.feed("--- rpc msgs/size in+out 3+811/0mb+0mb himarks 318788/64836 snd/rcv .022s/7.68s")
			var quiet_summary := _transfer_summary(s)
			# Paths with spaces and brackets, and a line that isn't a transfer
			# (type 4, a computation), must not confuse the count.
			var odd := P4Progress.new()
			odd.feed("progress (total): C:\\my ws\\art (final)\\a b.png (type 2 units 3) - 0 of 10")
			odd.feed("progress (done): C:\\my ws\\art (final)\\a b.png (type 2 units 3) - 10 of 10")
			odd.feed("progress (update): digest (type 4 units 6) - 3 of 9")
			_log("[selftest] silent sync: %.3f before finish, %.3f after, %d files; idle text=%s; summary=%s; odd path done=%s files=%d"
					% [before_finish, s.fraction(), s.files_done, idle_text, quiet_summary,
					odd.is_done("C:/my ws/art (final)/a b.png"), odd.expected_files()])
			var finish_ok: bool = before_finish < 0.1 and s.fraction() == 1.0 and s.files_done == 2 \
					and idle_text == "Working...  -  0:07" \
					and not quiet_summary.contains("crossed the network") \
					and odd.is_done("C:/my ws/art (final)/a b.png") and odd.expected_files() == 1

			# (d) Small pure pieces.
			var misc_ok: bool = _duration_text(3725.0) == "1:02:05" and _duration_text(7.9) == "0:07" \
					and absf(_p4_version_in("Rev. P4/NTX64/2025.2/2907753 (2026/03/09).") - 2025.2) < 0.001 \
					and _p4_version_in("Rev. P4/LINUX26X86_64/2020.2/2075706 (2021/01/12).") < P4_PROGRESS_MIN_VERSION \
					and _p4_version_in("nonsense") == 0.0 \
					and _submit_outcome_text("not_submitted", "12", "", "", true, true).contains("Submit cancelled") \
					and _submit_outcome_text("submitted", "12", "14", "", true, true).contains("Too late to cancel") \
					and _submit_outcome_text("submitted", "12", "14", "", true, true).contains("change 14")

			# (e) Cleanup after a cancelled sync. Four files the preview said
			# would be added: one p4 reported done (keep), one that was already
			# on disk before the sync (keep - it is the user's), one left empty
			# by the kill (remove), one that never appeared (nothing to do). Plus
			# a p4 temp file (remove) and a stranger's .tmp (keep).
			var scratch := _p4godot_cache_dir().path_join("selftest_cancel_%d" % Time.get_ticks_usec())
			DirAccess.make_dir_recursive_absolute(scratch)
			var paths := {}
			# And "recorded.bin": p4 never reported it done (an old p4 reports
			# nothing), but the server says it was delivered - it must stay.
			for n in ["done.bin", "mine.txt", "partial.bin", "never.bin", "t123t456t7.tmp", "notes.tmp", "kept.gd", "recorded.bin"]:
				paths[n] = scratch.path_join(n)
			for n in ["done.bin", "mine.txt", "partial.bin", "t123t456t7.tmp", "notes.tmp", "kept.gd", "recorded.bin"]:
				var wf := FileAccess.open(paths[n], FileAccess.WRITE)
				wf.store_string("" if n == "partial.bin" else "content")
				wf.close()
			_set_file_writable(paths["done.bin"], false)
			var ct := P4Progress.new()
			ct.feed("progress (total): %s (type 2 units 3) - 0 of 1" % paths["done.bin"])
			ct.feed("progress (done): %s (type 2 units 3) - 1 of 1" % paths["done.bin"])
			var fake_found := {"locals": [paths["done.bin"], paths["mine.txt"], paths["partial.bin"],
					paths["never.bin"], paths["kept.gd"]],
					"added_locals": [paths["done.bin"], paths["mine.txt"], paths["partial.bin"],
					paths["never.bin"], paths["recorded.bin"]]}
			# First with no server to ask (this test has none): nothing at all
			# may be deleted on the tracker's word alone.
			var blind_count: int = await _cleanup_cancelled_sync(fake_found,
					{_path_key(paths["mine.txt"]): true}, ct,
					int(Time.get_unix_time_from_system()) + 3600)
			var blind_kept: bool = blind_count == 0 and FileAccess.file_exists(paths["partial.bin"])
			# Then with the server's answer supplied.
			var removed_count: int = await _cleanup_cancelled_sync(fake_found,
					{_path_key(paths["mine.txt"]): true}, ct,
					int(Time.get_unix_time_from_system()) - 5,
					{_path_key(paths["recorded.bin"]): true})
			var left := {}
			for n in paths:
				left[n] = FileAccess.file_exists(paths[n])
			_log("[selftest] cleanup with no answer removed %d; with one removed %d; left on disk: %s"
					% [blind_count, removed_count, left])
			var cleanup_ok: bool = blind_kept and removed_count == 1 and left["done.bin"] \
					and left["mine.txt"] and left["recorded.bin"] \
					and not left["partial.bin"] and not left["t123t456t7.tmp"] \
					and left["notes.tmp"] and left["kept.gd"]
			for n in paths:
				_set_file_writable(paths[n], true)
				DirAccess.remove_absolute(paths[n])
			DirAccess.remove_absolute(scratch)

			if kb_ok and delta_ok and finish_ok and misc_ok and cleanup_ok:
				_log("[selftest] PASS: progress")
			elif not kb_ok:
				_log("[selftest] FAIL: progress - wrong totals from kilobyte progress lines")
			elif not delta_ok:
				_log("[selftest] FAIL: progress - Delta Transfer lines or the network total misread")
			elif not finish_ok:
				_log("[selftest] FAIL: progress - a file p4 never reported left the bar short, or an odd line broke the count")
			elif not misc_ok:
				_log("[selftest] FAIL: progress - duration, version or cancel text")
			else:
				_log("[selftest] FAIL: progress - cleanup after a cancelled sync removed the wrong files")
			get_tree().quit()
			return
		if arg == "--p4-selftest-streamed-exec":
			# Needs a local p4 binary, no server. Runs p4 through the piped,
			# streamed path: output must come back in the same shape OS.execute
			# gives, and a command stuck connecting to an address that never
			# answers must be stopped by Cancel in about a second, not after the
			# operating system's connect timeout.
			var st := P4Progress.new()
			var ver: Dictionary = await _p4_exec_streamed(["-V"], st)
			var ver_text := "" if ver.output.is_empty() else String(ver.output[0])
			_log("[selftest] streamed -V: exit=%d cancelled=%s, %d chars, version parsed=%.1f"
					% [ver.exit_code, ver.cancelled, ver_text.length(), _p4_version_in(ver_text)])
			var ver_ok: bool = int(ver.exit_code) == 0 and not ver.cancelled \
					and ver_text.contains("Perforce") and _p4_version_in(ver_text) > 2000.0
			get_tree().create_timer(0.6).timeout.connect(_cancel_streamed)
			var began := Time.get_ticks_msec()
			var stuck: Dictionary = await _p4_exec_streamed(["-p", "10.255.255.1:1666", "info"], st)
			var took := Time.get_ticks_msec() - began
			_log("[selftest] cancelled a stuck connect after %d ms: exit=%d cancelled=%s breaker tripped=%s"
					% [took, stuck.exit_code, stuck.cancelled, _server_unreachable()])
			var cancel_ok: bool = bool(stuck.cancelled) and took < 5000 and int(stuck.exit_code) != 0 \
					and _streamed_req == null
			if ver_ok and cancel_ok:
				_log("[selftest] PASS: streamed-exec")
			elif not ver_ok:
				_log("[selftest] FAIL: streamed-exec - a streamed command's output didn't come back intact")
			else:
				_log("[selftest] FAIL: streamed-exec - Cancel didn't stop a running p4")
			get_tree().quit()
			return
		if arg == "--p4-selftest-connection-dialogs":
			# Server-independent: run the connection dialogs' code. Nothing here
			# can see how a dialog looks; it proves the dialogs open, answer and
			# close without a script error, that the third button is told apart
			# from OK and Cancel, and the one rule with consequences: pressing
			# Connect without editing must not turn inherited Perforce settings
			# into stored per-project ones.
			_selftest_auto_answer = "confirm"
			var conn: Dictionary = await _show_connection_dialog("ssl:example:1666", "ana")
			var opt_ok: Dictionary = await _show_option_dialog("t", "m",
					PackedStringArray(["one", "two"]), 1, "OK", CHANGE_SERVER_TEXT)
			var before := [_override_port, _override_user, _override_client]
			var untouched: Dictionary = await _edit_connection()
			var after_edit := [_override_port, _override_user, _override_client]
			_selftest_auto_answer = "extra"
			var opt_extra: Dictionary = await _show_option_dialog("t", "m",
					PackedStringArray(["one", "two"]), 0, "OK", CHANGE_SERVER_TEXT)
			var in_extra: Dictionary = await _show_input_dialog("t", "m", "", false, "OK",
					false, CHANGE_SERVER_TEXT)
			# No third button on this one, so "extra" has nothing to press: cancel.
			var in_plain: Dictionary = await _show_input_dialog("t", "m", "", false, "OK")
			_selftest_auto_answer = "cancel"
			var conn_cancel: Dictionary = await _show_connection_dialog("ssl:example:1666", "ana")
			var cancelled_edit: Dictionary = await _edit_connection()
			var picked_nothing: bool = not await _pick_client()
			_log("[selftest] connection=%s option-ok=%s option-extra=%s input-extra=%s edit-unchanged=%s"
					% [conn, opt_ok, opt_extra, in_extra, untouched])
			var dialogs_ok: bool = conn.ok and conn.port == "ssl:example:1666" and conn.user == "ana" \
					and opt_ok.ok and opt_ok.index == 1 and not opt_ok.extra \
					and opt_extra.extra and not opt_extra.ok \
					and in_extra.extra and not in_extra.ok \
					and not in_plain.extra and not in_plain.ok \
					and not conn_cancel.ok
			var edit_ok: bool = untouched.ok and not untouched.changed and before == after_edit \
					and not cancelled_edit.ok and not cancelled_edit.changed and picked_nothing
			if dialogs_ok and edit_ok:
				_log("[selftest] PASS: connection-dialogs")
			elif not dialogs_ok:
				_log("[selftest] FAIL: connection-dialogs - a dialog reported the wrong button")
			else:
				_log("[selftest] FAIL: connection-dialogs - an unedited Connect changed the stored settings")
			get_tree().quit()
			return
		if arg == "--p4-selftest-submit-cancel":
			# Live and DESTRUCTIVE: uploads part (or all) of a 24 MB file.
			# Cancels a submit the moment p4 reports the transfer under way, then
			# checks that what the user is told matches the server. Either answer
			# is legitimate - cancelled in time, or too late - but it must be the
			# TRUE one, and the workspace must be left usable. Needs a clean
			# workspace.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: submit-cancel - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			var c_res := "res://p4godot_cancel_test.bin"
			var c_g := ProjectSettings.globalize_path(c_res)
			var cf := FileAccess.open(c_g, FileAccess.WRITE)
			var block := PackedByteArray()
			block.resize(1048576)
			for mb in 24:
				for i in range(0, block.size(), 8):
					block.encode_s64(i, randi() << 32 | randi())
				cf.store_buffer(block)
			cf.close()
			await _p4_exec_logged(["add", "-t", "binary", c_g])
			_selftest_cancel_on_progress = true
			var c_began := Time.get_ticks_msec()
			await _submit_changelist("default", [], "P4Godot selftest: cancelled submit (add)")
			var c_took := Time.get_ticks_msec() - c_began
			var c_outcome := _last_submit_outcome
			var c_head := _parse_ztag(await _p4_exec(["-ztag", "files", c_g]))
			var in_depot: bool = not c_head.is_empty() \
					and String(c_head[0].get("action", "")) != "delete"
			var c_opened := _parse_ztag(await _p4_exec(["-ztag", "opened", c_g]))
			var still_change := "" if c_opened.is_empty() else String(c_opened[0].get("change", ""))
			_log("[selftest] cancelled after %d ms: outcome=%s; in depot=%s; still opened in change '%s'"
					% [c_took, c_outcome, in_depot, still_change])
			# The claim has to match the server, whichever way it went.
			var truthful: bool = (c_outcome == "submitted" and in_depot and c_opened.is_empty()) \
					or (c_outcome == "not_submitted" and not in_depot and not still_change.is_empty())
			# Clean up, through the same code a user would use next.
			var c_clean := false
			if c_outcome == "not_submitted":
				# The promise was "submit it again from the panel": do exactly that.
				await _submit_changelist(still_change, [])
				c_clean = _last_submit_outcome == "submitted"
			if _last_submit_outcome == "submitted":
				await _p4_exec_logged(["delete", c_g])
				await _submit_changelist("default", [], "P4Godot selftest: cleanup of p4godot_cancel_test.bin")
				c_clean = c_clean or c_outcome == "submitted"
			var c_left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] resubmit-after-cancel ok=%s, opened-after=%d" % [c_clean, c_left])
			if truthful and c_clean and c_left == 0:
				_log("[selftest] PASS: submit-cancel (%s)" % c_outcome)
			elif not truthful:
				_log("[selftest] FAIL: submit-cancel - the outcome reported doesn't match the server")
			else:
				_log("[selftest] FAIL: submit-cancel - the workspace wasn't usable after the cancel")
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-submit-slow-trigger-live="):
			# Live and DESTRUCTIVE (three real submits; use a throwaway server):
			# --p4-selftest-submit-slow-trigger-live=<seconds>, on a server whose
			# change-content trigger sleeps that long (tools/p4-test-server.sh
			# trigger). First a submit left alone, which must wait the trigger
			# out and succeed. Then one cancelled after every file is sent: the
			# server has it all and finishes the job with p4 gone, so the only
			# true thing to tell the user is "too late, it was submitted".
			var wait_sec := int(arg.substr("--p4-selftest-submit-slow-trigger-live=".length()))
			_selftest_auto_answer = "confirm"
			if wait_sec <= 0 or not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: submit-slow-trigger-live - pass the trigger's seconds, and start with nothing opened")
				get_tree().quit()
				return
			var names := ["p4godot_trigger_a.txt", "p4godot_trigger_b.txt"]
			var outcomes: Array = []
			var times: Array = []
			var in_depot: Array = []
			for i in 2:
				var g := ProjectSettings.globalize_path("res://" + names[i])
				var fw := FileAccess.open(g, FileAccess.WRITE)
				fw.store_string("slow trigger %d\n" % i)
				fw.close()
				await _p4_exec_logged(["add", g])
				_selftest_cancel_when_sent = i == 1
				_selftest_shown.clear()
				var began := Time.get_ticks_msec()
				await _submit_changelist("default", [], "P4Godot selftest: slow trigger %d" % i)
				times.append(Time.get_ticks_msec() - began)
				outcomes.append(_last_submit_outcome)
				in_depot.append(not _parse_ztag(await _p4_exec(["-ztag", "files", g])).is_empty())
			var hook_fired := not _selftest_cancel_when_sent
			var told := "" if _selftest_shown.is_empty() else String(_selftest_shown[-1])
			_log("[selftest] left alone: %s after %d ms, in depot=%s" % [outcomes[0], times[0], in_depot[0]])
			_log("[selftest] cancelled once sent (cancel pressed=%s): %s after %d ms, in depot=%s; told: %s" \
					% [hook_fired, outcomes[1], times[1], in_depot[1], told.get_slice("\n", 0)])
			var ok: bool = outcomes[0] == "submitted" and in_depot[0] and int(times[0]) >= wait_sec * 1000 \
					and hook_fired and outcomes[1] == "submitted" and in_depot[1] \
					and told.begins_with("Too late to cancel")
			for n: String in names:
				await _p4_exec_logged(["delete", ProjectSettings.globalize_path("res://" + n)])
			await _submit_changelist("default", [], "P4Godot selftest: slow trigger cleanup")
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] opened-after=%d" % left)
			_log("[selftest] %s: submit-slow-trigger-live" % ("PASS" if ok and left == 0 else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-get-latest-cancel":
			# Live. Stage it outside Godot first: make the project several files
			# and at least ~20 MB behind (`p4 sync <path>#none` on some of it), so
			# the download lasts long enough to be stopped part-way.
			# Cancels Get Latest the moment the transfer is under way, then checks
			# the two things a killed sync gets wrong on its own: it leaves
			# half-written files that every later sync refuses to overwrite, and
			# it says nothing useful. A second Get Latest must then finish the job.
			_selftest_auto_answer = "confirm"
			var gl_before := _summarize_sync(_parse_ztag(
					await _p4_exec(["-ztag", "sync", "-n", "-s", _project_scope()])))
			_selftest_cancel_on_progress = true
			var gl_report := await _get_latest_flow()
			await _selftest_drain_frames()
			_log("[selftest] report: %s" % gl_report.replace("\n", " | "))
			var gl_mid: Dictionary = await _p4_exec(["-ztag", "sync", "-n", "-s", _project_scope()])
			var gl_mid_sum := _summarize_sync(_parse_ztag(gl_mid))
			var gl_mid_notes := _sync_notes(gl_mid)
			_log("[selftest] staged %d behind; after cancel %d still behind, %d refused as existing, %d as modified"
					% [gl_before.names.size(), gl_mid_sum.names.size(), gl_mid_notes.existing.size(),
					gl_mid_notes.modified.size()])
			var gl_second := await _get_latest_flow()
			await _selftest_drain_frames()
			var gl_after := _summarize_sync(_parse_ztag(
					await _p4_exec(["-ztag", "sync", "-n", "-s", _project_scope()])))
			_log("[selftest] second run: %s | still behind afterwards: %d"
					% [gl_second.replace("\n", " | ").left(160), gl_after.names.size()])
			var was_cancelled: bool = gl_report.contains("was cancelled")
			var no_wreckage: bool = gl_mid_notes.existing.is_empty() and gl_mid_notes.modified.is_empty()
			var recovered: bool = gl_after.names.is_empty() and not gl_second.contains("would not overwrite") \
					and not gl_second.contains("were not downloaded")
			if gl_before.names.size() < 2:
				_log("[selftest] FAIL: get-latest-cancel - stage the project behind head first (see the source comment)")
			elif not was_cancelled:
				_log("[selftest] FAIL: get-latest-cancel - the sync finished before Cancel landed; stage a bigger download")
			elif not gl_mid_sum.names.size() > 0:
				_log("[selftest] FAIL: get-latest-cancel - nothing was left to download, so Cancel stopped nothing")
			elif not no_wreckage:
				_log("[selftest] FAIL: get-latest-cancel - half-written files were left behind")
			elif not recovered:
				_log("[selftest] FAIL: get-latest-cancel - a second Get Latest didn't finish the job")
			else:
				_log("[selftest] PASS: get-latest-cancel")
			get_tree().quit()
			return
		if arg == "--p4-selftest-submit-verdict-live":
			# Live and DESTRUCTIVE (two real submits). Asks a real server what
			# became of a changelist in the two cases a dropped connection leaves
			# behind: submitted under a NEW number, and still pending.
			# Staging a renumber: a changelist is renumbered on submit when a
			# higher-numbered one exists, so an empty one is created after it.
			# Refuses to run unless nothing is opened.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: submit-verdict-live - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			var v_res := "res://p4godot_verdict_test.txt"
			var v_g := ProjectSettings.globalize_path(v_res)
			var vf := FileAccess.open(v_g, FileAccess.WRITE)
			vf.store_string("P4Godot verdict selftest %d\n" % Time.get_unix_time_from_system())
			vf.close()
			await _p4_exec_logged(["add", v_g])
			var v_opened := _parse_ztag(await _p4_exec(["-ztag", "opened", v_g]))
			var v_depot := "" if v_opened.is_empty() else String(v_opened[0].get("depotFile", ""))
			var first := _parse_change_number(await _p4_exec_spec(["change", "-i"],
					"Change: new\n\nDescription:\n\tP4Godot selftest: verdict (add)\n\nFiles:\n\t%s\n" % v_depot))
			var blocker := await _create_changelist("P4Godot selftest: forces a renumber - safe to delete")
			_log("[selftest] staged: file in change %s, empty change %s after it" % [first, blocker])

			# Still pending, and no submit of ours running: whether or not the
			# connection was lost, that is "not submitted".
			var v_pending: Dictionary = await _submit_verdict(first, true)
			var v_pending_answered: Dictionary = await _submit_verdict(first, false)
			_log("[selftest] verdict while pending: lost=%s answered=%s" % [v_pending, v_pending_answered])

			await _submit_changelist(first, [])
			# Asked about under its OLD number, as after a lost connection.
			var v_done: Dictionary = await _submit_verdict(first, true)
			var by_file := _parse_ztag(await _p4_exec(["-ztag", "changes", "-m1", "-s", "submitted", v_g]))
			var landed := "" if by_file.is_empty() else String(by_file[0].get("change", ""))
			_log("[selftest] verdict after submit: %s; the file's newest change is %s" % [v_done, landed])

			await _p4_exec_logged(["change", "-d", blocker])
			await _p4_exec_logged(["delete", v_g])
			await _submit_changelist("default", [], "P4Godot selftest: cleanup of p4godot_verdict_test.txt")
			var v_left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			var v_ok: bool = not first.is_empty() and not blocker.is_empty() \
					and v_pending.outcome == "not_submitted" \
					and v_pending_answered.outcome == "not_submitted" \
					and v_done.outcome == "submitted" and v_done.change == landed \
					and landed != first and not landed.is_empty() and v_left == 0
			_log("[selftest] renumbered %s -> %s, opened-after=%d" % [first, landed, v_left])
			_log("[selftest] %s: submit-verdict-live" % ("PASS" if v_ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-create-changelist":
			# Live: exercise the full stdin-spec plumbing, then clean up.
			var num := await _create_changelist("[P4 selftest] temp CL - safe to delete")
			_log("[selftest] created CL=%s" % num)
			if not num.is_empty():
				var del := await _p4_exec_logged(["change", "-d", num])
				_log("[selftest] cleanup delete exit=%d" % del.exit_code)
				_log("[selftest] %s: create-changelist" % ("PASS" if del.exit_code == 0 else "FAIL"))
			else:
				_log("[selftest] FAIL: create-changelist (no number returned)")
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-import-dock="):
			# Live: the Import dock hook. Part 1 presses the real Reimport button
			# with unchanged settings (armed, then re-locked, not opened). Part 2
			# changes a parameter while armed, as the dock's own save does, and
			# reimports (checked out). Leaves the .import opened - revert after.
			var path := arg.substr("--p4-selftest-import-dock=".length())
			var gp_imp := ProjectSettings.globalize_path(path + ".import")
			var is_rw := func() -> bool: return FileAccess.open(gp_imp, FileAccess.READ_WRITE) != null
			EditorInterface.select_file(path)
			await _selftest_drain_frames()
			var hooked := is_instance_valid(_import_reimport_button)
			var armed := false
			var relocked := false
			if hooked:
				_import_reimport_button.button_down.emit()
				armed = is_rw.call() and _reimport_backups.has(gp_imp)
				_import_reimport_button.pressed.emit()
				await _selftest_drain_frames()
				# Headless, the dock may not have picked up the selection, so the
				# press reimports nothing - exactly a user's cancel. Then the 30 s
				# fallback timer must re-lock it.
				var until := Time.get_ticks_msec() + 40000
				while (is_rw.call() or _reimport_backups.has(gp_imp)) and Time.get_ticks_msec() < until:
					await get_tree().create_timer(0.5).timeout
				relocked = not is_rw.call() and not _reimport_backups.has(gp_imp)
			var untouched: bool = await _needs_checkout(gp_imp)
			# Part 2: a real settings change.
			if hooked:
				_import_reimport_button.button_down.emit()
			else:
				_arm_reimport_guard(gp_imp)
			var cf := ConfigFile.new()
			cf.load(gp_imp)
			cf.set_value("params", "mipmaps/generate", not bool(cf.get_value("params", "mipmaps/generate", false)))
			cf.save(gp_imp)
			EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray([path]))
			await _selftest_drain_frames()
			var checked_out := not await _needs_checkout(gp_imp)
			_log("[selftest] hooked=%s armed=%s relocked=%s untouched=%s changed-checked-out=%s"
					% [hooked, armed, relocked, untouched, checked_out])
			_log("[selftest] %s: import-dock" % ("PASS" if hooked and armed and relocked
					and untouched and checked_out else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-script-revert="):
			# Live: reverting a script has to put the DEPOT text back in front
			# of the user. Godot holds the edited source in the cached Script
			# resource as well as in the open tab, so a reload that only
			# closes the tab hands the edit straight back the moment the file
			# is reopened.
			#
			# This has to run against a real `p4 revert`, not a simulated one.
			# Restoring the file with FileAccess moves its modification time
			# FORWARD, and Godot then reloads the script by itself, which
			# hides the bug. Perforce restores the depot file's own modtime,
			# which is older than the edit - Godot sees nothing to reload, and
			# the stale cached resource is what the user gets.
			# Self-cleaning: the revert is the cleanup.
			var path := arg.substr("--p4-selftest-script-revert=".length())
			var global := ProjectSettings.globalize_path(path)
			var marker := "# p4godot selftest edit"
			_selftest_auto_answer = "confirm"
			await _do_checkout(path)
			var original := FileAccess.get_file_as_string(global)
			var scr := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Script
			EditorInterface.edit_script(scr)
			await _settle_frames(2)
			# Edit it the way the editor does: the tab's text and the cached
			# resource both carry the change, and a save puts it on disk.
			var edited := original + "\n" + marker + "\n"
			scr.source_code = edited
			var typed := _current_script_code_edit()
			if typed:
				typed.text = edited
			var f := FileAccess.open(global, FileAccess.WRITE)
			f.store_string(edited)
			f.close()
			await _selftest_drain_frames()
			var dirty_before: bool = (ResourceLoader.load(path) as Script).source_code.contains(marker)

			# What _revert_path does, with a sample taken in between: whether
			# the cached resource is still dirty once Perforce has put the
			# depot file back is the whole question the fix turns on.
			await _p4_exec_logged(["revert", global])
			_checked_out_this_session.erase(path)
			var cached_dirty_at_reload: bool = (ResourceLoader.load(path) as Script).source_code.contains(marker)
			_log("[selftest] cached still dirty when the reload starts: %s" % cached_dirty_at_reload)
			await _reload_path(path)

			var disk_clean: bool = not FileAccess.get_file_as_string(global).contains(marker)
			var cached_clean: bool = not (ResourceLoader.load(path) as Script).source_code.contains(marker)
			var still_open := false
			for s in EditorInterface.get_script_editor().get_open_scripts():
				if (s as Script).resource_path == path:
					still_open = true
			var shown := _current_script_code_edit()
			var tab_clean: bool = shown != null and not shown.text.contains(marker)
			_log("[selftest] dirty before revert=%s; disk clean=%s; cached clean=%s; tab still open=%s; tab clean=%s"
					% [dirty_before, disk_clean, cached_clean, still_open, tab_clean])

			# Second case, and the one only the CACHE_MODE_IGNORE load can
			# cover: the script has no tab open when the revert happens. There
			# is nothing to close and reopen, so if the cached resource isn't
			# re-read, the edit is still sitting there waiting to be served
			# the next time the user opens the file.
			await _do_checkout(path)
			var f2 := FileAccess.open(global, FileAccess.WRITE)
			f2.store_string(edited)
			f2.close()
			(ResourceLoader.load(path) as Script).source_code = edited
			EditorInterface.get_script_editor().close_file(path)
			await _settle_frames(2)
			var closed: bool = not _is_open_in_editor(path)
			await _p4_exec_logged(["revert", global])
			_checked_out_this_session.erase(path)
			await _reload_path(path)
			var closed_cached_clean: bool = not (ResourceLoader.load(path) as Script).source_code.contains(marker)
			_log("[selftest] with no tab open: closed=%s cached clean after reload=%s"
					% [closed, closed_cached_clean])

			var ok: bool = dirty_before and disk_clean and cached_clean and still_open \
					and tab_clean and closed and closed_cached_clean
			_log("[selftest] %s: script-revert" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-decline-reprompt="):
			# Live: declining a checkout must not turn checkout off for the
			# rest of the session. The decline reloads the file from disk, so
			# the NEXT edit is a genuinely new one and has to prompt again.
			# Leaves the scene opened - revert afterwards.
			var path := arg.substr("--p4-selftest-decline-reprompt=".length())
			var global := ProjectSettings.globalize_path(path)
			auto_checkout_checkbox.set_pressed_no_signal(true)
			_selftest_auto_answer = "cancel"
			await _selftest_simulate_edit(path)
			await _selftest_drain_frames()
			var opened_after_decline := not await _needs_checkout(global)
			var suppressed := _declined_this_session.has(path)
			# A second edit, accepted this time. Reaching the prompt at all is
			# what's under test; the checkout is how we observe it.
			#
			# It has to land in the SAME tab, with no reopen: opening the
			# scene again would hand the editor a fresh undo history, which
			# hides a stale recorded version (the reload resets the version to
			# 1, so a version left on record from before the reload is a
			# number later edits can never reach).
			_selftest_auto_answer = "confirm"
			var root := EditorInterface.get_edited_scene_root()
			var root_path := "<none>" if root == null else root.get_scene_file_path()
			if root != null:
				var ur2 := get_undo_redo()
				ur2.create_action("[P4 selftest] second edit, same tab")
				ur2.add_do_method(root, "set_meta", "_p4_selftest_2", true)
				ur2.add_undo_method(root, "remove_meta", "_p4_selftest_2")
				ur2.commit_action()
			await _selftest_drain_frames()
			var opened_after_second := not await _needs_checkout(global)
			_log("[selftest] after decline: opened=%s suppressed=%s; second edit in tab '%s': opened=%s"
					% [opened_after_decline, suppressed, root_path, opened_after_second])
			var ok: bool = not opened_after_decline and not suppressed and opened_after_second
			_log("[selftest] %s: decline-reprompt" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-opened-cache="):
			# Live: the session's "already checked out" cache is rebuilt from
			# `p4 opened` on every refresh, so a submit or revert made outside
			# Godot can't leave a file marked checked out here for the rest of
			# the session (which would make later edits to it silently skip
			# the checkout). Leaves the file opened - revert afterwards.
			var path := arg.substr("--p4-selftest-opened-cache=".length())
			_selftest_auto_answer = "confirm"
			await _do_checkout(path)
			await _selftest_drain_frames()
			# A file someone else reverted or submitted, still on record here.
			_checked_out_this_session["res://a_file_reverted_elsewhere.tscn"] = true
			_refresh_changelists()
			await _selftest_drain_frames()
			var stale_dropped: bool = not _checked_out_this_session.has("res://a_file_reverted_elsewhere.tscn")
			var real_kept: bool = _checked_out_this_session.has(path)
			_log("[selftest] stale entry dropped=%s; really-open entry kept=%s (cache holds %d)"
					% [stale_dropped, real_kept, _checked_out_this_session.size()])
			_log("[selftest] %s: opened-cache" % ("PASS" if stale_dropped and real_kept else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-connection-store":
			# Server-independent: the connection overrides round-trip through
			# the per-user store, a second project doesn't clobber the first,
			# and anything left in the old in-project location is moved out
			# and blanked - that location is a file inside .godot/, which a
			# team can submit by accident.
			var settings := EditorInterface.get_editor_settings()
			var store := _connection_store_path()
			var saved_port := _override_port
			var saved_user := _override_user
			var saved_client := _override_client

			_override_port = "ssl:example:1666"
			_override_user = "alice"
			_override_client = "alice_ws"
			_save_connection_overrides()
			_override_port = ""
			_override_user = ""
			_override_client = ""
			_load_connection_overrides()
			var round_trip: bool = _override_port == "ssl:example:1666" \
					and _override_user == "alice" and _override_client == "alice_ws"

			# A second project must not overwrite the first project's section.
			var other := ConfigFile.new()
			other.load(store)
			other.set_value("some_other_project_hash", "user", "bob")
			other.save(store)
			_load_connection_overrides()
			var kept_separate: bool = _override_user == "alice"

			# Migration: clear the new store for this project, put values in
			# the old place, and load.
			var cfg := ConfigFile.new()
			cfg.load(store)
			cfg.erase_section(_project_store_section())
			cfg.save(store)
			settings.set_project_metadata(SETTINGS_SECTION, "override_user", "legacy_user")
			_override_user = ""
			_load_connection_overrides()
			var migrated: bool = _override_user == "legacy_user"
			var old_cleared: bool = String(settings.get_project_metadata(
					SETTINGS_SECTION, "override_user", "")).is_empty()
			var in_new_store := ConfigFile.new()
			in_new_store.load(store)
			var landed: bool = String(in_new_store.get_value(
					_project_store_section(), "user", "")) == "legacy_user"

			# Put the real settings back, and take the test data out.
			_override_port = saved_port
			_override_user = saved_user
			_override_client = saved_client
			_save_connection_overrides()
			var cleanup := ConfigFile.new()
			cleanup.load(store)
			cleanup.erase_section("some_other_project_hash")
			cleanup.save(store)

			_log("[selftest] store=%s" % store)
			_log("[selftest] round-trip=%s kept-separate=%s migrated=%s old-cleared=%s landed-in-new=%s"
					% [round_trip, kept_separate, migrated, old_cleared, landed])
			var ok: bool = round_trip and kept_separate and migrated and old_cleared and landed
			_log("[selftest] %s: connection-store" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-plugin-prompt":
			# Live: run the startup check for real. Meant for a project whose
			# project.godot is in Perforce while the addon folder is not -
			# it reports what the check decided either way, and asserts it
			# only opens the plugin when the plugin was actually missing.
			var plugin_cfg := ProjectSettings.globalize_path(
					_plugin_dir().path_join("plugin.cfg"))
			var before := await _is_in_depot(plugin_cfg)
			_selftest_mode = false # the whole point is to let the check run
			EditorInterface.get_editor_settings().set_project_metadata(
					SETTINGS_SECTION, "plugin_add_declined", false)
			_selftest_auto_answer = "confirm"
			await _check_plugin_tracked()
			await _selftest_drain_frames()
			var after := await _is_in_depot(plugin_cfg)
			_log("[selftest] plugin in depot before=%s after=%s" % [before, after])
			_log("[selftest] %s: plugin-prompt" % ("PASS" if after else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-plugin-tracked":
			# Live and read-only: the three questions the startup check asks -
			# where the plugin lives, whether a path is in the depot, and
			# whether P4IGNORE covers it. A path p4 has never heard of must
			# read as "not in the depot", which only works because a bare
			# "no such file(s)" message yields no tagged record.
			var plugin_res := _plugin_dir()
			var plugin_dir := ProjectSettings.globalize_path(plugin_res)
			var project_file := ProjectSettings.globalize_path("res://project.godot")
			var absent := ProjectSettings.globalize_path("res://p4godot_no_such_file.txt")
			var project_tracked := await _is_in_depot(project_file)
			var absent_tracked := await _is_in_depot(absent)
			var plugin_tracked := await _is_in_depot(plugin_dir.path_join("plugin.cfg"))
			var godot_dir_ignored := await _p4_path_ignored(
					ProjectSettings.globalize_path("res://.godot/x"))
			var project_ignored := await _p4_path_ignored(project_file)
			_log("[selftest] plugin dir=%s" % plugin_res)
			_log("[selftest] in-depot: project.godot=%s plugin.cfg=%s absent-file=%s"
					% [project_tracked, plugin_tracked, absent_tracked])
			_log("[selftest] ignored: .godot/x=%s project.godot=%s"
					% [godot_dir_ignored, project_ignored])
			var ok: bool = plugin_res.ends_with("/p4godot") and project_tracked \
					and not absent_tracked and godot_dir_ignored and not project_ignored
			_log("[selftest] %s: plugin-tracked" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-reconcile-report":
			# Live and read-only: exactly what the Reconcile dialog would say
			# about this workspace right now - the files, the per-action
			# counts, and anything Perforce says it won't open. Opens nothing,
			# so it is safe to run against a workspace in any state.
			var result: Dictionary = await _p4_exec(["-ztag", "reconcile", "-n", _project_scope()])
			var records := _parse_ztag(result)
			var found := _summarize_reconcile(records)
			var refused := _refusals(result)
			_log("[selftest] reconcile would open %d file(s): add=%d edit=%d delete=%d"
					% [found.names.size(), found.adds, found.edits, found.deletes])
			for n in found.names:
				_log("[selftest]   %s" % n)
			_log("[selftest] refused=%d locked=%s" % [refused.count, refused.locked])
			for refusal_line in refused.lines:
				_log("[selftest]   ! %s" % refusal_line)
			# The invariant the dock depends on: every record it counts is a
			# real file with an action. A p4 message parsed as a record breaks
			# this, and used to show up as a file to edit that could never be
			# opened.
			var well_formed := true
			for rec in records:
				if String(rec.get("clientFile", "")).is_empty() \
						or String(rec.get("action", "")).is_empty():
					well_formed = false
					_log("[selftest] malformed record: %s" % [rec])
			_log("[selftest] %s: reconcile-report" % ("PASS" if well_formed else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-get-latest="):
			# Live: the real Get Latest flow against a workspace that is
			# genuinely behind. STAGE IT OUTSIDE GODOT first - a revision
			# specifier can't travel through _p4_exec, which escapes the `#` in
			# a path argument (for files really named that):
			#
			#   p4 sync <file>#1                       ordinary case
			#   p4 sync <file>#1; chmod +w; append     the case sync -n cannot
			#                                          predict - changed on
			#                                          disk, not checked out
			#   p4 sync <file>#1; p4 edit <file>       checked out and behind:
			#                                          p4 leaves the file alone
			#                                          and wants a resolve
			#
			# Then restore with `p4 revert <file>` (third case) and
			# `p4 sync -f <file>`. The test accepts any of the three and asserts
			# the outcome that staging demands, so one test covers all of them;
			# it fails if nothing was staged at all, because "already up to
			# date" would otherwise pass for free. Note the third staging
			# produces NO preview record - only a message - which is why the
			# staging check has to consult the notes as well as the records.
			# Pass a `.gd` as well as a `.tscn` across runs: scripts take the
			# _reload_script path, which is the one with the CACHE_MODE_IGNORE
			# subtlety, and a scene that only ever loads as a scene never
			# exercises it.
			var path := arg.substr("--p4-selftest-get-latest=".length())
			_selftest_auto_answer = "confirm"
			var ext := path.get_extension().to_lower()
			if ext == "tscn" or ext == "scn":
				EditorInterface.open_scene_from_path(path)
				await _selftest_drain_frames()
			elif ext == "gd" or ext == "cs":
				var scr := load(path) as Script
				if scr:
					EditorInterface.edit_script(scr)
					await _selftest_drain_frames()
			var was_open: bool = _open_editor_files().has(path)
			var before: Dictionary = await _p4_exec(["-ztag", "sync", "-n", _project_scope()])
			var staged := _summarize_sync(_parse_ztag(before))
			var staged_notes := _sync_notes(before)
			var checked_out_behind: bool = int(staged_notes.opened_behind) > 0
			_log("[selftest] staged: %d record(s) behind head %s, %d checked-out-and-behind (open in editor=%s)"
					% [staged.names.size(), staged.names, staged_notes.opened_behind, was_open])
			var report := await _get_latest_flow()
			await _selftest_drain_frames()
			_log("[selftest] report: %s" % report.replace("\n", " | "))
			var still_behind := _summarize_sync(_parse_ztag(
					await _p4_exec(["-ztag", "sync", "-n", _project_scope()])))
			_log("[selftest] after the flow, %d file(s) still behind: %s"
					% [still_behind.names.size(), still_behind.names])
			var was_staged: bool = staged.names.has(path) or checked_out_behind
			var came_up_to_date: bool = not still_behind.names.has(path)
			var refusal_reported: bool = report.contains("would not overwrite") \
					and report.contains(path)
			var resolve_reported: bool = report.contains("two versions combined") \
					and report.contains(path)
			var outcome := ""
			var outcome_ok := false
			if checked_out_behind:
				# p4 never overwrites a file you have checked out. It moves the
				# have revision and wants a resolve, and the report must say so
				# - left unsaid, the file silently can't be submitted.
				outcome_ok = resolve_reported
				outcome = "resolve reported"
			elif not came_up_to_date:
				# A file p4 refused to overwrite MUST still be behind - that is
				# the protection working - and the report must name it.
				outcome_ok = refusal_reported
				outcome = "refusal reported"
			else:
				outcome_ok = true
				outcome = "downloaded and reloaded"
			var reload_ok: bool = not (was_open and came_up_to_date and not checked_out_behind) \
					or report.contains("reloaded")
			if not was_staged:
				_log("[selftest] FAIL: get-latest - '%s' was not behind head; stage it first (see the source comment)" % path)
			elif not outcome_ok:
				_log("[selftest] FAIL: get-latest - expected '%s' and the report doesn't say it" % outcome)
			elif not reload_ok:
				_log("[selftest] FAIL: get-latest - the open tab was not reloaded onto the downloaded version")
			else:
				_log("[selftest] PASS: get-latest (%s)" % outcome)
			get_tree().quit()
			return
		if arg == "--p4-selftest-external-scan":
			# Live: a file another program dropped into the workspace must be
			# found by the focus-in scan and offered for checkout, and a set
			# the user declined must not ask again. Self-cleaning: it adds its
			# own scratch file, then reverts and deletes it.
			var rel := "res://p4godot_external_%d.txt" % Time.get_unix_time_from_system()
			var global := ProjectSettings.globalize_path(rel)
			var f := FileAccess.open(rel, FileAccess.WRITE)
			f.store_string("written by a program that knows nothing about Perforce\n")
			f.close()
			detect_external_checkbox.set_pressed_no_signal(true)
			auto_open_checkbox.set_pressed_no_signal(false)

			# The focus notification is what drives the scan in normal use, and
			# a headless session never gets a real one. Propagating it by hand
			# at least proves it reaches this plugin node and starts a scan
			# (the scan stamps _external_scan_last_msec when it finishes).
			_selftest_auto_answer = "cancel"
			_external_scan_last_msec = -EXTERNAL_SCAN_MIN_INTERVAL_MSEC
			var stamp_before := _external_scan_last_msec
			get_tree().root.propagate_notification(NOTIFICATION_APPLICATION_FOCUS_IN)
			await _selftest_drain_frames()
			var focus_scanned := _external_scan_last_msec != stamp_before
			_log("[selftest] focus notification started a scan: %s" % focus_scanned)
			_external_scan_dismissed = ""

			# The scan reconciles everything it finds, and this workspace can
			# hold unrelated changes - narrow it to our own file.
			var preview := await _reconcile_preview()
			var found := false
			for rec in preview:
				if _local_to_res(String(rec.get("clientFile", ""))) == rel:
					found = true
			_log("[selftest] reconcile preview saw the new file: %s" % found)

			var one_file := {"locals": [global], "names": [rel],
					"adds": 1, "edits": 0, "deletes": 0}
			var no_refusals := {"count": 0, "lines": [], "locked": false}

			# Decline once: the file stays unopened and the set is remembered,
			# so the same set can't ask again on every alt-tab.
			_selftest_auto_answer = "cancel"
			await _offer_external_changes(one_file, no_refusals)
			await _selftest_drain_frames()
			var opened_after_decline := not _parse_ztag(await _p4_exec(["-ztag", "opened", global])).is_empty()
			var remembered := not _external_scan_dismissed.is_empty()

			# Asked again with the identical set: the dialog must not reappear,
			# so even a "confirm" answer leaves the file unopened.
			_selftest_auto_answer = "confirm"
			await _offer_external_changes(one_file, no_refusals)
			await _selftest_drain_frames()
			var still_unopened := _parse_ztag(await _p4_exec(["-ztag", "opened", global])).is_empty()

			# A fresh set does ask, and accepting opens the file for add.
			_external_scan_dismissed = ""
			await _offer_external_changes(one_file, no_refusals)
			await _selftest_drain_frames()
			var opened := not _parse_ztag(await _p4_exec(["-ztag", "opened", global])).is_empty()

			await _p4_exec_logged(["revert", global])
			DirAccess.remove_absolute(global)
			_log("[selftest] preview-found=%s opened-after-decline=%s remembered=%s still-unopened-on-repeat=%s opened-after-accept=%s"
					% [found, opened_after_decline, remembered, still_unopened, opened])
			var ok: bool = found and focus_scanned and not opened_after_decline \
					and remembered and still_unopened and opened
			_log("[selftest] %s: external-scan" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-history-gate="):
			# Live: a history_changed with no edit (clear_history, as a tab switch
			# does) must NOT check the scene out; a real commit_action must.
			# Leaves the scene opened - revert afterwards.
			var path := arg.substr("--p4-selftest-history-gate=".length())
			var global := ProjectSettings.globalize_path(path)
			_selftest_auto_answer = "confirm"
			auto_checkout_checkbox.set_pressed_no_signal(true)
			await _selftest_make_current(path)
			await _selftest_drain_frames()
			var ur := get_undo_redo()
			ur.clear_history(ur.get_object_history_id(EditorInterface.get_edited_scene_root()), false)
			await _selftest_drain_frames()
			var opened_after_clear := not await _needs_checkout(global)
			await _selftest_simulate_edit(path)
			await _selftest_drain_frames()
			var opened_after_edit := not await _needs_checkout(global)
			_log("[selftest] opened after clear_history=%s, after real edit=%s" % [opened_after_clear, opened_after_edit])
			_log("[selftest] %s: history-gate" % ("PASS" if not opened_after_clear and opened_after_edit else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-fs-checkout="):
			# Live: the FileSystem-dock "P4: Check Out" path (an imported asset's
			# .import comes along). Leaves the files opened - revert afterwards.
			var path := arg.substr("--p4-selftest-fs-checkout=".length())
			await _checkout_path(path)
			var both := true
			for p: String in [path, path + ".import"]:
				var opened := not await _needs_checkout(ProjectSettings.globalize_path(p))
				_log("[selftest] %s opened=%s" % [p, opened])
				both = both and opened
			_log("[selftest] %s: fs-checkout" % ("PASS" if both else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-checkout="):
			var path := arg.substr("--p4-selftest-checkout=".length())
			_log("[selftest] Forcing checkout of '%s'" % path)
			if not await _needs_checkout(ProjectSettings.globalize_path(path)):
				_log("[selftest] no checkout needed")
			else:
				await _do_checkout(path)
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-reload="):
			var path := arg.substr("--p4-selftest-reload=".length())
			_log("[selftest] Forcing reload-from-disk of '%s'" % path)
			await _reload_path(path)
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-simulate-edit="):
			var path := arg.substr("--p4-selftest-simulate-edit=".length())
			await _selftest_simulate_edit(path)
			await _selftest_drain_frames()
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-save-checkout="):
			var path := arg.substr("--p4-selftest-save-checkout=".length())
			# set_pressed_no_signal: don't let test toggles persist into the
			# user's real project metadata via _on_setting_toggled.
			auto_checkout_checkbox.set_pressed_no_signal(false)
			checkout_on_save_checkbox.set_pressed_no_signal(true)
			await _selftest_simulate_edit(path)
			# The edit-time flow is async - wait for it to settle so the
			# pending-for-save report below is deterministic.
			await _selftest_drain_frames()
			_log("[selftest] pending-for-save: %s" % [_pending_save_checkout.keys()])
			await _selftest_make_current(path)
			EditorInterface.save_scene()
			await _selftest_drain_frames()
			await _selftest_report_opened(path)
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-save-rescue="):
			var path := arg.substr("--p4-selftest-save-rescue=".length())
			auto_checkout_checkbox.set_pressed_no_signal(false)
			checkout_on_save_checkbox.set_pressed_no_signal(false)
			await _selftest_simulate_edit(path)
			await _selftest_make_current(path)
			var save_err := EditorInterface.save_scene()
			_log("[selftest] save_scene() returned error code %d" % save_err)
			await _selftest_drain_frames()
			await _selftest_report_opened(path)
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-save-current="):
			# Open and save a scene WITHOUT editing it - exercises companion-
			# resource writes (a load-modified .tres gets written on every
			# scene save) without touching the scene's own content.
			var path := arg.substr("--p4-selftest-save-current=".length())
			await _selftest_make_current(path)
			EditorInterface.save_scene()
			await _selftest_drain_frames()
			await _selftest_drain_frames()
			get_tree().quit()
			return
		elif arg.begins_with("--p4-selftest-save-rescue-multi="):
			# Comma-separated scene list; verifies Save All failures collapse
			# into ONE batched rescue dialog that checks out all of them.
			var paths := arg.substr("--p4-selftest-save-rescue-multi=".length()).split(",")
			auto_checkout_checkbox.set_pressed_no_signal(false)
			checkout_on_save_checkbox.set_pressed_no_signal(false)
			for p in paths:
				await _selftest_simulate_edit(p)
			# Let the async edit-time flows settle before saving, so the save
			# pass starts from the same state the old synchronous code had.
			await _selftest_drain_frames()
			EditorInterface.save_all_scenes()
			await _selftest_drain_frames()
			await _selftest_drain_frames()
			for p in paths:
				await _selftest_report_opened(p)
			get_tree().quit()
			return


## Self-tests only: whether the OS would refuse a write to this file.
func _selftest_is_read_only(global_path: String) -> bool:
	if OS.get_name() == "Windows":
		return FileAccess.get_read_only_attribute(global_path)
	return FileAccess.get_unix_permissions(global_path) & FileAccess.UNIX_WRITE_OWNER == 0


## Self-tests only: a new pending changelist holding `local_path` (or empty
## when that is ""). Returns its number.
func _create_selftest_change(description: String, local_path: String) -> String:
	var spec := "Change: new\n\nDescription:\n\t%s\n" % description
	if not local_path.is_empty():
		var opened := _parse_ztag(await _p4_exec(["-ztag", "opened", local_path]))
		if not opened.is_empty():
			spec += "Files:\n\t%s\n" % String(opened[0].get("depotFile", ""))
	return _created_change_in(await _p4_exec_spec(["change", "-i"], spec))


func _selftest_menu_labels() -> String:
	var labels: Array = []
	for i in range(context_menu.item_count):
		labels.append(context_menu.get_item_text(i))
	return " | ".join(labels)


func _selftest_simulate_edit(path: String) -> void:
	_log("[selftest] Opening '%s' and simulating a real commit_action()..." % path)
	EditorInterface.open_scene_from_path(path)
	await get_tree().process_frame
	await get_tree().process_frame
	# Main::start auto-opens the project's MAIN scene at a nondeterministic
	# point during boot (see _selftest_make_current) - it can steal the
	# current tab between our open and our commit, making the edit land on
	# the wrong scene. Refocus until the requested scene is actually current.
	var scene_root := EditorInterface.get_edited_scene_root()
	for attempt in range(10):
		if scene_root != null and scene_root.get_scene_file_path() == path:
			break
		EditorInterface.open_scene_from_path(path)
		await get_tree().process_frame
		await get_tree().process_frame
		scene_root = EditorInterface.get_edited_scene_root()
	if scene_root == null or scene_root.get_scene_file_path() != path:
		_log("[selftest] FAILED: couldn't make '%s' the edited scene" % path)
		return
	# A harmless do/undo pair (universal Object meta, nothing type-specific):
	# what matters is that commit_action() fires history_changed and our
	# handler reacts, not that the edit does anything meaningful.
	var ur := get_undo_redo()
	ur.create_action("[P4 selftest] dummy edit")
	ur.add_do_method(scene_root, "set_meta", "_p4_selftest", true)
	ur.add_undo_method(scene_root, "remove_meta", "_p4_selftest")
	ur.commit_action()
	await get_tree().process_frame
	_log("[selftest] commit_action() done for '%s'" % path)


## Re-focuses `path` as the current scene tab. Needed because when the editor
## session restored no tabs, Main::start auto-opens the project's MAIN scene
## (main.cpp), stealing current-tab focus from the scene a test opened during
## plugin init - EditorInterface.save_scene() would then save the main scene
## instead of the scene under test.
func _selftest_make_current(path: String) -> void:
	EditorInterface.open_scene_from_path(path)
	await get_tree().process_frame
	await get_tree().process_frame
	var root := EditorInterface.get_edited_scene_root()
	_log("[selftest] current scene at save time: '%s'" % (root.get_scene_file_path() if root else "<none>"))


## Prompt resolution, p4 round trips, and rescue probes all run as independent
## un-awaited coroutines off the signal handlers. Fixed frame counts can't
## bound that anymore: wait until the p4 worker, save probes, rescue queue,
## and dialogs have ALL been idle for a stretch of consecutive frames (a
## momentary lull between pipeline stages must not end the wait early), with a
## hard time cap so a regression fails loudly instead of hanging the harness.
func _selftest_drain_frames() -> void:
	var deadline := Time.get_ticks_msec() + 20000
	var idle_streak := 0
	while idle_streak < 10 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if _identity_checked and _p4_inflight == 0 and _rescue_probes_inflight == 0 \
				and not _dialog_busy and not _rescue_scheduled and _rescue_paths.is_empty():
			idle_streak += 1
		else:
			idle_streak = 0
	if idle_streak < 10:
		_log("[selftest] WARNING: timed out waiting for idle (inflight=%d probes=%d dialog=%s)"
				% [_p4_inflight, _rescue_probes_inflight, _dialog_busy])
	_log("[selftest] done waiting.")


func _selftest_report_opened(path: String) -> void:
	if not await _needs_checkout(ProjectSettings.globalize_path(path)):
		_log("[selftest] PASS: '%s' is opened for edit in our workspace." % path)
	else:
		_log("[selftest] FAIL: '%s' is NOT opened in our workspace." % path)
