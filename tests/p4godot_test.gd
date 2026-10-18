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
		if arg == "--p4-selftest-history":
			# Server-independent: `p4 -Mj -ztag filelog -l -t -i` output captured
			# from p4d 2026.1 - a file moved from f.txt to g.txt, a description
			# with a blank line in it (which ends a tagged record early), and the
			# error object p4 prints for a file that was never submitted.
			var json := "\n".join([
				'{"action0":"edit","action1":"move/add","change0":"6","change1":"4","client0":"dev-ws","client1":"dev-ws","depotFile":"//game/main/g.txt","desc0":"para one\\n\\npara two\\n","desc1":"rename","fileSize0":"12","fileSize1":"8","how1,0":"moved from","file1,0":"//game/main/f.txt","srev1,0":"#none","erev1,0":"#2","rev0":"2","rev1":"1","time0":"1792084541","time1":"1792084504","type0":"text","type1":"text","user0":"dev","user1":"dev"}',
				'{"action0":"edit","action1":"add","change0":"3","change1":"2","client0":"dev-ws","client1":"dev-ws","depotFile":"//game/main/f.txt","desc0":"edit","desc1":"first","fileSize0":"8","fileSize1":"6","how0,0":"moved into","file0,0":"//game/main/g.txt","rev0":"2","rev1":"1","time0":"1792084504","time1":"1792084504","type0":"text","type1":"binary","user0":"dev","user1":"amy"}',
			])
			var parsed := _filelog_revisions(json + "\r\n")
			var revs: Array = parsed.revs
			var order := revs.map(func(r: Dictionary) -> String: return _history_rev_name(r, String(parsed.depot)))
			_log("[selftest] history order: %s" % [order])
			var parse_ok: bool = String(parsed.depot) == "//game/main/g.txt" and not parsed.untracked \
					and order == ["#2", "#1", "f.txt#2", "f.txt#1"] \
					and String(revs[0].desc) == "para one\n\npara two" \
					and String(revs[1].from) == "//game/main/f.txt" and String(revs[2].from) == "" \
					and int(revs[3].change) == 2 and String(revs[3].user) == "amy"
			var never := _filelog_revisions('{"code0":554768760,"data":"u.txt - file(s) not on client.\\n","generic":17,"severity":2}')
			var untracked_ok: bool = never.revs.is_empty() and bool(never.untracked)
			_log("[selftest] history parse=%s untracked=%s" % [parse_ok, untracked_ok])

			# What each selection allows. Index 2 is from before the move; 3 is
			# the first revision.
			var cur := String(parsed.depot)
			var one := _history_actions(revs, [0], cur, true)
			var two := _history_actions(revs, [3, 1], cur, true)
			var old := _history_actions(revs, [2], cur, true)
			var first := _history_actions(revs, [3], cur, true)
			var gone := _history_actions(revs, [1], cur, false)
			var none := _history_actions(revs, [], cur, true)
			var deleted: Array = revs.duplicate(true)
			deleted[1].action = "delete"
			var del := _history_actions(deleted, [0], cur, true)
			var have := _history_actions(revs, [0], cur, true, 2)
			var cut := _history_actions(revs, [3], cur, true, 0, true)
			var purged: Array = revs.duplicate(true)
			purged[1].action = "purge"
			var pur := _history_actions(purged, [0], cur, true)
			var more_ok: bool = not have.get.ok and String(have.get.reason).contains("already have") \
					and have.workspace.ok \
					and not cut.diff.ok and String(cut.diff.reason).contains("earliest revision shown") \
					and not pur.diff.ok and String(pur.diff.reason).contains("purged") \
					and int(parsed.most) == 2
			_log("[selftest] history have/cut-short/purged/most=%s" % more_ok)
			var acts_ok: bool = more_ok and one.diff.ok and one.diff.older == 1 and one.diff.newer == 0 \
					and one.workspace.ok and one.get.ok \
					and two.diff.ok and two.diff.older == 3 and two.diff.newer == 1 \
					and not two.workspace.ok and not two.get.ok \
					and old.diff.ok and not old.workspace.ok and not old.get.ok \
					and String(old.get.reason).contains("f.txt#2") \
					and not first.diff.ok and String(first.diff.reason).contains("first revision") \
					and not gone.workspace.ok and gone.get.ok \
					and not none.diff.ok \
					and not del.diff.ok and String(del.diff.reason).contains("deleted")
			_log("[selftest] history actions=%s" % acts_ok)

			var ident_ok := _diff2_identical("==== //a#2 (text) - //b#1 (text) ==== identical\r\n") \
					and not _diff2_identical("==== //a#1 (text) - //a#2 (text) ==== content\n@@ -1 +1 @@\n-a\n+b\n")
			# 2026-10-15 17:15 UTC, shown at UTC-7.
			var date_ok := _history_date(1792084504, -420) == "2026-10-15 10:15"
			_log("[selftest] history identical=%s date=%s (%s)" % [ident_ok, date_ok, _history_date(1792084504, -420)])

			# The window itself, filled from the parsed revisions.
			_build_history_window()
			_history_res_path = "res://g.txt"
			_history_depot_path = cur
			_history_revs = revs
			_history_have_rev = 1
			_populate_history()
			var rows := _history_tree.get_root().get_child_count()
			var have_ok := _history_tree.get_root().get_child(1).get_text(0) == "#1  (you have)"
			var first_selected := _history_selected() == [0]
			var detail_ok := _history_detail.text.contains("para two")
			_history_tree.get_root().get_child(2).select(0)
			_update_history_buttons()
			var two_rows := _history_diff_button.text == "Diff Selected" and _history_get_button.disabled
			_history_tree.deselect_all()
			_history_tree.get_root().get_child(2).select(0)
			_update_history_buttons()
			var old_row := not _history_diff_button.disabled and _history_get_button.disabled \
					and _history_get_button.tooltip_text.contains("before the file was moved")
			var ui_ok := rows == 4 and have_ok and first_selected and detail_ok and two_rows and old_row
			_log("[selftest] history window: rows=%d have=%s selected=%s detail=%s two=%s old=%s"
					% [rows, have_ok, first_selected, detail_ok, two_rows, old_row])
			var ok := parse_ok and untracked_ok and acts_ok and ident_ok and date_ok and ui_ok
			_log("[selftest] %s: history" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-shelves":
			# Server-independent: output captured from p4d 2026.1. `describe -S`
			# of two changelists in one call (one JSON object each; a move's
			# deleted half has no type or size; a description with a blank
			# line), and p4's message object, which is skipped.
			var json := "\n".join([
				'{"action0":"add","action1":"move/delete","action2":"move/add","action3":"edit","change":"7","changeType":"public","client":"dev-ws","depotFile0":"//game/main/added2.txt","depotFile1":"//game/main/n.txt","depotFile2":"//game/main/n_moved.txt","depotFile3":"//game/main/two.txt","desc":"Shelf A\\n\\nsecond paragraph\\n","digest0":"2832E21254F4D3B0ED755A827D07CE58","digest2":"C3BE117041A113540DEB0FF532B19543","digest3":"4FCC82A88EE38E0AA16C17F512C685C9","fileSize0":"6","fileSize2":"2","fileSize3":"12","rev0":"1","rev1":"1","rev2":"1","rev3":"2","shelved":"","status":"pending","time":"1792095163","type0":"text","type1":"text","type2":"text","type3":"text","user":"dev"}',
				'{"action0":"edit","change":"8","changeType":"public","client":"dev-ws","depotFile0":"//game/main/one.txt","desc":"Shelf B\\n","digest0":"3B5D5C3712955042212316173CCF37BE","fileSize0":"2","rev0":"1","shelved":"","status":"pending","time":"1792095163","type0":"binary+l","user":"mate"}',
				'{"code0":822155278,"data":"Invalid changelist number \'x\'.\\n","generic":1,"severity":3}',
			])
			var shelves := _shelf_records(json + "\r\n")
			var a: Dictionary = shelves[0] if shelves.size() > 0 else {}
			var parse_ok: bool = shelves.size() == 2 and String(a.change) == "7" \
					and String(a.desc) == "Shelf A\n\nsecond paragraph" and a.files.size() == 4 \
					and String(a.files[1].action) == "move/delete" and int(a.files[1].size) == 0 \
					and int(a.files[3].rev) == 2 and String(a.files[3].type) == "text" \
					and String(shelves[1].user) == "mate" and String(shelves[1].files[0].type) == "binary+l"
			_log("[selftest] shelves parse=%s" % parse_ok)

			# What an unshelve did, from the state afterwards plus p4's words
			# for the refusals (its output as measured, mate unshelving dev's
			# shelf, plus a refused overwrite naming the local path).
			var said := "\n".join([
				"//game/main/one.txt#1 - unshelved, opened for edit",
				"... //game/main/one.txt - must resolve //game/main/one.txt@=3 before submitting",
				"... //game/main/one.txt - also opened by dev@dev-ws",
				"//game/main/pic.png - can't edit exclusive file already opened",
				"... //game/main/pic.png - also opened by dev@dev-ws",
				"//game/main/two.txt#1 - unshelved, opened for edit",
				"... //game/main/two.txt - also opened by dev@dev-ws",
				"Can't clobber writable file C:/ws/mate\\three.txt",
				"//game/main/one.txt.bak - can't edit exclusive file already opened",
			])
			var wanted := ["//game/main/one.txt", "//game/main/pic.png", "//game/main/two.txt",
					"//game/main/three.txt", "//game/main/one.txt.b", "//game/main/four.txt"]
			var in_target := {
				"//game/main/one.txt": {"depotFile": "//game/main/one.txt", "unresolved": "", "haveRev": "1", "headRev": "1"},
				"//game/main/two.txt": {"depotFile": "//game/main/two.txt", "haveRev": "1", "headRev": "2"},
			}
			var report := _unshelve_report(wanted, in_target, said,
					{"//game/main/three.txt": "C:/ws/mate/three.txt"})
			var why := {}
			for r in report.refused:
				why[String(r.depot)] = String(r.why)
			var report_ok: bool = report.opened == ["//game/main/one.txt", "//game/main/two.txt"] \
					and report.resolve == ["//game/main/one.txt"] and report.behind == ["//game/main/two.txt"] \
					and report.refused.size() == 4 \
					and String(why.get("//game/main/pic.png", "")).contains("exclusive") \
					and String(why.get("//game/main/pic.png", "")).contains("dev@dev-ws") \
					and String(why.get("//game/main/three.txt", "")).contains("writable but isn't checked out") \
					and String(why.get("//game/main/one.txt.b", "")).contains("didn't say why") \
					and String(why.get("//game/main/four.txt", "")).contains("didn't say why")
			# A file already open in the target counts only when p4 says it
			# unshelved it, and a file checked out before isn't "behind" because
			# of the shelf.
			var target_out := "//d/kept.txt#2 - unshelved, opened for edit\n//d/refused.txt - can't unshelve, it's opened for edit"
			var target_state := {"//d/kept.txt": {"haveRev": "1", "headRev": "2"},
					"//d/refused.txt": {"haveRev": "1", "headRev": "1"}}
			var already := _unshelve_report(["//d/kept.txt", "//d/refused.txt"], target_state, target_out, {},
					{"//d/kept.txt": "9", "//d/refused.txt": "9"}, "9")
			var already_ok: bool = already.opened == ["//d/kept.txt"] and already.behind.is_empty() \
					and already.refused.size() == 1 and String(already.refused[0].why).contains("can't unshelve")
			report_ok = report_ok and already_ok
			_log("[selftest] shelves unshelve-report=%s already-in-target=%s %s" % [report_ok, already_ok, why])

			# What can be done with each shelved file.
			var edit_acts := _shelf_file_actions(a.files[3], true, true)
			var del_acts := _shelf_file_actions(a.files[1], true, true)
			var unmapped := _shelf_file_actions(a.files[3], false, false)
			var missing := _shelf_file_actions(a.files[0], true, false)
			var acts_ok: bool = edit_acts.base.ok and edit_acts.workspace.ok \
					and not del_acts.base.ok and String(del_acts.base.reason).contains("deletes") \
					and not del_acts.workspace.ok \
					and unmapped.base.ok and not unmapped.workspace.ok \
					and String(unmapped.workspace.reason).contains("isn't part of your workspace") \
					and missing.base.ok and not missing.workspace.ok
			_log("[selftest] shelves file-actions=%s" % acts_ok)

			# A shelved add shows beside an empty left pane: every row an add.
			var added_lines := _split_lines("one\ntwo\nthree\n")
			var rows := _align_diff(PackedStringArray(), added_lines,
					_parse_unified_hunks(_line_diff_unified(PackedStringArray(), added_lines)))
			var kinds := rows.map(func(r: Dictionary) -> String: return String(r.kind))
			var add_ok: bool = kinds == ["add", "add", "add"] and String(rows[2].right) == "three" \
					and _line_diff_unified(PackedStringArray(), PackedStringArray()) == ""
			# The line diff behind it: for generated pairs, its steps rebuild
			# both sides, and it keeps as many lines as the longest common
			# subsequence (so it is a shortest diff). Then one past the effort
			# cap, which falls back to remove-then-add but still rebuilds both.
			var rng := RandomNumberGenerator.new()
			rng.seed = 4711
			var lcs_len := func(x: PackedStringArray, y: PackedStringArray) -> int:
				var prev := PackedInt32Array()
				prev.resize(y.size() + 1)
				for i in x.size():
					var cur := PackedInt32Array()
					cur.resize(y.size() + 1)
					for j in y.size():
						cur[j + 1] = prev[j] + 1 if x[i] == y[j] else maxi(prev[j + 1], cur[j])
					prev = cur
				return prev[y.size()]
			var rebuilds := func(x: PackedStringArray, y: PackedStringArray, ops: Array) -> bool:
				var rx := PackedStringArray()
				var ry := PackedStringArray()
				var i := 0
				var j := 0
				for op: String in ops:
					if op != "add":
						if i >= x.size():
							return false
						rx.append(x[i])
						i += 1
					if op != "del":
						if j >= y.size():
							return false
						ry.append(y[j])
						j += 1
					if op == "ctx" and x[i - 1] != y[j - 1]:
						return false
				return rx == x and ry == y
			var myers_ok := true
			for case_i in 300:
				var x := PackedStringArray()
				var y := PackedStringArray()
				for _k in rng.randi_range(0, 25):
					x.append("abcde"[rng.randi_range(0, 4)])
				for _k in rng.randi_range(0, 25):
					y.append("abcde"[rng.randi_range(0, 4)])
				var ops := _line_diff_ops(x, y)
				var kept := ops.count("ctx")
				if not rebuilds.call(x, y, ops) or kept != lcs_len.call(x, y):
					myers_ok = false
					_log("[selftest] line diff wrong for %s -> %s: %s" % [x, y, ops])
					break
			var big_x := PackedStringArray()
			var big_y := PackedStringArray()
			for k in LINE_DIFF_MAX_EDITS + 10:
				big_x.append("x%d" % k)
				big_y.append("y%d" % k)
			var capped := _line_diff_ops(big_x, big_y)
			var cap_ok: bool = rebuilds.call(big_x, big_y, capped) and capped.count("ctx") == 0
			_log("[selftest] shelves added-file rows=%s %s, line diff shortest=%s, past the cap=%s"
					% [add_ok, kinds, myers_ok, cap_ok])
			add_ok = add_ok and myers_ok and cap_ok

			# The dock's menus for changelists with and without a shelf.
			_populate_context_menu({"type": "cl", "change": "9", "file_count": 2, "shelved_count": 3})
			var both := _selftest_menu_labels()
			_populate_context_menu({"type": "cl", "change": "9", "file_count": 0, "shelved_count": 3})
			var shelf_only := _selftest_menu_labels()
			_populate_context_menu({"type": "cl", "change": "9", "file_count": 0, "shelved_count": 0})
			var empty := _selftest_menu_labels()
			_populate_context_menu({"type": "cl", "change": "default", "file_count": 2})
			var dflt := _selftest_menu_labels()
			_populate_context_menu({"type": "shelved_file", "change": "9", "depot_path": "//d/a.gd"})
			var shelved_row := _selftest_menu_labels()
			_log("[selftest] shelves menus: both=[%s] shelf-only=[%s] empty=[%s] default=[%s] file=[%s]"
					% [both, shelf_only, empty, dflt, shelved_row])
			var menus_ok: bool = both.contains("Update Shelf...") and both.contains("Shelve and Revert...") \
					and both.contains("Unshelve Files...") and not both.contains("Delete Changelist") \
					and not shelf_only.contains("Shelve Files...") and not shelf_only.contains("Shelve and Revert") \
					and not shelf_only.contains("Update Shelf") \
					and shelf_only.contains("Unshelve Files...") and shelf_only.contains("Delete Shelved Files...") \
					and not shelf_only.contains("Delete Changelist") \
					and empty.contains("Delete Changelist") and not empty.contains("helve") \
					and dflt.contains("Shelve Files...") and not dflt.contains("Unshelve") \
					and shelved_row.contains("Diff vs Base") and shelved_row.contains("Unshelve This File...")

			# The tree: a changelist's shelf is its own row, under it the files.
			_rebuild_tree({"available": true, "changelists": [
				{"change": "default", "desc": "", "files": [], "shelved": []},
				{"change": "9", "desc": "wip", "files": [{"res_path": "res://a.gd", "depot_path": "//d/a.gd",
						"action": "edit", "change": "9"}],
				"shelved": [{"res_path": "res://a.gd", "depot_path": "//d/a.gd", "action": "edit", "rev": 1,
						"type": "text", "size": 3, "change": "9"},
						{"res_path": "", "depot_path": "//other/b.gd", "action": "add", "rev": 1,
						"type": "text", "size": 3, "change": "9"}]}]})
			var cl9 := tree.get_root().get_child(1)
			var shelf_row := cl9.get_child(1) if cl9.get_child_count() > 1 else null
			var tree_ok: bool = shelf_row != null and shelf_row.get_text(0) == "Shelved" \
					and shelf_row.get_child_count() == 2 \
					and String(shelf_row.get_child(1).get_text(0)) == "//other/b.gd" \
					and String(shelf_row.get_child(0).get_metadata(0).type) == "shelved_file" \
					and int(cl9.get_metadata(0).shelved_count) == 2
			_log("[selftest] shelves menus=%s tree=%s" % [menus_ok, tree_ok])

			# The Shelves window, filled from the parsed shelves.
			_build_shelves_window()
			_shelves_list = shelves
			_populate_shelves_list("")
			var listed := _shelves_tree.get_root().get_child_count()
			var shelf: Dictionary = a.duplicate(true)
			for f: Dictionary in shelf.files:
				f["local"] = "" if String(f.depot).ends_with("two.txt") else "C:/nowhere/" + String(f.depot).get_file()
				f["res_path"] = ""
			_show_shelf_files(shelf)
			var nothing_picked := _shelf_diff_button.disabled and _shelf_unshelve_button.text == "Unshelve All..." \
					and not _shelf_unshelve_button.disabled and _shelf_detail.text.contains("second paragraph")
			_shelf_files_tree.get_root().get_child(1).select(0)
			_update_shelf_buttons()
			var deleted_row := _shelf_diff_button.disabled and _shelf_diff_button.tooltip_text.contains("deletes") \
					and _shelf_unshelve_button.text == "Unshelve 1 Selected..."
			_shelf_files_tree.deselect_all()
			_shelf_files_tree.get_root().get_child(3).select(0)
			_update_shelf_buttons()
			var unmapped_row := not _shelf_diff_button.disabled and _shelf_workspace_button.disabled \
					and _shelf_workspace_button.tooltip_text.contains("isn't part of your workspace")
			var ui_ok := listed == 2 and nothing_picked and deleted_row and unmapped_row
			_log("[selftest] shelves window: listed=%d none=%s deleted=%s unmapped=%s"
					% [listed, nothing_picked, deleted_row, unmapped_row])
			var ok := parse_ok and report_ok and acts_ok and add_ok and menus_ok and tree_ok and ui_ok
			_log("[selftest] %s: shelves" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-watch":
			# Server-independent: the decisions behind the workspace watcher -
			# which files a pass asks Perforce about, what to do with opened
			# files whose disk state contradicts the open, the allwrite spec
			# edit, and the dock's "Changed, not checked out" rows.
			var checks := {}
			var now := 1000000
			var walked := {
				"a": ["A", now - 100], # new: never checked
				"b": ["B", now - 100], # same time, checked well after its write: trusted
				"c": ["C", now - 100], # its time changed
				"d": ["D", now - 100], # checked within the settle window of its write
				"e": ["E", now - 1],   # still being written
				"f": ["F", now - 100], # opened: Perforce already tracks it
			}
			var cache := {
				"b": ["B", now - 100, now - 50, ""],
				"c": ["C", now - 200, now - 150, ""],
				"d": ["D", now - 100, now - 99, ""],
				"g": ["G", now - 300, now - 250, ""],       # gone from disk: asked once
				"h": ["H", -1, now - 250, "delete"],        # known gone, asked lately: not asked again
				"i": ["I", -1, now - WATCH_MISSING_RECHECK_SEC - 10, "delete"], # known gone, asked long ago
				"f": ["F", now - 300, now - 250, "edit"],
			}
			var plan := _watch_candidates(walked, cache, {"f": true}, now)
			var check: Array = plan.check.duplicate()
			check.sort()
			_log("[selftest] candidates: %s unsettled=%s" % [check, plan.unsettled])
			checks["candidates are new, changed, too-soon and gone files"] = check == ["A", "C", "D", "G", "I"] \
					and bool(plan.unsettled)
			checks["a settled, quiet workspace checks nothing"] = (_watch_candidates({"b": ["B", now - 100]},
					{"b": ["B", now - 100, now - 50, "edit"]}, {}, now).check as Array).is_empty()

			var on_disk := {"C:/w/added_here.txt": true, "C:/w/del_back.txt": true, "C:/w/kept.txt": true}
			var exists := func(p: String) -> bool: return on_disk.has(p)
			var records := [
				{"depotFile": "//d/added_gone.txt", "clientFile": "C:/w/added_gone.txt", "action": "add", "change": "default"},
				{"depotFile": "//d/added_here.txt", "clientFile": "C:/w/added_here.txt", "action": "add", "change": "default"},
				{"depotFile": "//d/del_back.txt", "clientFile": "C:/w/del_back.txt", "action": "delete", "change": "7", "headType": "text+w"},
				{"depotFile": "//d/del_gone.txt", "clientFile": "C:/w/del_gone.txt", "action": "delete", "change": "7"},
				{"depotFile": "//d/new.txt", "clientFile": "C:/w/new.txt", "action": "move/add", "change": "8", "movedFile": "//d/old.txt"},
				{"depotFile": "//d/old.txt", "clientFile": "C:/w/old.txt", "action": "move/delete", "change": "8"},
				{"depotFile": "//d/edited.txt", "clientFile": "C:/w/edited.txt", "action": "edit", "change": "default"},
				# Deliberate states, which must be left alone: an add of a file that
				# never existed, a virtual branch, a `delete -k`.
				{"depotFile": "//d/never.txt", "clientFile": "C:/w/never.txt", "action": "add", "change": "default"},
				{"depotFile": "//d/virtual.txt", "clientFile": "C:/w/virtual.txt", "action": "branch", "change": "default"},
				{"depotFile": "//d/kept.txt", "clientFile": "C:/w/kept.txt", "action": "delete", "change": "default"},
			]
			var seen := {"c:/w/added_gone.txt": true, "c:/w/added_here.txt": true, "c:/w/del_back.txt": false,
					"c:/w/del_gone.txt": false, "c:/w/new.txt": true, "c:/w/never.txt": false,
					"c:/w/virtual.txt": true, "c:/w/kept.txt": true}
			var tidy := {}
			for step: Dictionary in _tidy_plan(records, exists, seen):
				tidy[String(step.local)] = step
			_log("[selftest] tidy plan: %s" % [tidy.keys()])
			checks["nothing is tidied without an earlier look"] = _tidy_plan(records, exists, {}).is_empty()
			checks["tidy plan names the three changes seen, not the deliberate states"] = tidy.size() == 3 \
					and String(tidy.get("C:/w/added_gone.txt", {}).get("kind", "")) == "add gone" \
					and String(tidy.get("C:/w/del_back.txt", {}).get("kind", "")) == "delete back" \
					and String(tidy.get("C:/w/del_back.txt", {}).get("change", "")) == "7" \
					and String(tidy.get("C:/w/del_back.txt", {}).get("type", "")) == "text+w" \
					and String(tidy.get("C:/w/new.txt", {}).get("kind", "")) == "move gone" \
					and String(tidy.get("C:/w/new.txt", {}).get("source", "")) == "C:/w/old.txt"

			var spec := "# A comment\nClient:\tdev-ws\n\nOptions:\tnoallwrite noclobber nocompress unlocked nomodtime normdir\n\nRoot:\tC:/w\n"
			var spec_on := _spec_with_allwrite(spec, true)
			checks["allwrite spec flips only that word, and back"] = spec_on.contains(
					"Options:\tallwrite noclobber nocompress unlocked nomodtime normdir") \
					and _spec_with_allwrite(spec_on, false) == spec \
					and _spec_with_allwrite("Client:\tx\n", true) == "Client:\tx\n"
			checks["+w filetypes"] = _type_is_writable("text+w") and _type_is_writable("binary+lw") \
					and not _type_is_writable("text") and not _type_is_writable("binary+l") \
					and not _type_is_writable("xtext")
			var chunks := _path_chunks(["aaaa", "bbbb", "cccc", "a-path-longer-than-the-budget"], 15)
			checks["path chunks stay under budget"] = chunks.size() == 3 and (chunks[0] as Array).size() == 2 \
					and (chunks[2] as Array) == ["a-path-longer-than-the-budget"]
			checks["nothing-to-do answers"] = _reconcile_had_nothing({"exit_code": 1, "output": [
					"Path 'C:/x' is not under client's root 'C:/w'.\nNo file(s) to reconcile.\n"]}) \
					and not _reconcile_had_nothing({"exit_code": 1, "output": [
					"Perforce client error:\n\tConnect to server failed; check $P4PORT.\n"]}) \
					and not _reconcile_had_nothing({"exit_code": 1, "output": [""]})

			var project := ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")
			var outside := project.get_base_dir().path_join("art/hero.psd")
			checks["labels"] = _tree_label("res://scenes/a.tscn") == "scenes/a.tscn" \
					and _tree_label(outside) == "../art/hero.psd"
			checks["row verbs"] = _detected_verb("edit") == "Check Out" and _detected_verb("add") == "Mark for Add" \
					and _detected_verb("delete") == "Mark for Delete"

			# The dock: a listed file gets a group row at the top; once opened
			# it is left out.
			var key := _path_key(outside)
			_watch_detected = [{"key": key, "local": outside, "mtime": now, "action": "edit"}]
			var model := {"available": true, "changelists": [{"change": "default", "desc": "",
					"files": [], "shelved": []}]}
			_rebuild_tree(model)
			var top := tree.get_root().get_first_child()
			var row := null if top == null else top.get_first_child()
			checks["group row and file row"] = top != null and (top.get_metadata(0) as Dictionary).get("type") == "detected_group" \
					and row != null and row.get_text(0) == "../art/hero.psd" \
					and (row.get_metadata(0) as Dictionary).get("type") == "detected"
			if row != null:
				_populate_context_menu(row.get_metadata(0))
				checks["edit row menu"] = _selftest_menu_labels() == "Check Out |  | Show in File Manager | Diff vs Depot | History... |  | Revert My Change... |  | Refresh"
				_log("[selftest] edit row menu: %s" % _selftest_menu_labels())
			_populate_context_menu({"type": "detected", "action": "delete", "local": outside, "res_path": outside})
			checks["delete row menu"] = _selftest_menu_labels() == "Mark for Delete |  | History... |  | Revert My Change... |  | Refresh"
			_populate_context_menu({"type": "detected", "action": "move/add", "local": outside, "res_path": outside})
			checks["moved-to row menu"] = _selftest_menu_labels() == "Record the Move |  | Show in File Manager |  | Refresh"

			# Answers p4 2026.1 gave (copied 2026-10-16), and what is made of them.
			var probe_text := ("//game/main/build/__p4godot_folder_probe__#1 - opened for add\n" +
					"C:/ws/dev\\build\\__p4godot_folder_probe__ - ignored file can't be added.\n" +
					"//game/main/src/__p4godot_folder_probe__#1 - opened for add\n" +
					"C:/ws/view/other/__p4godot_folder_probe__ - file(s) not in client view.\n")
			var probed := _probe_verdicts_in(probe_text)
			checks["folder probe answers"] = bool(probed.answered) and probed.verdicts.size() == 2 \
					and String(probed.verdicts.get("c:/ws/dev/build", "")) == "ignored" \
					and String(probed.verdicts.get("c:/ws/view/other", "")) == "unmapped" \
					and not bool(_probe_verdicts_in("Perforce client error:\n\tConnect to server failed\n").answered)
			checks["under a left-out folder"] = _under_any("c:/w/build/x/y.o", ["c:/w/build"]) \
					and not _under_any("c:/w/buildings/a.png", ["c:/w/build"])
			var lock_lines := ["//d/art/hero.psd - can't edit exclusive file already opened",
					"//d/art/hero.psd - also opened by mate@mate-ws"]
			checks["lock holder named"] = _refusal_reason(lock_lines, "c:/w/art/hero.psd", "//d/art/hero.psd") \
					== "locked by mate@mate-ws" \
					and _refusal_reason(lock_lines, "c:/w/art/other.psd", "//d/art/other.psd").begins_with("Perforce didn't")
			checks["a refused preview still counts as a change"] = _preview_refusals(lock_lines) \
					== {"//d/art/hero.psd": "edit"} and _preview_refusals([
					"//d/x.png - can't delete exclusive file already opened"]) == {"//d/x.png": "delete"}
			var tmp_dir := OS.get_cache_dir().path_join("p4g_leftover_test")
			DirAccess.make_dir_recursive_absolute(tmp_dir)
			for n: String in ["music.mp3", "music.mp34667122.tmp", "save", "save1.tmp", "orphan.txt12345.tmp"]:
				var f := FileAccess.open(tmp_dir.path_join(n), FileAccess.WRITE)
				f.store_string("x")
				f.close()
			checks["Godot save leftovers"] = _is_godot_save_leftover(tmp_dir.path_join("music.mp34667122.tmp")) 					and not _is_godot_save_leftover(tmp_dir.path_join("save1.tmp")) 					and not _is_godot_save_leftover(tmp_dir.path_join("orphan.txt12345.tmp")) 					and not _is_godot_save_leftover(tmp_dir.path_join("music.mp3"))
			for n: String in DirAccess.get_files_at(tmp_dir):
				DirAccess.remove_absolute(tmp_dir.path_join(n))
			checks["clean gets raw names"] = Array(_escape_path_args(["clean", "-e", "C:/w/x@2.txt"])) 					== ["clean", "-e", "C:/w/x@2.txt"]
			checks["revert flags"] = _clean_flag("edit") == "-e" and _clean_flag("delete") == "-d" \
					and _clean_flag("move/delete") == "-d" and _clean_flag("add") == "" and _clean_flag("move/add") == ""
			model.changelists[0].files = [{"res_path": outside, "depot_path": "//d/art/hero.psd",
					"action": "edit", "change": "default", "type": "binary"}]
			_rebuild_tree(model)
			var first_row := tree.get_root().get_first_child()
			checks["opened file leaves the group"] = first_row != null \
					and (first_row.get_metadata(0) as Dictionary).get("type") == "cl"
			_watch_detected = []

			var ok := true
			for name: String in checks:
				_log("[selftest] %s: %s" % [name, checks[name]])
				ok = ok and bool(checks[name])
			_log("[selftest] %s: watch" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-editor-menus":
			# Server-independent: the P4 submenus on scene tabs, script tabs, the
			# code editor and the scene tree, and the pieces behind "Who Changed
			# This Line?".
			var files_ok: bool = _is_project_file("res://a.gd") and not _is_project_file("") \
					and not _is_project_file("res://main.tscn::GDScript_x1") and not _is_project_file("res://dir/")
			# A scene tree node: the instanced scene and the script it comes from;
			# the open scene's root offers only its script.
			var root := Node.new()
			var enemy := Node.new()
			root.add_child(enemy)
			enemy.scene_file_path = "res://enemy.tscn"
			var scr := GDScript.new()
			scr.resource_path = "res://enemy_brain.gd"
			enemy.set_script(scr)
			root.scene_file_path = "res://main.tscn"
			var node_files := _node_source_files(enemy, root)
			var root_files := _node_source_files(root, root)
			var nodes_ok: bool = node_files == ["res://enemy.tscn", "res://enemy_brain.gd"] and root_files.is_empty()
			root.free()
			_log("[selftest] editor-menus files=%s nodes=%s %s" % [files_ok, nodes_ok, node_files])

			# Each slot's submenu. There's no server here; the menus stay silent
			# when p4 is known to be unavailable, so say it is.
			_p4_available = true
			_slot_submenus.clear()
			_slot_targets.clear()
			var slot_menu := P4SlotMenu.new()
			_populate_slot_menu(slot_menu, "scene_tabs", PackedStringArray(["res://main.tscn"]))
			_populate_slot_menu(slot_menu, "script_tabs", PackedStringArray(["res://main.tscn::GDScript_x1"]))
			_populate_slot_menu(slot_menu, "scene_tabs", PackedStringArray([""]))
			_add_file_submenu(slot_menu, "code", "P4", "res://a.gd", 12)
			var labels := func(key: String) -> Array:
				var sub: PopupMenu = _slot_submenus[key]
				var out: Array = []
				for i in sub.item_count:
					out.append(sub.get_item_text(i))
				return out
			var tab_labels: Array = labels.call("scene_tabs")
			var code_labels: Array = labels.call("code")
			var slots_ok: bool = _slot_submenus.keys().size() == 2 \
					and String(_slot_targets.scene_tabs.res) == "res://main.tscn" \
					and tab_labels.size() == _fs_context_actions().size() and tab_labels.has("History...") \
					and not tab_labels.has("Who Changed This Line?") \
					and code_labels[0] == "Who Changed This Line?" and int(_slot_targets.code.line) == 12
			_log("[selftest] editor-menus slots=%s tab=%s code=%s" % [slots_ok, tab_labels, code_labels])

			# A line on disk back to the have revision's line: lines added or
			# changed on disk map to 0.
			var have_lines := _split_lines("a\nb\nc\nd\ne\n")
			var disk_lines := _split_lines("z\na\nb\nX\nd\ne\nf\n")
			var hunks := _parse_unified_hunks(_line_diff_unified(have_lines, disk_lines))
			var mapped: Array = []
			for i in disk_lines.size():
				mapped.append(_have_line_for(i + 1, hunks))
			# p4's hunk for a pure insertion after line 2 names line 2 as its old start.
			var inserted: Array = []
			for i in 4:
				inserted.append(_have_line_for(i + 1, [{"old_start": 2, "new_start": 3, "ops": ["add"]}]))
			var map_ok: bool = mapped == [0, 1, 2, 0, 4, 5, 0] and inserted == [1, 2, 0, 3] \
					and _have_line_for(3, []) == 3
			# `p4 -Mj -ztag annotate -c -i` as measured: the file, then a line each.
			var ann := _annotate_changes("\n".join([
				'{"action":"move/add","change":"4","depotFile":"//game/main/b.gd","rev":"1","time":"1792108358","type":"text"}',
				'{"data":"l1\\r\\n","lower":"2","upper":"4"}',
				'{"data":"... depotFile looks like a field\\r\\n","lower":"3","upper":"4"}',
			]))
			var ann_ok: bool = ann == [2, 3]
			_log("[selftest] editor-menus line map=%s %s inserted=%s annotate=%s" % [map_ok, mapped, inserted, ann])
			# Changed-line marks: against "a b c d e".
			var base_lines := _split_lines("a\nb\nc\nd\ne\n")
			var mark_cases := [
				["a\nB\nc\nd\ne\nf\n", {1: "changed", 5: "added"}],
				["a\nc\nd\ne\n", {1: "deleted"}],
				["a\nb\nc\n", {2: "deleted_end"}],
				["z\na\nb\nc\nd\ne\n", {0: "added"}],
				["a\nX\nY\nZ\ne\n", {1: "changed", 2: "changed", 3: "changed"}],
				["a\nb\nc\nd\ne\n", {}],
			]
			var marks_ok := true
			for mc: Array in mark_cases:
				var got := _gutter_marks_for(base_lines, _split_lines(String(mc[0])))
				if got != mc[1]:
					marks_ok = false
					_log("[selftest] marks for %s: %s, want %s" % [String(mc[0]).c_escape(), got, mc[1]])
			var code := CodeEdit.new()
			var gutters_before := code.get_gutter_count()
			_gutter_attach(code)
			_gutter_attach(code) # a second activation adds nothing
			code.text = "a\nB\nc\nd\ne\n"
			code.set_meta("p4_have_lines", base_lines)
			_gutter_update(code)
			# Another handler on the same signal - as the files layer has - must
			# survive the marks being taken down.
			var other := func() -> void: pass
			code.text_changed.connect(other)
			var gutter_ok: bool = code.get_gutter_count() == gutters_before + 1 \
					and code.get_gutter_type(_gutter_index(code)) == TextEdit.GUTTER_TYPE_CUSTOM \
					and code.get_meta("p4_gutter_marks") == {1: "changed"}
			_unregister_gutters()
			gutter_ok = gutter_ok and code.get_gutter_count() == gutters_before and _gutter_index(code) == -1 \
					and code.text_changed.is_connected(other) \
					and not code.text_changed.get_connections().any(func(c: Dictionary) -> bool:
						return Callable(c.callable).get_method() == &"_gutter_schedule")
			_log("[selftest] editor-menus gutter after takedown: %s" % [code.text_changed.get_connections().map(
					func(c: Dictionary) -> String: return String(Callable(c.callable).get_method()))])
			# A removal marked on a line that the next run then adds to stays
			# visible as a change.
			var flushed := {}
			_gutter_flush(flushed, 2, [3], 4, 10)
			_gutter_flush(flushed, 1, [4], 5, 10)
			marks_ok = marks_ok and flushed == {3: "changed", 4: "changed"}
			code.free()
			_log("[selftest] editor-menus marks=%s gutter=%s" % [marks_ok, gutter_ok])
			var ok := files_ok and nodes_ok and slots_ok and map_ok and ann_ok and marks_ok and gutter_ok
			_log("[selftest] %s: editor-menus" % ("PASS" if ok else "FAIL"))
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
					and not ("res://sub/" in fs_files) and labels.size() == 7 \
				and labels.has("History...")
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
					and with_item.begins_with("Resolve... |  | Open") \
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
		if arg == "--p4-selftest-history-live":
			# Live and DESTRUCTIVE (five real submits; use a throwaway server): the
			# history window on a file with two revisions before a move and two
			# after, one of them described in two paragraphs. Drives the window's
			# own button handlers and checks the diff window, the alerts, the
			# file on disk and the revision p4 says this workspace has.
			_selftest_auto_answer = "confirm"
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: history-live - files already opened; needs a clean workspace")
				get_tree().quit()
				return
			await _probe_connection()
			var dir := "res://p4g_history_test"
			var dir_g := ProjectSettings.globalize_path(dir)
			DirAccess.make_dir_recursive_absolute(dir_g)
			var a_g := dir_g.path_join("a.txt")
			var b_g := dir_g.path_join("b.txt")
			var write := func(path: String, text: String) -> void:
				_set_file_writable(path, true)
				var fw := FileAccess.open(path, FileAccess.WRITE)
				fw.store_string(text)
				fw.close()
			write.call(a_g, "one\ntwo\nthree\n")
			await _p4_exec_logged(["add", a_g])
			await _submit_changelist("default", [], "history: first")
			var ok := _last_submit_outcome == "submitted"
			await _p4_exec_logged(["edit", a_g])
			write.call(a_g, "one\nTWO\nthree\nfour\n")
			await _submit_changelist("default", [], "history: second\n\nwith a second paragraph")
			ok = ok and _last_submit_outcome == "submitted"
			await _p4_exec_logged(["edit", a_g])
			await _p4_exec_logged(["move", a_g, b_g])
			await _submit_changelist("default", [], "history: move")
			ok = ok and _last_submit_outcome == "submitted"
			await _p4_exec_logged(["edit", b_g])
			write.call(b_g, "one\nTWO\nthree\nfour\nfive\n")
			await _submit_changelist("default", [], "history: third")
			ok = ok and _last_submit_outcome == "submitted"
			_log("[selftest] four submits=%s" % ok)

			var b_res := dir.path_join("b.txt")
			await _show_history(b_res)
			var names: Array = _history_revs.map(func(r: Dictionary) -> String:
				return _history_rev_name(r, _history_depot_path))
			var rows_ok: bool = names == ["#2", "#1", "a.txt#2", "a.txt#1"] \
					and String(_history_revs[2].desc).contains("second paragraph") \
					and _history_have_rev == 2 and history_window.visible
			_log("[selftest] history rows %s, have #%d, second paragraph kept=%s" \
					% [names, _history_have_rev, String(_history_revs[2].desc).contains("second paragraph")])
			var pick := func(rows: Array) -> void:
				_history_tree.deselect_all()
				for i: int in rows:
					_history_tree.get_root().get_child(i).select(0)
				_update_history_buttons()
			var added := func(line: String) -> bool:
				return _diff_rows.any(func(r: Dictionary) -> bool:
					return String(r.kind) == "add" and String(r.right) == line)

			# 1. The newest revision against the one before it.
			pick.call([0])
			diff_window.hide()
			await _on_history_diff_pressed()
			var prev_ok: bool = diff_window.visible and added.call("five") \
					and diff_left_label.text.contains("b.txt#1")
			# 2. The move itself changed nothing.
			pick.call([1])
			diff_window.hide()
			_selftest_shown.clear()
			await _on_history_diff_pressed()
			var move_ok: bool = not diff_window.visible \
					and _selftest_shown.any(func(t: String) -> bool: return t.contains("same content"))
			# 3. Two revisions on either side of the move.
			pick.call([0, 3])
			await _on_history_diff_pressed()
			var across_ok: bool = diff_window.visible and diff_left_label.text.contains("a.txt#1") \
					and diff_right_label.text.contains("b.txt#2") and added.call("four")
			# 4. Against the workspace (which has #2, so "five" is the change).
			pick.call([1])
			diff_window.hide()
			await _on_history_workspace_pressed()
			var ws_ok: bool = diff_window.visible and added.call("five") \
					and diff_right_label.text.contains(DIFF_WORKSPACE_LABEL)
			_log("[selftest] diff: previous=%s move=%s across-move=%s workspace=%s" % [prev_ok, move_ok, across_ok, ws_ok])

			# 4b. Who changed each line. b.txt is "one TWO three four five": "one"
			# from the first submit (under the old name a.txt, which annotate -i
			# follows), "TWO" from the second, "five" from the third. Then with a
			# line added on disk above them: the new line is "yours", and the
			# others shift down by one. "Show in History" selects the change.
			var first_change := int(_history_revs[3].change)
			var second_change := int(_history_revs[2].change)
			var third_change := int(_history_revs[0].change)
			var who1 := await _who_changed_line(b_res, 1)
			var who2 := await _who_changed_line(b_res, 2)
			var who5 := await _who_changed_line(b_res, 5)
			await _p4_exec_logged(["edit", b_g])
			write.call(b_g, "zero\none\nTWO\nthree\nfour\nfive\n")
			var who_new := await _who_changed_line(b_res, 1)
			var who_shift := await _who_changed_line(b_res, 3)
			# The editor's text, unsaved, differs from the disk ("zero one TWO
			# three four five"): line 5 on screen is "five" (the third submit),
			# where line 5 on disk is "four" (the second). And line 3 of a
			# two-line editor text is past its end, though the disk has one.
			var who_buffer := await _who_changed_line(b_res, 5, "one\nTWO\nthree\nfour\nfive\n", true)
			var who_past := await _who_changed_line(b_res, 3, "zero\none\n", true)
			# The code editor's marks for the same file, against the real #have:
			# the added first line, and "four" changed in the editor (unsaved).
			var marked := CodeEdit.new()
			marked.text = "zero\none\nTWO\nthree\nFOUR\nfive\n"
			_gutter_attach(marked)
			await _gutter_fetch_have(marked, b_res)
			var marks_live: Dictionary = marked.get_meta("p4_gutter_marks", {})
			_unregister_gutters()
			marked.free()
			await _p4_exec_logged(["revert", b_g])
			var who_ok: bool = int(who1.get("change", 0)) == first_change \
					and int(who2.get("change", 0)) == second_change \
					and String(who2.get("desc", "")).contains("second paragraph") \
					and int(who5.get("change", 0)) == third_change \
					and bool(who_new.get("local", false)) and int(who_shift.get("change", 0)) == second_change \
					and int(who_buffer.get("change", 0)) == third_change \
					and String(who_past.get("reason", "")).contains("nothing on line 3")
			await _show_history(b_res, second_change)
			var pick_ok: bool = _history_selected() == [2]
			_log("[selftest] who changed: one=%s TWO=%s five=%s (want %d %d %d), added line local=%s, shifted=%s; history picks the change=%s" \
					% [who1.get("change", who1.get("reason")), who2.get("change", who2.get("reason")),
					who5.get("change", who5.get("reason")), first_change, second_change, third_change,
					who_new.get("local", who_new.get("reason")), who_shift.get("change", who_shift.get("reason")), pick_ok])
			_log("[selftest] changed-line marks against #have: %s" % [marks_live])
			ok = ok and who_ok and pick_ok and marks_live == {0: "added", 4: "changed"}

			# 5. Get revision #1, then refuse it on a checked-out file. The file
			# is writable but unchanged first: `sync -s` refuses that ("can't
			# clobber"), and _safe_sync's retry once fetched the head revision
			# instead of the one asked for.
			_set_file_writable(b_g, true)
			pick.call([1])
			await _on_history_get_pressed()
			# The workspace's LineEnd is local: CRLF on Windows.
			var on_disk := FileAccess.get_file_as_string(b_g).replace("\r\n", "\n")
			var got_ok: bool = on_disk == "one\nTWO\nthree\nfour\n" and _history_have_rev == 1 \
					and _history_tree.get_root().get_child(1).get_text(0) == "#1  (you have)"
			await _p4_exec_logged(["edit", b_g])
			pick.call([0])
			_selftest_shown.clear()
			await _on_history_get_pressed()
			var refused_ok: bool = _selftest_shown.any(func(t: String) -> bool: return t.contains("is checked out")) \
					and int((await _fetch_fstat_record(b_res)).get("haveRev", "0")) == 1
			await _p4_exec_logged(["revert", b_g])
			_log("[selftest] get: revision #1 on disk=%s (%s, have #%d), refused while checked out=%s" % [got_ok, on_disk.c_escape(), _history_have_rev, refused_ok])

			# 6. A file that was never submitted.
			write.call(dir_g.path_join("new.txt"), "new\n")
			_selftest_shown.clear()
			await _show_history(dir.path_join("new.txt"))
			var new_ok: bool = _selftest_shown.any(func(t: String) -> bool: return t.contains("never been submitted"))
			_log("[selftest] never-submitted file told=%s" % new_ok)

			# 7. The filetype changed between two revisions (text -> utf8). Without
			# `diff2 -t` p4 says only "files differ", and the window showed
			# every line as unchanged.
			var c_g := dir_g.path_join("c.txt")
			var c_res := dir.path_join("c.txt")
			write.call(c_g, "alpha\nbeta\n")
			await _p4_exec_logged(["add", "-t", "text", c_g])
			await _submit_changelist("default", [], "history: c as text")
			await _p4_exec_logged(["edit", "-t", "utf8", c_g])
			write.call(c_g, "alpha\nbeta\ngamma\n")
			await _submit_changelist("default", [], "history: c as utf8")
			await _show_history(c_res)
			pick.call([0])
			diff_window.hide()
			await _on_history_diff_pressed()
			var retyped_ok: bool = diff_window.visible and added.call("gamma")
			# 8. A rename that isn't submitted yet: its history is under the old
			# name, and the window says so rather than "never submitted".
			var d_g := dir_g.path_join("d.txt")
			await _p4_exec_logged(["edit", c_g])
			await _p4_exec_logged(["move", c_g, d_g])
			_selftest_shown.clear()
			await _show_history(dir.path_join("d.txt"))
			var pending_ok: bool = _selftest_shown.is_empty() and _history_revs.size() == 2 \
					and _history_heading.text.contains("renamed from") \
					and _history_rev_name(_history_revs[0], _history_depot_path) == "c.txt#2"
			# Who changed a line, and the code editor's marks, on the new name:
			# both are based on the old name's revision.
			var utf8_change := int(_history_revs[0].change)
			var who_moved := await _who_changed_line(dir.path_join("d.txt"), 3)
			var moved_code := CodeEdit.new()
			moved_code.text = "alpha\nBETA\ngamma\n"
			_gutter_attach(moved_code)
			await _gutter_fetch_have(moved_code, dir.path_join("d.txt"))
			var moved_marks: Dictionary = moved_code.get_meta("p4_gutter_marks", {})
			_unregister_gutters()
			moved_code.free()
			pending_ok = pending_ok and int(who_moved.get("change", 0)) == utf8_change \
					and moved_marks == {1: "changed"}
			_log("[selftest] unsubmitted rename: who changed line 3=%s (want %d), marks=%s" \
					% [who_moved.get("change", who_moved.get("reason")), utf8_change, moved_marks])
			await _p4_exec_logged(["revert", c_g, d_g])
			_log("[selftest] filetype change diffed=%s, unsubmitted rename shows old history=%s (%s)" \
					% [retyped_ok, pending_ok, _history_heading.text.strip_edges()])

			await _p4_exec_logged(["sync", b_g, c_g])
			await _p4_exec_logged(["delete", b_g, c_g])
			await _submit_changelist("default", [], "P4Godot selftest: history cleanup")
			DirAccess.remove_absolute(dir_g.path_join("new.txt"))
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] opened-after=%d" % left)
			ok = ok and rows_ok and prev_ok and move_ok and across_ok and ws_ok and got_ok \
					and refused_ok and new_ok and retyped_ok and pending_ok and left == 0
			_log("[selftest] %s: history-live" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-shelves-live":
			# Live and DESTRUCTIVE (real submits and shelves; use a throwaway
			# server with the second user "mate", workspace mate-ws at
			# $P4TEST_MATE_WS). Your own shelf from the default changelist,
			# updated, shelved and reverted, unshelved back and submitted; then
			# a teammate's shelf listed, diffed and unshelved here, onto a file
			# checked out with your own edits (resolve), a writable file nobody
			# checked out (refused) and an exclusive file the teammate has open
			# (refused).
			_selftest_auto_answer = "confirm"
			var mate_ws := OS.get_environment("P4TEST_MATE_WS")
			if mate_ws.is_empty() or not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: shelves-live - needs P4TEST_MATE_WS and nothing opened")
				get_tree().quit()
				return
			await _probe_connection()
			var dir := "res://p4g_shelf_test"
			var dir_g := ProjectSettings.globalize_path(dir)
			DirAccess.make_dir_recursive_absolute(dir_g)
			var at := func(file_name: String) -> String: return dir_g.path_join(file_name)
			var write := func(path: String, text: String) -> void:
				_set_file_writable(path, true)
				var fw := FileAccess.open(path, FileAccess.WRITE)
				fw.store_string(text)
				fw.close()
			# The workspace's LineEnd is local: CRLF on Windows.
			var read := func(path: String) -> String:
				return FileAccess.get_file_as_string(path).replace("\r\n", "\n")
			write.call(at.call("a.txt"), "a1\na2\na3\n")
			write.call(at.call("c.txt"), "c1\n")
			write.call(at.call("d.txt"), "d1\nd2\nd3\nd4\n")
			write.call(at.call("m.txt"), "m1\n")
			write.call(at.call("lock.bin"), "LOCK1")
			await _p4_exec_logged(["add", at.call("a.txt"), at.call("c.txt"), at.call("d.txt"), at.call("m.txt")])
			await _p4_exec_logged(["add", "-t", "binary+l", at.call("lock.bin")])
			await _submit_changelist("default", [], "shelves: base")
			var ok := _last_submit_outcome == "submitted"

			# 1. Shelve from the default changelist: the files move to a new
			# numbered changelist, are shelved, and stay checked out.
			await _p4_exec_logged(["edit", at.call("a.txt"), at.call("m.txt")])
			write.call(at.call("a.txt"), "a1\nA2\na3\n")
			write.call(at.call("b.txt"), "b1\n")
			await _p4_exec_logged(["add", at.call("b.txt")])
			await _p4_exec_logged(["move", at.call("m.txt"), at.call("m2.txt")])
			var n := await _shelve_changelist("default", false, "shelves: review me\n\nsecond paragraph")
			var mine := {}
			if not n.is_empty():
				mine = await _read_shelf(n)
			var actions := {}
			for f: Dictionary in mine.get("files", []):
				actions[String(f.depot).get_file()] = String(f.action)
			var model := await _query_pending_model()
			var in_model := 0
			for cl in model.changelists:
				if String(cl.change) == n:
					in_model = cl.shelved.size()
			var shelve_ok: bool = not n.is_empty() and (await _opened_in_change(n)).size() == 4 \
					and actions == {"a.txt": "edit", "b.txt": "add", "m.txt": "move/delete", "m2.txt": "move/add"} \
					and String(mine.get("desc", "")).contains("second paragraph") and in_model == 4
			_log("[selftest] shelved #%s: %s, in the dock model=%d" % [n, actions, in_model])
			# What Shelve and Revert checks before throwing the disk copies
			# away: an edit made after shelving - the state a failed shelf
			# update leaves - to a text file and to an added file.
			var open_files: Array = await _submit_file_list(n, [])
			var shelved_map := {}
			for f: Dictionary in (await _read_shelves([n])).get(n, []):
				shelved_map[String(f.depot)] = f
			var same_now: Array = await _shelf_differs_from_disk(n, open_files, shelved_map)
			write.call(at.call("a.txt"), "a1\nA2\na3\nlater\n")
			write.call(at.call("b.txt"), "b1 later\n")
			var stale: Array = await _shelf_differs_from_disk(n, open_files, shelved_map)
			var stale_names: Array = stale.map(func(s: String) -> String: return s.get_file())
			stale_names.sort()
			var check_ok: bool = same_now.is_empty() and stale_names == ["a.txt", "b.txt"]
			_log("[selftest] disk vs shelf: unchanged=%s, edited after shelving=%s" % [same_now, stale_names])
			# The same comparison in the diff window. The moved file is where
			# `p4 diff m2.txt@=N` read project.godot's content instead.
			var own_shelf := await _read_shelf(n)
			var own := {}
			for f: Dictionary in own_shelf.files:
				own[String(f.depot).get_file()] = f
			var ws_moved := await _shelf_workspace_diff(n, own.get("m2.txt", {}))
			var ws_added := await _shelf_workspace_diff(n, own.get("b.txt", {}))
			var ws_ok: bool = not bool(ws_moved.ok) and String(ws_moved.reason).contains("identical") \
					and bool(ws_added.ok) and String(ws_added.new).contains("b1 later") \
					and String(ws_added.old).replace("\r\n", "\n") == "b1\n"
			# And Diff vs Depot on the renamed file, which uses `p4 diff`
			# without a shelf: the file is unchanged since the rename.
			diff_window.hide()
			_selftest_shown.clear()
			await _diff_path(dir.path_join("m2.txt"))
			var depot_diff_ok: bool = not diff_window.visible \
					and _selftest_shown.any(func(t: String) -> bool: return t.contains("identical"))
			_log("[selftest] workspace vs shelf: moved=%s added=%s; Diff vs Depot on the renamed file=%s %s"
					% [ws_moved.get("reason", "(a diff)"), ws_added.ok, depot_diff_ok, _selftest_shown])
			write.call(at.call("b.txt"), "b1\n")
			# A moved file compared with its base: the file it was moved from.
			var moved_base := await _shelf_base_diff(n, own.get("m2.txt", {}), own_shelf.files)
			var moved_base_ok: bool = not bool(moved_base.ok) \
					and String(moved_base.reason).contains("moved without being changed")
			# A shelf update p4 aborts - a checked-out file missing from disk -
			# keeps the old shelf, which has the same files and actions. It must
			# read as a failure, and Shelve and Revert must revert nothing.
			var a_text: String = read.call(at.call("a.txt"))
			_set_file_writable(at.call("a.txt"), true)
			DirAccess.remove_absolute(at.call("a.txt"))
			_selftest_shown.clear()
			var aborted := await _shelve_changelist(n, true)
			write.call(at.call("a.txt"), a_text)
			var abort_ok: bool = aborted.is_empty() and (await _opened_in_change(n)).size() == 4 \
					and FileAccess.file_exists(at.call("b.txt")) \
					and _selftest_shown.any(func(t: String) -> bool: return t.contains("didn't shelve"))
			_log("[selftest] moved file vs base=%s (%s); aborted update reverted nothing=%s" \
					% [moved_base_ok, moved_base.get("reason", ""), abort_ok])
			shelve_ok = shelve_ok and check_ok and ws_ok and depot_diff_ok and moved_base_ok and abort_ok

			# 2. Shelve and Revert, after another edit (with CRLF line ends,
			# which the comparison with the shelf has to see past): the shelf
			# is updated (-r), the workspace goes back to the server's files.
			write.call(at.call("a.txt"), "a1\r\nA2\r\na3\r\nA4\r\n")
			_selftest_shown.clear()
			var again := await _shelve_changelist(n, true)
			var a_depot := ""
			for f: Dictionary in (await _read_shelf(n)).get("files", []):
				if String(f.depot).ends_with("/a.txt"):
					a_depot = String(f.depot)
			var shelved_a := await _p4_exec(["print", "-q", "%s@=%s" % [a_depot, n]])
			var reverted_ok: bool = again == n and (await _opened_in_change(n)).is_empty() \
					and read.call(at.call("a.txt")) == "a1\na2\na3\n" \
					and not FileAccess.file_exists(at.call("b.txt")) \
					and not FileAccess.file_exists(at.call("m2.txt")) and FileAccess.file_exists(at.call("m.txt")) \
					and String(shelved_a.output[0]).contains("A4") \
					and _selftest_shown.any(func(t: String) -> bool: return t.contains("Update the shelf"))
			_log("[selftest] shelve and revert=%s" % reverted_ok)

			# 3. Unshelve it back: b.txt alone into the default changelist, the
			# rest into the same changelist.
			var b_depot := a_depot.get_base_dir().path_join("b.txt")
			var to_default := await _unshelve(await _read_shelf(n), [b_depot], "default")
			var default_ok: bool = to_default.get("opened", []) == [b_depot] \
					and (await _opened_in_change("default")).has(b_depot)
			var rest: Array = (await _read_shelf(n)).files.map(func(f: Dictionary) -> String: return String(f.depot)) \
					.filter(func(d: String) -> bool: return d != b_depot)
			var back := await _unshelve(await _read_shelf(n), rest, n)
			await _p4_exec_logged(["reopen", "-c", n, b_depot])
			var back_ok: bool = default_ok and back.get("opened", []).size() == 3 and back.get("refused", [1]).is_empty() \
					and read.call(at.call("a.txt")) == "a1\nA2\na3\nA4\n" and read.call(at.call("b.txt")) == "b1\n" \
					and FileAccess.file_exists(at.call("m2.txt")) and not FileAccess.file_exists(at.call("m.txt"))
			_log("[selftest] unshelved back=%s, b.txt into the default changelist=%s (%s)" % [back_ok, default_ok, back])

			# 4. Submit: the confirmation says the shelf goes first, and names
			# b.txt, reverted off disk, whose only copy is the shelf.
			await _p4_exec_logged(["revert", "-w", b_depot])
			_selftest_shown.clear()
			await _submit_changelist(n, [])
			var submit_ok: bool = _last_submit_outcome == "submitted" \
					and _selftest_shown.any(func(t: String) -> bool:
						return t.contains("shelved file") and t.contains("only copy") and t.contains("b.txt")) \
					and (await _opened_in_change(n)).is_empty()
			_log("[selftest] submitted with its shelf deleted first=%s" % submit_ok)

			# 5. A teammate shelves edits to a, c, d and the exclusive file,
			# and a new file, and keeps them checked out.
			var as_mate := PackedStringArray(["-u", "mate", "-c", "mate-ws"])
			var theirs := func(file_name: String) -> String: return mate_ws.path_join("p4g_shelf_test").path_join(file_name)
			await _p4_exec(as_mate + PackedStringArray(["sync", "//mate-ws/..."]))
			await _p4_exec(as_mate + PackedStringArray(["edit", theirs.call("a.txt"), theirs.call("c.txt"),
					theirs.call("d.txt"), theirs.call("lock.bin")]))
			write.call(theirs.call("a.txt"), "a1\nA2\na3\nA4\nmate5\n")
			write.call(theirs.call("c.txt"), "c1 mate\n")
			write.call(theirs.call("d.txt"), "d1\nd2\nd3\nd4 mate\n")
			write.call(theirs.call("lock.bin"), "LOCK mate")
			write.call(theirs.call("new.txt"), "new from mate\n")
			await _p4_exec(as_mate + PackedStringArray(["add", theirs.call("new.txt")]))
			var x := _created_change_in(await _p4_exec_spec(as_mate + PackedStringArray(["change", "-i"]),
					"Change: new\n\nDescription:\n\tmate: please review\n\n\tsecond paragraph\n"))
			await _p4_exec(as_mate + PackedStringArray(["reopen", "-c", x, theirs.call("a.txt"), theirs.call("c.txt"),
					theirs.call("d.txt"), theirs.call("lock.bin"), theirs.call("new.txt")]))
			await _p4_exec(as_mate + PackedStringArray(["shelve", "-c", x]))
			# Here: d checked out with an edit of its own, c writable but not
			# checked out, with changes nobody told Perforce about.
			await _p4_exec_logged(["edit", at.call("d.txt")])
			write.call(at.call("d.txt"), "d1 dev\nd2\nd3\nd4\n")
			write.call(at.call("c.txt"), "c1 local\n")

			# 6. The list and the shelf.
			await _show_shelves()
			var listed_ok: bool = _shelves_list.any(func(s: Dictionary) -> bool:
				return String(s.change) == x and String(s.user) == "mate")
			await _open_shelf_number(x)
			var by_name := {}
			for f: Dictionary in _shelf.get("files", []):
				by_name[String(f.depot).get_file()] = f
			var shelf_ok: bool = listed_ok and String(_shelf.get("change", "")) == x and by_name.size() == 5 \
					and _shelf_detail.text.contains("second paragraph")
			_log("[selftest] shelf #%s listed=%s files=%s" % [x, listed_ok, by_name.keys()])

			# 7. Diffs, without unshelving anything.
			var base_a := await _shelf_base_diff(x, by_name.get("a.txt", {}), _shelf.files)
			var base_new := await _shelf_base_diff(x, by_name.get("new.txt", {}), _shelf.files)
			var base_lock := await _shelf_base_diff(x, by_name.get("lock.bin", {}), _shelf.files)
			var ws_a := await _shelf_workspace_diff(x, by_name.get("a.txt", {}))
			var diffs_ok: bool = bool(base_a.ok) and String(base_a.old).contains("A4") \
					and not String(base_a.old).contains("mate5") and String(base_a.new).contains("mate5") \
					and bool(base_new.ok) and String(base_new.left) == "(new file)" \
					and not bool(base_lock.ok) and String(base_lock.reason).contains("binary") \
					and bool(ws_a.ok) and String(ws_a.right) == DIFF_WORKSPACE_LABEL
			# The window's own button, on the selected row.
			var a_row: TreeItem = null
			for item in _shelf_files_tree.get_root().get_children():
				if String(item.get_text(0)).ends_with("a.txt"):
					a_row = item
			_shelf_files_tree.deselect_all()
			if a_row:
				a_row.select(0)
			diff_window.hide()
			await _on_shelf_diff_pressed()
			var button_ok: bool = diff_window.visible and _diff_rows.any(func(r: Dictionary) -> bool:
				return String(r.kind) == "add" and String(r.right) == "mate5")
			_log("[selftest] shelf diffs=%s window button=%s" % [diffs_ok, button_ok])

			# 8. Unshelve all of it into a new changelist, and combine d.
			_shelf_files_tree.deselect_all()
			_selftest_option_picks = [0, 0] # the new changelist; "Combine both versions"
			var rep := await _unshelve(_shelf)
			var why := {}
			for r in rep.get("refused", []):
				why[String(r.depot).get_file()] = String(r.why)
			var opened_names: Array = rep.get("opened", []).map(func(d: String) -> String: return d.get_file())
			opened_names.sort()
			var spec := await _p4_exec(["change", "-o", String(rep.get("change", "0"))])
			var d_text: String = read.call(at.call("d.txt"))
			var unshelve_ok: bool = opened_names == ["a.txt", "d.txt", "new.txt"] \
					and rep.get("resolve", []).size() == 1 and rep.get("moved", []).size() == 1 \
					and String(why.get("c.txt", "")).contains("writable") \
					and String(why.get("lock.bin", "")).contains("mate@mate-ws") \
					and read.call(at.call("a.txt")).contains("mate5") and read.call(at.call("new.txt")) == "new from mate\n" \
					and read.call(at.call("c.txt")) == "c1 local\n" \
					and d_text.contains("d1 dev") and d_text.contains("d4 mate") \
					and String(spec.output[0]).contains("Review of #%s" % x) \
					and _unresolved_in(_parse_ztag(await _p4_exec(["-ztag", "resolve", "-n"]))).is_empty()
			_log("[selftest] unshelved into #%s: opened=%s refused=%s d=%s" % [rep.get("change", ""),
					opened_names, why.keys(), d_text.c_escape()])

			# Clean up: this workspace's files reverted (the added one off disk),
			# the review changelist deleted, the teammate's shelf and files gone.
			var review := String(rep.get("change", ""))
			await _p4_exec_logged(["revert", "-w", "//%s/..." % _p4_client])
			if not review.is_empty():
				await _p4_exec_logged(["change", "-d", review])
			await _p4_exec_logged(["sync", "-f", at.call("c.txt")])
			await _p4_exec(as_mate + PackedStringArray(["shelve", "-d", "-c", x]))
			await _p4_exec(as_mate + PackedStringArray(["revert", "-w", "//mate-ws/..."]))
			await _p4_exec(as_mate + PackedStringArray(["change", "-d", x]))
			await _p4_exec_logged(["delete", dir_g.path_join("...")])
			await _submit_changelist("default", [], "P4Godot selftest: shelves cleanup")
			var left := _parse_ztag(await _p4_exec(["-ztag", "opened"])).size()
			_log("[selftest] opened-after=%d" % left)
			ok = ok and shelve_ok and reverted_ok and back_ok and submit_ok and shelf_ok and diffs_ok \
					and button_ok and unshelve_ok and left == 0
			_log("[selftest] %s: shelves-live" % ("PASS" if ok else "FAIL"))
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
			# Not in Perforce before (or the check had nothing to do), in after.
			_log("[selftest] %s: plugin-prompt" % ("PASS" if after and not before else "FAIL"))
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
			var resolve_reported: bool = report.contains("have to be combined") \
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
		if arg == "--p4-selftest-watch-live":
			# Live, through tools/run-live-tests.sh, which puts the project in a
			# folder of the workspace with art/readme.txt beside it. Covers the
			# watcher end to end: the verified-mtime cache, an outside-project
			# edit checked out automatically, the listed-instead mode and its
			# dock row, a submit made elsewhere clearing a listing, the opened-
			# file cleanup (vanished add, a delete come back unchanged or
			# changed, a vanished rename), and the cleanup before a submit.
			# Self-cleaning; leaves its scratch files submitted as deleted.
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: watch-live - needs a workspace with nothing opened")
				get_tree().quit()
				return
			_selftest_auto_answer = "confirm"
			detect_external_checkbox.set_pressed_no_signal(true)
			auto_checkout_detected_checkbox.set_pressed_no_signal(true)
			auto_open_checkbox.set_pressed_no_signal(false)
			# Every pass here is the test's own: the timer's and the follow-ups'
			# would make "the first look" a matter of timing.
			if _watch_timer:
				_watch_timer.stop()
			_watch_followup_queued = true
			var checks := {}

			# Two tracked scratch files for the delete cases.
			var back1 := ProjectSettings.globalize_path("res://p4g_watch_back1.txt")
			var back2 := ProjectSettings.globalize_path("res://p4g_watch_back2.txt")
			for p: String in [back1, back2]:
				var fw := FileAccess.open(p, FileAccess.WRITE)
				fw.store_string("tracked by the watch self-test\n")
				fw.close()
			await _p4_exec_logged(["add", back1, back2])
			# The workspace started with nothing opened, so the default
			# changelist holds just these (submit takes one file argument).
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: watch scratch files"])

			# 1. The first pass checks every file; later passes only changed ones,
			#    and the cache survives a restart.
			await _selftest_settle()
			await _selftest_watch_pass()
			var first := _watch_last_checked.size()
			await _selftest_settle()
			await _selftest_watch_pass()
			await _selftest_watch_pass()
			var again := _watch_last_checked.size()
			_save_watch_cache(true)
			_watch_cache = {}
			_watch_cache_path_loaded = ""
			await _selftest_watch_pass()
			var reloaded := _watch_last_checked.size()
			_log("[selftest] checked: first pass %d, a later one %d, after reloading the cache %d" % [first, again, reloaded])
			checks["first pass checks every file, later ones none"] = first > 5 and again == 0
			checks["reloaded cache needs no checks"] = reloaded == 0

			# 2. An edit outside the project, made by another program, is
			#    checked out and shows in the dock under its "../" name.
			var art := _client_root.path_join("art/readme.txt")
			await _selftest_overwrite(art, "changed by another program\n")
			await _selftest_watch_pass()
			checks["outside-project edit checked out"] = await _selftest_action(art) == "edit"
			var model := await _query_pending_model()
			var labelled := ""
			for cl in model.changelists:
				for f in cl.files:
					if _path_key(ProjectSettings.globalize_path(String(f.res_path))) == _path_key(art):
						labelled = _tree_label(String(f.res_path))
			_log("[selftest] outside-project file in the dock as '%s'" % labelled)
			checks["outside-project file listed as ../art/readme.txt"] = labelled == "../art/readme.txt"
			await _p4_exec_logged(["revert", art])

			# 2b. The files Godot itself wrote (the .uid beside each script) go
			#     in first, as a team's would, so the automatic steps below see
			#     only what they make.
			auto_checkout_detected_checkbox.set_pressed_no_signal(false)
			await _selftest_watch_pass()
			var baseline: Array = _watch_detected.filter(func(r: Dictionary) -> bool: return r.action == "add") \
					.map(func(r: Dictionary) -> String: return String(r.local))
			_log("[selftest] files Godot wrote: %s" % [baseline])
			if not baseline.is_empty():
				var add_args: PackedStringArray = ["add"]
				add_args.append_array(PackedStringArray(baseline))
				await _p4_exec_logged(add_args)
				await _p4_exec_logged(["submit", "-d", "P4Godot selftest: files Godot wrote"])
			auto_checkout_detected_checkbox.set_pressed_no_signal(true)

			# 2c. Checking out automatically covers a new file, a deleted one
			#     and a renamed one (recorded as a move) as well as edits.
			var fresh := ProjectSettings.globalize_path("res://p4g_auto_new.txt")
			var renamed := ProjectSettings.globalize_path("res://p4g_watch_back1_renamed.txt")
			await _selftest_overwrite(fresh, "new, from another program\n")
			_set_file_writable(back2, true)
			DirAccess.remove_absolute(back2)
			_set_file_writable(back1, true)
			DirAccess.rename_absolute(back1, renamed)
			await _selftest_settle()
			await _selftest_watch_pass()
			# A delete waits one look (and the new name with it, to pair up).
			var waited := await _selftest_action(back2) == "" and await _selftest_action(renamed) == ""
			await _selftest_watch_pass()
			checks["a delete waits for a second look"] = waited
			var auto_actions := [await _selftest_action(fresh), await _selftest_action(back2),
					await _selftest_action(back1), await _selftest_action(renamed)]
			_log("[selftest] opened automatically: %s" % [auto_actions])
			checks["automatic: add, delete and move opened"] = auto_actions == ["add", "delete", "move/delete", "move/add"]
			await _p4_exec_logged(["revert", fresh, back2, back1, renamed])
			for p: String in [fresh, renamed]:
				if FileAccess.file_exists(p):
					DirAccess.remove_absolute(p)
			checks["put back after the automatic steps"] = FileAccess.file_exists(back1) and FileAccess.file_exists(back2)
			await _selftest_settle()
			await _selftest_watch_pass()

			# 2e. Many new files at once are asked about, not opened silently.
			var many_dir := ProjectSettings.globalize_path("res://p4g_many")
			DirAccess.make_dir_recursive_absolute(many_dir)
			var many: Array = []
			for i in WATCH_BULK_ASK + 1:
				var path := many_dir.path_join("f%d.txt" % i)
				var fw := FileAccess.open(path, FileAccess.WRITE)
				fw.store_string("one of many
")
				fw.close()
				many.append(path)
			await _selftest_settle()
			_selftest_auto_answer = "cancel"
			await _selftest_watch_pass()
			await _selftest_wait_asked()
			var silent := 0
			for path: String in many:
				if await _selftest_action(path) != "":
					silent += 1
			var listed_many := many.all(func(p: String) -> bool: return not _selftest_listed(p).is_empty())
			_selftest_auto_answer = "confirm"
			await _open_detected_rows(_watch_detected.filter(func(r: Dictionary) -> bool:
				return String(r.local).contains("p4g_many")))
			var opened_many := 0
			for path: String in many:
				if await _selftest_action(path) == "add":
					opened_many += 1
			checks["many new files: asked, listed, opened on request"] = silent == 0 and listed_many 					and opened_many == many.size()
			var revert_many: PackedStringArray = ["revert"]
			revert_many.append_array(PackedStringArray(many))
			await _p4_exec_logged(revert_many)
			for path: String in many:
				DirAccess.remove_absolute(path)
			DirAccess.remove_absolute(many_dir)
			await _selftest_settle()
			await _selftest_watch_pass()

			# 2d. Ignored folders: one with nothing tracked isn't walked; one
			#     holding a tracked file is, and an edit there is found; a "!"
			#     rule switches the leaving-out off.
			var root_ignore := _client_root.path_join(".p4ignore")
			await _p4_exec_logged(["edit", root_ignore])
			var ignore_text := FileAccess.get_file_as_string(root_ignore)
			var out_dir := ProjectSettings.globalize_path("res://build_out")
			var keep_dir := ProjectSettings.globalize_path("res://build_keep")
			var kept_file := keep_dir.path_join("k.txt")
			DirAccess.make_dir_recursive_absolute(out_dir.path_join("sub"))
			DirAccess.make_dir_recursive_absolute(keep_dir)
			for p: String in [out_dir.path_join("a.o"), out_dir.path_join("sub/b.o"), kept_file]:
				var fw := FileAccess.open(p, FileAccess.WRITE)
				fw.store_string("built\n")
				fw.close()
			await _p4_exec_logged(["add", "-I", kept_file])
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: a tracked file in an ignored folder", kept_file])
			await _selftest_overwrite(root_ignore, ignore_text + "build_out/\nbuild_keep/\n")
			await _selftest_watch_pass()
			await _selftest_watch_pass()
			var out_verdict := String((_watch_dirs.get(_path_key(out_dir), ["?"]) as Array)[0])
			var keep_verdict := String((_watch_dirs.get(_path_key(keep_dir), ["?"]) as Array)[0])
			await _selftest_overwrite(out_dir.path_join("a.o"), "rebuilt\n")
			await _selftest_watch_pass()
			var looked_in_build := _watch_last_checked.any(func(p: String) -> bool:
				return _path_key(p).begins_with(_path_key(out_dir) + "/"))
			await _selftest_overwrite(kept_file, "edited\n")
			await _selftest_watch_pass()
			_log("[selftest] folder verdicts: build_out '%s', build_keep '%s'; looked in build_out: %s" % [
					out_verdict, keep_verdict, looked_in_build])
			checks["ignored folder left out"] = out_verdict == "ignored" and not looked_in_build
			checks["ignored folder holding a tracked file still watched"] = keep_verdict == "" \
					and await _selftest_action(kept_file) == "edit"
			await _selftest_overwrite(root_ignore, ignore_text + "build_out/\nbuild_keep/\n!build_out/keep_me.txt\n")
			await _selftest_watch_pass()
			checks["a ! rule keeps ignored folders watched"] = String(
					(_watch_dirs.get(_path_key(out_dir), ["?"]) as Array)[0]) == ""
			await _p4_exec_logged(["revert", kept_file, root_ignore])
			for p: String in [out_dir.path_join("sub/b.o"), out_dir.path_join("a.o")]:
				DirAccess.remove_absolute(p)
			DirAccess.remove_absolute(out_dir.path_join("sub"))
			DirAccess.remove_absolute(out_dir)
			await _selftest_settle()
			await _selftest_watch_pass()

			# 3. With automatic checkout off the edit is listed instead: a dock
			#    row whose action opens it; a submit made elsewhere clears it.
			auto_checkout_detected_checkbox.set_pressed_no_signal(false)
			var gd := ProjectSettings.globalize_path("res://main.gd")
			await _selftest_overwrite(gd, "extends Node\n# edited by another program\n")
			await _selftest_watch_pass()
			var listed := _selftest_listed(gd)
			checks["edit listed, not opened"] = not listed.is_empty() and await _selftest_action(gd) == ""
			# Built here, not by _refresh_changelists: that returns at once when
			# a refresh is already running.
			_rebuild_tree(await _query_pending_model())
			var top := tree.get_root().get_first_child()
			_log("[selftest] top row: '%s' with %d row(s)" % ["" if top == null else top.get_text(0),
					0 if top == null else top.get_child_count()])
			var top_meta: Variant = null if top == null else top.get_metadata(0)
			var row_meta: Variant = null
			if top != null:
				for child in top.get_children():
					var m: Variant = child.get_metadata(0)
					if m is Dictionary and _path_key(String(m.get("local", ""))) == _path_key(gd):
						row_meta = m
			checks["dock shows the group and row"] = top_meta is Dictionary \
					and top_meta.get("type") == "detected_group" and row_meta is Dictionary \
					and row_meta.get("type") == "detected" and row_meta.get("action") == "edit"
			if row_meta is Dictionary:
				_populate_context_menu(row_meta)
				_log("[selftest] row menu: %s" % _selftest_menu_labels())
				checks["row menu offers Check Out and Diff"] = _selftest_menu_labels().contains("Check Out") \
						and _selftest_menu_labels().contains("Diff vs Depot")
			if not listed.is_empty():
				await _open_detected_rows([listed])
			checks["row action checks it out"] = await _selftest_action(gd) == "edit"
			await _selftest_watch_pass()
			checks["opened file no longer listed"] = _selftest_listed(gd).is_empty()
			# Listed again, then opened and submitted outside the plugin.
			await _p4_exec_logged(["revert", "-k", gd])
			await _selftest_overwrite(gd, "extends Node\n# edited by another program, again\n")
			await _selftest_watch_pass()
			var relisted := not _selftest_listed(gd).is_empty()
			await _p4_exec_logged(["edit", gd])
			await _selftest_watch_pass()
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: an edit made outside Godot", gd])
			await _selftest_watch_pass()
			checks["submitted elsewhere, no longer listed"] = relisted and _selftest_listed(gd).is_empty()

			# 4. Opened for add, then deleted from disk: out of the changelist.
			var gone := ProjectSettings.globalize_path("res://p4g_watch_gone.txt")
			await _selftest_overwrite(gone, "about to vanish\n")
			await _p4_exec_logged(["add", gone])
			await _selftest_watch_pass() # as the timer would, between the add and the delete
			DirAccess.remove_absolute(gone)
			await _selftest_watch_pass()
			checks["vanished add reverted"] = await _selftest_action(gone) == ""

			# 5. Opened for delete, then back unchanged: the delete is undone and
			#    the file is read-only again, as a sync leaves it.
			var original := FileAccess.get_file_as_string(back1)
			await _p4_exec_logged(["delete", back1])
			var removed := not FileAccess.file_exists(back1)
			await _selftest_watch_pass()
			await _selftest_overwrite(back1, original)
			await _selftest_watch_pass()
			checks["unchanged delete undone, read-only"] = removed and await _selftest_action(back1) == "" \
					and _selftest_is_read_only(back1)

			# 5b. `delete -k` keeps the file on disk on purpose: left alone.
			await _p4_exec_logged(["delete", "-k", back1])
			await _selftest_watch_pass()
			await _selftest_watch_pass()
			checks["delete -k left alone"] = await _selftest_action(back1) == "delete"
			await _p4_exec_logged(["revert", "-k", back1])

			# 6. Opened for delete in a numbered changelist, back changed: opened
			#    for edit in that changelist instead.
			var cl := await _create_selftest_change("P4Godot selftest: watch", "")
			await _p4_exec_logged(["delete", "-c", cl, back2])
			await _selftest_watch_pass()
			await _selftest_overwrite(back2, "came back different\n")
			await _selftest_watch_pass()
			var back2_rec := await _selftest_fstat(back2)
			checks["changed delete becomes an edit in its changelist"] = String(back2_rec.get("action", "")) == "edit" \
					and String(back2_rec.get("change", "")) == cl
			await _p4_exec_logged(["revert", back2])

			# 7. A rename whose new name is deleted: the changelist deletes the
			#    old name instead.
			var moved := ProjectSettings.globalize_path("res://p4g_watch_moved.txt")
			await _p4_exec_logged(["edit", "-c", cl, back1])
			await _p4_exec_logged(["move", back1, moved])
			await _selftest_watch_pass()
			DirAccess.remove_absolute(moved)
			await _selftest_watch_pass()
			var back1_rec := await _selftest_fstat(back1)
			checks["vanished rename becomes a delete"] = String(back1_rec.get("action", "")) == "delete" \
					and String(back1_rec.get("change", "")) == cl and await _selftest_action(moved) == ""
			await _p4_exec_logged(["revert", back1])
			await _p4_exec_logged(["change", "-d", cl])

			# 8. A submit first takes out an add whose file is gone - before this,
			#    the whole submit failed on it.
			var keep := ProjectSettings.globalize_path("res://p4g_watch_submitted.txt")
			var gone2 := ProjectSettings.globalize_path("res://p4g_watch_gone2.txt")
			await _selftest_overwrite(keep, "submitted by the watch self-test\n")
			await _selftest_overwrite(gone2, "about to vanish\n")
			await _p4_exec_logged(["add", keep, gone2])
			await _selftest_watch_pass()
			DirAccess.remove_absolute(gone2)
			await _submit_changelist("default", [], "P4Godot selftest: submit after a vanished add")
			var keep_rec := await _selftest_fstat(keep)
			checks["submit went through without the vanished add"] = String(keep_rec.get("headAction", "")) == "add" \
					and await _selftest_action(gone2) == ""

			# 9. A teammate's lock stops the automatic checkout: asked at once.
			#    Keep leaves the change, listed with who holds the lock, and it
			#    is checked out when they let go; Revert puts back the version
			#    you had.
			auto_checkout_detected_checkbox.set_pressed_no_signal(true)
			var locked := ProjectSettings.globalize_path("res://p4g_locked.bin")
			var mate_ws := OS.get_environment("P4TEST_MATE_WS")
			await _selftest_overwrite(locked, "v1\n")
			await _p4_exec_logged(["add", "-t", "binary+l", locked])
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: a file only one person can change", locked])
			var as_mate := PackedStringArray(["-u", "mate", "-c", "mate-ws"])
			var theirs := mate_ws.path_join("p4g_locked.bin")
			await _p4_exec(as_mate + PackedStringArray(["sync", "//mate-ws/..."]))
			await _p4_exec(as_mate + PackedStringArray(["edit", theirs]))
			_selftest_auto_answer = "cancel"
			await _selftest_overwrite(locked, "my change\n")
			await _selftest_watch_pass()
			await _selftest_wait_asked()
			var why := String(_watch_refused.get(_path_key(locked), ""))
			_log("[selftest] refused: %s" % why)
			checks["lock: kept, listed with who holds it"] = await _selftest_action(locked) == "" \
					and FileAccess.get_file_as_string(locked) == "my change\n" \
					and not _selftest_listed(locked).is_empty() and why.contains("mate@mate-ws")
			await _p4_exec(as_mate + PackedStringArray(["revert", theirs]))
			await _selftest_watch_pass()
			checks["lock: checked out once the teammate lets go"] = await _selftest_action(locked) == "edit"
			await _p4_exec_logged(["revert", locked])
			await _p4_exec(as_mate + PackedStringArray(["edit", theirs]))
			_selftest_auto_answer = "confirm"
			await _selftest_overwrite(locked, "my second change\n")
			await _selftest_watch_pass()
			await _selftest_wait_asked()
			checks["lock: revert puts back the version you had"] = await _selftest_action(locked) == "" \
					and FileAccess.get_file_as_string(locked) == "v1\n" and _selftest_listed(locked).is_empty()
			await _p4_exec(as_mate + PackedStringArray(["revert", theirs]))

			# Clean up: the scratch files leave the depot.
			await _p4_exec_logged(["delete", back1, back2, keep, kept_file, locked])
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: watch cleanup"])
			for p: String in [art, gd]:
				var rec := await _selftest_fstat(p)
				if not rec.has("action") and FileAccess.file_exists(p):
					await _p4_exec_logged(["sync", "-f", p])

			var ok := true
			for name: String in checks:
				_log("[selftest] %s: %s" % [name, checks[name]])
				ok = ok and bool(checks[name])
			_log("[selftest] %s: watch-live" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg in ["--p4-selftest-gui-dock", "--p4-selftest-gui-dialogs", "--p4-selftest-gui-windows",
				"--p4-selftest-gui-editor", "--p4-selftest-gui-readme"]:
			var which := arg.trim_prefix("--p4-selftest-")
			var ok: bool = false
			match which:
				"gui-dock": ok = await _gui_test_dock()
				"gui-dialogs": ok = await _gui_test_dialogs()
				"gui-windows": ok = await _gui_test_windows()
				"gui-editor": ok = await _gui_test_editor()
				"gui-readme": ok = await _gui_test_readme()
			_log("[selftest] %s: %s" % ["PASS" if ok else "FAIL", which])
			get_tree().quit()
			return
		if arg == "--p4-selftest-gui-spike":
			# GUI (tools/run-live-tests.sh with GUI=1): can a test see what the
			# user sees? Saves the editor, the dock's menu and a dialog.
			_selftest_auto_answer = ""
			var gd := ProjectSettings.globalize_path("res://main.gd")
			await _p4_exec_logged(["edit", gd])
			var fresh := ProjectSettings.globalize_path("res://notes_spike.txt")
			var fw := FileAccess.open(fresh, FileAccess.WRITE)
			fw.store_string("x\n")
			fw.close()
			await _p4_exec_logged(["add", fresh])
			await _refresh_changelists()
			await _gui_show_dock()
			await _gui_frames(30)
			await _gui_shot("editor")
			_log("[selftest] step done: await _gui_shot('editor')")
			var row := tree.get_root().get_first_child().get_first_child()
			if row:
				row.select(0)
				_context_target = row.get_metadata(0)
				_show_context_menu(_context_target)
				_log("[selftest] step done: _show_context_menu(_context_target)")
				await _gui_frames(5)
				await _gui_shot("dock-menu", context_menu)
				_log("[selftest] step done: await _gui_shot('dock-menu', context_menu)")
				context_menu.hide()
			_log("[selftest] menu hidden; showing a dialog")
			_show_confirm_dialog("Submit 2 files from the default changelist?\n\n    main.gd\n    notes_spike.txt",
					"Submit", "Cancel")
			_log("[selftest] dialog requested")
			await _gui_frames(5)
			for w in get_tree().root.find_children("*", "Window", true, false):
				var win := w as Window
				if win.visible:
					var t := (win as AcceptDialog).dialog_text.left(80) if win is AcceptDialog else ""
					_log("[selftest] window %s title='%s' exclusive=%s text='%s'" % [win.get_class(), win.title, win.exclusive, t])
			var dialog := await _gui_wait_dialog()
			if dialog:
				await _gui_shot("dialog", dialog)
				_gui_press(dialog, false)
			await _p4_exec_logged(["revert", gd, fresh])
			DirAccess.remove_absolute(fresh)
			_log("[selftest] PASS: gui-spike")
			get_tree().quit()
			return
		if arg == "--p4-selftest-diff-limits-live":
			# Live: Diff vs Depot on a changed text file over the size limit, and
			# on a changed binary, says why it shows nothing - and never opens
			# the diff window or downloads the file first.
			_selftest_auto_answer = "confirm"
			var big := ProjectSettings.globalize_path("res://p4g_diff_big.txt")
			var bin := ProjectSettings.globalize_path("res://p4g_diff_pic.bin")
			var fw := FileAccess.open(big, FileAccess.WRITE)
			for i in 30000:
				fw.store_string("line %d of a large text file, long enough to pass the limit\n" % i)
			fw.close()
			fw = FileAccess.open(bin, FileAccess.WRITE)
			fw.store_buffer(PackedByteArray([0, 1, 2, 3, 255, 254]))
			fw.close()
			await _p4_exec_logged(["add", big])
			await _p4_exec_logged(["add", "-t", "binary", bin])
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: diff limits"])
			await _p4_exec_logged(["edit", big, bin])
			fw = FileAccess.open(big, FileAccess.READ_WRITE)
			fw.seek_end()
			fw.store_string("one more line\n")
			fw.close()
			fw = FileAccess.open(bin, FileAccess.WRITE)
			fw.store_buffer(PackedByteArray([9, 9, 9]))
			fw.close()
			_selftest_shown.clear()
			await _diff_path("res://p4g_diff_big.txt")
			var big_said := "" if _selftest_shown.is_empty() else String(_selftest_shown[-1])
			_selftest_shown.clear()
			await _diff_path("res://p4g_diff_pic.bin")
			var bin_said := "" if _selftest_shown.is_empty() else String(_selftest_shown[-1])
			var window_shown := diff_window != null and diff_window.visible
			_log("[selftest] big: %s | binary: %s | diff window shown: %s" % [big_said, bin_said, window_shown])
			await _p4_exec_logged(["revert", big, bin])
			await _p4_exec_logged(["delete", big, bin])
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: diff limits cleanup"])
			var ok := big_said.contains("too large") and big_said.contains("P4V") \
					and (bin_said.contains("binary") or bin_said.contains("isn't text")) and not window_shown
			_log("[selftest] %s: diff-limits-live" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-allwrite-offer-live":
			# Live: the startup offers run for real (self-tests normally skip
			# them). The allwrite offer asks once per server+workspace: "Not Now"
			# is remembered, so a second start doesn't ask; another workspace
			# is asked afresh. The project.godot offer checks the file out with
			# +w. Leaves the workspace noallwrite and project.godot as it was.
			var settings := EditorInterface.get_editor_settings()
			var checks := {}
			var pg := ProjectSettings.globalize_path("res://project.godot")
			# project.godot without +w, as a team that hasn't set it up has it.
			await _p4_exec_logged(["edit", "-t", "text", pg])
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: project.godot without +w", pg])
			settings.set_project_metadata(SETTINGS_SECTION, "allwrite_asked", [])
			settings.set_project_metadata(SETTINGS_SECTION, "project_godot_writable_asked", false)
			_selftest_mode = false # the whole point is to let the offers run
			# 1. Not Now to both.
			_selftest_auto_answer = "cancel"
			_client_allwrite = null
			await _offer_allwrite_once()
			_client_allwrite = null
			var asked: Array = settings.get_project_metadata(SETTINGS_SECTION, "allwrite_asked", [])
			checks["declined: remembered for this workspace, still read-only"] = \
					("%s|%s" % [_p4_port, _p4_client]) in asked and not await _workspace_is_allwrite()
			checks["declined project.godot: unchanged"] = String((await _selftest_fstat(pg)).get("action", "")) == ""
			# 2. A second start would answer yes - but isn't asked.
			_selftest_auto_answer = "confirm"
			await _offer_allwrite_once()
			_client_allwrite = null
			checks["not asked again"] = not await _workspace_is_allwrite() \
					and String((await _selftest_fstat(pg)).get("action", "")) == ""
			# 3. Another workspace (as far as the memory knows) is asked afresh;
			#    yes switches. The project.godot offer then has nothing to do.
			settings.set_project_metadata(SETTINGS_SECTION, "allwrite_asked", ["127.0.0.1:1|other-ws"])
			await _offer_allwrite_once()
			_client_allwrite = null
			checks["another workspace is asked; yes switches"] = await _workspace_is_allwrite()
			await _switch_allwrite(false, false)
			while _external_scan_inflight:
				await get_tree().process_frame
			# 4. The project.godot offer on its own, answered yes.
			settings.set_project_metadata(SETTINGS_SECTION, "project_godot_writable_asked", false)
			_client_allwrite = null
			await _offer_project_godot_writable()
			var pg_rec := await _selftest_fstat(pg)
			checks["project.godot checked out with +w"] = String(pg_rec.get("action", "")) == "edit" \
					and String(pg_rec.get("type", "")).contains("+w")
			await _p4_exec_logged(["submit", "-d", "P4Godot selftest: project.godot back to +w", pg])
			_selftest_mode = true
			var ok := true
			for name: String in checks:
				_log("[selftest] %s: %s" % [name, checks[name]])
				ok = ok and bool(checks[name])
			_log("[selftest] %s: allwrite-offer-live" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg.begins_with("--p4-selftest-ssl-fingerprint-live="):
			# Live: an SSL server whose certificate changed since this computer
			# trusted it (tools/run-live-tests.sh stages it). Connection setup
			# must warn, name both fingerprints, and on "Trust New Fingerprint"
			# install exactly the new one. Restores the connection settings.
			var ssl_port := arg.substr("--p4-selftest-ssl-fingerprint-live=".length())
			var saved_port := _override_port
			var saved_user := _override_user
			var saved_client := _override_client
			_override_port = ssl_port
			_override_user = ""
			_override_client = ""
			_reset_connection_state()
			var before := String((await _p4_exec(["trust", "-l"])).output[0])
			_selftest_auto_answer = "confirm"
			_selftest_shown.clear()
			var status := await _probe_connection()
			var probe_text := _last_probe_text
			var trusted := status == "fingerprint changed" and await _handle_fingerprint_change()
			var warning := ""
			for shown: String in _selftest_shown:
				if shown.contains("CHANGED"):
					warning = shown
			var after := String((await _p4_exec(["trust", "-l"])).output[0])
			var change := _fingerprint_change_in(probe_text)
			_override_port = saved_port
			_override_user = saved_user
			_override_client = saved_client
			_save_connection_overrides()
			_log("[selftest] status before setup: %s; new fingerprint %s" % [status, change.get("new", "")])
			_log("[selftest] trusted before: %s" % before.strip_edges().replace("\n", " | "))
			_log("[selftest] trusted after: %s" % after.strip_edges().replace("\n", " | "))
			var new_fp := String(change.get("new", ""))
			var old_fp := _trusted_fingerprint_for(before, String(change.get("address", "")))
			var ok := trusted and not new_fp.is_empty() and not old_fp.is_empty() \
					and warning.contains(new_fp) and warning.contains(old_fp) and after.contains(new_fp) \
					and not after.contains(old_fp)
			_log("[selftest] %s: ssl-fingerprint-live" % ("PASS" if ok else "FAIL"))
			get_tree().quit()
			return
		if arg == "--p4-selftest-watch-time":
			# Manual benchmark, not in any runner: time the watcher's first pass
			# (every file checked) and the one after (cache hits) on whatever
			# workspace this project sits in. Changes nothing: automatic opens
			# are off.
			detect_external_checkbox.set_pressed_no_signal(true)
			auto_checkout_detected_checkbox.set_pressed_no_signal(false)
			auto_open_checkbox.set_pressed_no_signal(false)
			var t0 := Time.get_ticks_msec()
			await _selftest_watch_pass()
			var first_ms := Time.get_ticks_msec() - t0
			var first_n := _watch_last_checked.size()
			t0 = Time.get_ticks_msec()
			await _selftest_watch_pass()
			_log("[selftest] watch-time: first pass checked %d file(s) in %d ms; the next checked %d in %d ms; %d listed"
					% [first_n, first_ms, _watch_last_checked.size(), Time.get_ticks_msec() - t0, _watch_detected.size()])
			_log("[selftest] PASS: watch-time")
			get_tree().quit()
			return
		if arg == "--p4-selftest-allwrite-live":
			# Live, through tools/run-live-tests.sh: switch the workspace to
			# allwrite and back. Files follow the switch; a save of a writable
			# file doesn't wait on a checkout; an edit made while allwrite is
			# found; switching back leaves a changed, unopened file writable and
			# listed. Leaves the workspace noallwrite, as it found it.
			if not _parse_ztag(await _p4_exec(["-ztag", "opened"])).is_empty():
				_log("[selftest] FAIL: allwrite-live - needs a workspace with nothing opened")
				get_tree().quit()
				return
			_selftest_auto_answer = "confirm"
			detect_external_checkbox.set_pressed_no_signal(true)
			auto_checkout_detected_checkbox.set_pressed_no_signal(true)
			auto_open_checkbox.set_pressed_no_signal(false)
			var checks := {}
			var gd := ProjectSettings.globalize_path("res://main.gd")
			var art := _client_root.path_join("art/readme.txt")
			checks["starts read-only"] = not await _workspace_is_allwrite() and _selftest_is_read_only(gd)

			await _switch_allwrite(true, false)
			_client_allwrite = null
			checks["switched to allwrite"] = await _workspace_is_allwrite() and not _selftest_is_read_only(gd) \
					and not _selftest_is_read_only(art)

			# A pending save of a writable file isn't checked out first.
			_pending_save_checkout["res://main.gd"] = true
			checkout_on_save_checkbox.set_pressed_no_signal(true)
			_apply_changes()
			checks["save of a writable file doesn't block on a checkout"] = await _selftest_action(gd) == ""
			_pending_save_checkout.erase("res://main.gd")

			# An edit made while allwrite - no chmod needed - is checked out.
			var fw := FileAccess.open(art, FileAccess.WRITE)
			var wrote := fw != null
			if wrote:
				fw.store_string("edited with no checkout, in an allwrite workspace\n")
				fw.close()
			await _selftest_settle()
			await _selftest_watch_pass()
			checks["allwrite edit checked out"] = wrote and await _selftest_action(art) == "edit"
			await _p4_exec_logged(["revert", art])
			checks["revert leaves it writable"] = not _selftest_is_read_only(art)

			# Back to read-only: an unopened edit stays writable and listed.
			auto_checkout_detected_checkbox.set_pressed_no_signal(false)
			fw = FileAccess.open(art, FileAccess.WRITE)
			if fw:
				fw.store_string("changed, not checked out, when switching back\n")
				fw.close()
			await _selftest_settle()
			await _switch_allwrite(false, false)
			while _external_scan_inflight: # the listing pass the switch starts
				await get_tree().process_frame
			_client_allwrite = null
			checks["switched back"] = not await _workspace_is_allwrite() and _selftest_is_read_only(gd)
			checks["unopened edit stays writable and listed"] = not _selftest_is_read_only(art) \
					and not _selftest_listed(art).is_empty()
			await _p4_exec_logged(["sync", "-f", art])

			var ok := true
			for name: String in checks:
				_log("[selftest] %s: %s" % [name, checks[name]])
				ok = ok and bool(checks[name])
			_log("[selftest] %s: allwrite-live" % ("PASS" if ok else "FAIL"))
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


## Self-tests only: one watcher pass now, whatever the throttle says. A pass
## the timer started first is waited out, or this one would return at once.
func _selftest_watch_pass() -> void:
	while _external_scan_inflight:
		await get_tree().process_frame
	_external_scan_last_msec = -EXTERNAL_SCAN_MIN_INTERVAL_MSEC
	await _scan_for_external_changes("self-test")


## Self-tests only: long enough that files written before it count as
## settled (WATCH_SETTLE_SEC, and one-second file times).
func _selftest_settle() -> void:
	await get_tree().create_timer(WATCH_SETTLE_SEC + 1.2).timeout


## Self-tests only: write a file as another program would (clearing a
## read-only bit first), then wait for it to settle.
func _selftest_overwrite(local: String, text: String) -> void:
	if FileAccess.file_exists(local):
		_set_file_writable(local, true)
	var f := FileAccess.open(local, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	await _selftest_settle()


func _selftest_fstat(local: String) -> Dictionary:
	var recs := _parse_ztag(await _p4_exec(["-ztag", "fstat", local]))
	return {} if recs.is_empty() else recs[0]


## Self-tests only: what `local` is opened for here, or "".
func _selftest_action(local: String) -> String:
	return String((await _selftest_fstat(local)).get("action", ""))


## Self-tests only: the watcher's dock row for `local`, or {}.
func _selftest_listed(local: String) -> Dictionary:
	for row: Dictionary in _watch_detected:
		if String(row.key) == _path_key(local):
			return row
	return {}


## Self-tests only: until the question about refused files is answered and
## acted on (it is asked without the pass waiting for it).
func _selftest_wait_asked() -> void:
	await get_tree().process_frame
	var deadline := Time.get_ticks_msec() + 20000
	while _watch_asking and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


# ---------------------------------------------------------------------------
# GUI tests: screenshots of the real editor (run with GUI=1)
# ---------------------------------------------------------------------------

func _gui_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Save a PNG of what the user sees into $P4GODOT_SHOTS: the editor's main
## window, or `window` alone. A window drawn inside the editor (dialogs and
## menus are, in GUI tests: see _gui_show_dock) is cut out of the main
## window's picture, title bar and border included.
func _gui_shot(name: String, window: Window = null) -> void:
	var dir := OS.get_environment("P4GODOT_SHOTS")
	if dir.is_empty():
		_log("[selftest] (no P4GODOT_SHOTS: skipped screenshot %s)" % name)
		return
	await _gui_frames(3)
	var main := EditorInterface.get_base_control().get_window()
	var image: Image
	if window == null or window == main:
		image = main.get_texture().get_image()
	elif window.is_embedded():
		var full := main.get_texture().get_image()
		var rect := _gui_window_rect(window).intersection(Rect2i(Vector2i.ZERO, full.get_size()))
		image = full.get_region(rect)
	else:
		image = window.get_texture().get_image()
	var path := dir.path_join(name + ".png")
	image.save_png(path)
	_log("[selftest] screenshot %s (%dx%d)" % [path, image.get_width(), image.get_height()])


## Open the P4G panel: it sits in the bottom bar, collapsed. Godot 4.7 keeps
## a toggle button named after the dock there.
func _gui_show_dock() -> void:
	var w := EditorInterface.get_base_control().get_window()
	w.mode = Window.MODE_WINDOWED
	w.size = Vector2i(1600, 900)
	# THEME=light: the same tour in Godot's light theme, where colours that
	# only work on dark backgrounds show up.
	if OS.get_environment("P4GODOT_THEME") == "light":
		var es := EditorInterface.get_editor_settings()
		es.set_setting("interface/theme/follow_system_theme", false)
		es.set_setting("interface/theme/color_preset", "Light")
		es.set_setting("interface/theme/base_color", Color(0.9, 0.9, 0.9))
		es.set_setting("interface/theme/accent_color", Color(0.18, 0.5, 1.0))
		await _gui_frames(30)
	# Dialogs and menus drawn inside the editor window, not as windows of
	# their own: a new native window stalled the editor's frame loop under
	# test (measured), and inside, a screenshot shows them in context.
	w.gui_embed_subwindows = true
	# Godot's own startup dialogs (Load Errors) are not under test: note what
	# they say, then close them so the plugin's dialogs are the only ones up.
	for found in get_tree().root.find_children("*", "AcceptDialog", true, false):
		var d := found as AcceptDialog
		if d.visible:
			var said := PackedStringArray()
			for label in d.find_children("*", "RichTextLabel", true, false):
				said.append((label as RichTextLabel).get_parsed_text().strip_edges())
			_log("[selftest] closing Godot's '%s' dialog: %s %s" % [d.title, d.dialog_text, " ".join(said)])
			d.hide()
	if dock.is_visible_in_tree():
		return
	var chain := PackedStringArray()
	var n: Node = dock
	for i in 6:
		n = n.get_parent()
		if n == null:
			break
		chain.append("%s(%s)" % [n.get_class(), n.name])
	_log("[selftest] dock parents: %s" % " < ".join(chain))
	if dock.get_parent() is TabContainer:
		var tc := dock.get_parent() as TabContainer
		_log("[selftest] tab container: tabs=%d current=%d visible=%s" % [tc.get_tab_count(), tc.current_tab, tc.is_visible_in_tree()])
	if has_method("make_bottom_panel_item_visible"):
		call("make_bottom_panel_item_visible", dock)
		await _gui_frames(5)
		_log("[selftest] after make_bottom_panel_item_visible: %s" % dock.is_visible_in_tree())
		if dock.is_visible_in_tree():
			return
	var button := _gui_find_button(EditorInterface.get_base_control(), "P4G")
	if button:
		if button.toggle_mode:
			button.button_pressed = true
		else:
			button.pressed.emit()
	else:
		_log("[selftest] no P4G button in the bottom bar")


func _gui_find_button(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and (child as Button).text == text and (child as Button).is_visible_in_tree():
			return child
		var deeper := _gui_find_button(child, text)
		if deeper:
			return deeper
	return null


## The plugin's dialog on screen, once it appears (up to 5 s).
func _gui_wait_dialog() -> AcceptDialog:
	for i in 100:
		await _gui_frames(3)
		if i % 10 == 0:
			_log("[selftest] waiting for a dialog, %d frames, msec %d, lock %s" % [i * 3, Time.get_ticks_msec(), _dialog_busy])
		for found in get_tree().root.find_children("*", "AcceptDialog", true, false):
			var d := found as AcceptDialog
			if not d.visible:
				continue
			if d.title == "Load Errors":
				# Godot's own, not under test: say what it said and close it.
				var said := PackedStringArray()
				for label in d.find_children("*", "RichTextLabel", true, false):
					said.append((label as RichTextLabel).get_parsed_text().strip_edges())
				_log("[selftest] closing Godot's Load Errors: %s" % " ".join(said))
				d.hide()
				continue
			await _gui_frames(3)
			return d
	var shown := PackedStringArray()
	for w in get_tree().root.find_children("*", "Window", true, false):
		if (w as Window).visible:
			shown.append("%s '%s'" % [w.get_class(), (w as Window).title])
	_log("[selftest] no dialog appeared (dialog lock held: %s); visible windows: %s" % [
			_dialog_busy, ", ".join(shown)])
	return null


## Answer a dialog as its buttons do: the plugin's dialogs resolve on the
## dialog's own confirmed / canceled signals.
func _gui_press(dialog: AcceptDialog, ok: bool) -> void:
	if ok:
		dialog.confirmed.emit()
	else:
		dialog.canceled.emit()


# ---------------------------------------------------------------------------
# GUI tour: every screen the plugin shows, with realistic data, saved as
# screenshots for review (GUI=1 tools/run-live-tests.sh gui-dock gui-dialogs
# gui-windows). Each returns whether its own checks held; the screenshots
# are the real output.
# ---------------------------------------------------------------------------

## A workspace with something in every state the dock can show: the default
## changelist (edit, add, an outside-project edit), a numbered changelist
## with an edit, a delete and a shelf, and an untracked file the watcher
## lists. Returns the paths it touched, for _gui_cleanup.
func _gui_stage(tag: String) -> Dictionary:
	var paths := {}
	var gd := ProjectSettings.globalize_path("res://main.gd")
	# Named per test: an earlier test submitted its own, which left them
	# read-only.
	var level := ProjectSettings.globalize_path("res://levels/%s_level_01.tscn" % tag)
	var hero := ProjectSettings.globalize_path("res://art/%s_hero.png" % tag)
	var notes := ProjectSettings.globalize_path("res://docs/design_notes.txt")
	var art := _client_root.path_join("art/readme.txt")
	DirAccess.make_dir_recursive_absolute(level.get_base_dir())
	DirAccess.make_dir_recursive_absolute(hero.get_base_dir())
	DirAccess.make_dir_recursive_absolute(notes.get_base_dir())
	var scene := PackedScene.new()
	var root := Node2D.new()
	root.name = "Level01"
	scene.pack(root)
	ResourceSaver.save(scene, ProjectSettings.localize_path(level))
	root.free()
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.6, 0.9))
	img.save_png(hero)
	for pair in [[notes, "Design notes\n"]]:
		var fw := FileAccess.open(String(pair[0]), FileAccess.WRITE)
		fw.store_string(String(pair[1]))
		fw.close()
	await _p4_exec_logged(["add", level, hero])
	await _p4_exec_logged(["submit", "-d", "Level 1 and the hero sprite"])
	await _p4_exec_logged(["edit", gd])
	await _p4_exec_logged(["add", notes])
	await _p4_exec_logged(["edit", art])
	var cl := await _create_selftest_change("Lighting pass for level 1: warmer key light, softer shadows", "")
	await _p4_exec_logged(["edit", "-c", cl, level])
	await _p4_exec_logged(["delete", "-c", cl, hero])
	await _p4_exec_logged(["shelve", "-c", cl])
	paths.cl = cl
	paths.files = [gd, level, hero, notes, art]
	# Something the watcher lists, with automatic opening off.
	var stray := ProjectSettings.globalize_path("res://art/concept_v2.png")
	img.save_png(stray)
	paths.stray = stray
	detect_external_checkbox.set_pressed_no_signal(true)
	auto_checkout_detected_checkbox.set_pressed_no_signal(false)
	await _gui_frames(150)
	await _selftest_watch_pass()
	_rebuild_tree(await _query_pending_model())
	return paths


func _gui_cleanup(paths: Dictionary) -> void:
	await _p4_exec_logged(["shelve", "-d", "-c", String(paths.cl)])
	var revert: PackedStringArray = ["revert"]
	revert.append_array(PackedStringArray(paths.files))
	await _p4_exec_logged(revert)
	await _p4_exec_logged(["change", "-d", String(paths.cl)])
	DirAccess.remove_absolute(String(paths.stray))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("res://docs/design_notes.txt"))


## The tree row whose metadata matches every key in `want`, or null.
func _gui_row(want: Dictionary) -> TreeItem:
	var stack: Array = [tree.get_root()]
	while not stack.is_empty():
		var item: TreeItem = stack.pop_back()
		if item == null:
			continue
		var meta: Variant = item.get_metadata(0)
		if meta is Dictionary:
			var all := true
			for k in want:
				if String((meta as Dictionary).get(k, "")) != String(want[k]):
					all = false
			if all:
				return item
		for child in item.get_children():
			stack.append(child)
	return null


## Right-click a row the way the mouse would, then capture the menu.
func _gui_shot_row_menu(name: String, row: TreeItem) -> void:
	if row == null:
		_log("[selftest] no row for %s" % name)
		return
	row.select(0)
	tree.scroll_to_item(row)
	await _gui_frames(2)
	var rect := tree.get_item_area_rect(row, 0)
	var at := Vector2i(tree.get_screen_position() + rect.position + Vector2(rect.size.x * 0.4, rect.size.y * 0.5))
	_context_target = row.get_metadata(0)
	_populate_context_menu(_context_target)
	context_menu.reset_size()
	context_menu.position = at
	context_menu.popup()
	await _gui_frames(4)
	await _gui_shot(name + "-menu", context_menu)
	await _gui_shot(name + "-in-context")
	context_menu.hide()


func _gui_test_dock() -> bool:
	await _gui_show_dock()
	var paths := await _gui_stage(OS.get_cmdline_user_args()[0].trim_prefix("--p4-selftest-gui-"))
	await _gui_frames(10)
	await _gui_shot("dock")
	await _gui_shot_row_menu("dock-file", _gui_row({"type": "file", "action": "edit"}))
	await _gui_shot_row_menu("dock-default-cl", _gui_row({"type": "cl", "change": "default"}))
	await _gui_shot_row_menu("dock-numbered-cl", _gui_row({"type": "cl", "change": String(paths.cl)}))
	await _gui_shot_row_menu("dock-shelf", _gui_row({"type": "shelf"}))
	await _gui_shot_row_menu("dock-shelved-file", _gui_row({"type": "shelved_file"}))
	await _gui_shot_row_menu("dock-detected", _gui_row({"type": "detected"}))
	settings_menu.show_popup()
	await _gui_frames(4)
	await _gui_shot("dock-settings-menu", settings_menu.get_popup())
	settings_menu.get_popup().hide()
	# A narrow editor: the toolbar has to wrap rather than clip.
	var w := EditorInterface.get_base_control().get_window()
	w.size = Vector2i(1100, 800)
	await _gui_frames(20)
	await _gui_shot("dock-narrow")
	w.size = Vector2i(1600, 900)
	# Perforce unreachable.
	_set_actions_enabled(false)
	_rebuild_tree({"available": false, "changelists": []})
	await _gui_frames(5)
	await _gui_shot("dock-unavailable")
	_set_actions_enabled(true)
	await _gui_cleanup(paths)
	return true


## Start `flow` (not awaited), capture the dialog it shows as `name`, and
## answer it. Returns the dialog's text.
func _gui_capture(name: String, flow: Callable, ok: bool = false) -> String:
	flow.call()
	var dialog := await _gui_wait_dialog()
	if dialog == null:
		_log("[selftest] FAIL: %s showed no dialog" % name)
		return ""
	var text := dialog.dialog_text
	await _gui_shot(name, dialog)
	_gui_press(dialog, ok)
	await _gui_frames(5)
	return text


func _gui_test_dialogs() -> bool:
	await _gui_show_dock()
	_selftest_auto_answer = ""
	var paths := await _gui_stage(OS.get_cmdline_user_args()[0].trim_prefix("--p4-selftest-gui-"))
	var cl := String(paths.cl)
	var gd := ProjectSettings.globalize_path("res://main.gd")
	await _gui_capture("dialog-new-changelist", func() -> void: _on_new_changelist_pressed())
	await _gui_capture("dialog-submit-description", func() -> void: _submit_changelist("default", []))
	await _gui_capture("dialog-revert", func() -> void: _revert_path("res://main.gd"))
	await _gui_capture("dialog-reconcile", func() -> void: _reconcile_flow())
	await _gui_capture("dialog-get-latest", func() -> void: _get_latest_flow())
	await _gui_capture("dialog-shelve", func() -> void: _shelve_changelist(cl, false))
	await _gui_capture("dialog-delete-shelf", func() -> void: _delete_shelf(cl, []))
	await _gui_capture("dialog-revert-unchanged", func() -> void: _revert_unchanged_flow())
	var choices := await _pending_changelist_choices()
	await _gui_capture("dialog-checkout-target", func() -> void:
		_show_checkout_target_dialog(("'levels/level_01.tscn' isn't checked out. Check it out so you " +
				"can save your change?"), "Check Out", "Discard My Changes", choices))
	var row := {"key": _path_key(gd), "local": gd, "mtime": 1, "checked": 1, "action": "edit"}
	_watch_refused[_path_key(gd)] = "locked by mate@mate-ws"
	await _gui_capture("dialog-lock", func() -> void: _ask_about_refused([row]))
	_watch_refused.erase(_path_key(gd))
	_watch_alerted.clear()
	var many: Array = []
	for i in 24:
		many.append({"key": "k%d" % i, "local": _client_root.path_join("build/out_%02d.bin" % i), "mtime": 1,
				"checked": 1, "action": "add" if i % 3 else "delete"})
	await _gui_capture("dialog-bulk", func() -> void: _ask_about_bulk(many))
	await _gui_capture("dialog-allwrite-offer", func() -> void: _show_allwrite_offer())
	await _gui_capture("dialog-project-godot-offer", func() -> void: _show_project_godot_offer())
	await _gui_capture("dialog-connection", func() -> void: _show_connection_dialog("ssl:perforce.example.com:1666", "dev"))
	await _gui_capture("dialog-workspace", func() -> void:
		_show_option_dialog("P4Godot - Connection Setup", ("Server: ssl:perforce.example.com:1666\nUser: dev\n\n" +
				"Found a workspace whose root contains this project.\nWorkspace to use for this project " +
				"(stored per-project, per-user):"), PackedStringArray(["dev-ws  (C:/Projects/Game)",
				"dev-laptop  (D:/Work/Game)"]), 0, "Use This Workspace", CHANGE_SERVER_TEXT))
	await _gui_capture("dialog-password", func() -> void:
		_show_input_dialog("Log In to Perforce", "Password for dev on ssl:perforce.example.com:1666:", "", false,
				"Log In", true))
	await _gui_capture("dialog-alert", func() -> void: _show_alert(NOT_CONNECTED_MESSAGE))
	await _gui_capture("dialog-resolve", func() -> void:
		_resolve_one({"res_path": "res://scripts/player.gd", "local": gd, "binary": false,
				"special": false, "shelf": ""}, 1, 2))
	await _gui_capture("dialog-resolve-binary", func() -> void:
		_resolve_one({"res_path": "res://art/icon.svg", "local": gd, "binary": true,
				"special": false, "shelf": ""}, 2, 2))
	_selftest_auto_answer = "confirm"
	await _gui_cleanup(paths)
	return true


func _gui_test_windows() -> bool:
	await _gui_show_dock()
	_selftest_auto_answer = ""
	var paths := await _gui_stage(OS.get_cmdline_user_args()[0].trim_prefix("--p4-selftest-gui-"))
	var gd := ProjectSettings.globalize_path("res://main.gd")
	var fw := FileAccess.open(gd, FileAccess.WRITE)
	fw.store_string("extends Node\n\n## The game's entry point.\n\n\nfunc _ready() -> void:\n\tprint(\"Hello from P4Godot\")\n\tset_process(true)\n")
	fw.close()
	_on_toggle_log_pressed()
	await _gui_frames(10)
	await _gui_shot("window-log", log_window)
	_on_toggle_log_pressed()
	_diff_path("res://main.gd")
	await _gui_frames(60)
	await _gui_shot("window-diff", diff_window)
	diff_window.hide()
	# History: a few submitted revisions of main.gd first.
	for i in 3:
		fw = FileAccess.open(gd, FileAccess.WRITE)
		fw.store_string("extends Node\n# revision %d\n" % i)
		fw.close()
		await _p4_exec_logged(["submit", "-d", "Tune the main script, round %d\n\nSmaller steps this time." % (i + 1), gd])
		await _p4_exec_logged(["edit", gd])
	_show_history("res://main.gd")
	await _gui_frames(60)
	await _gui_shot("window-history", history_window)
	history_window.hide()
	_show_shelves(String(paths.cl))
	await _gui_frames(90)
	await _gui_shot("window-shelves", shelves_window)
	shelves_window.hide()
	# The transfer progress window, part-way through a submit.
	var tracker := P4Progress.new()
	tracker.total_files = 14
	tracker.total_bytes = 52 * 1024 * 1024
	_progress_begin("Submitting", "Submitting changelist #12: 14 files", tracker)
	tracker.files_done = 5
	tracker._bytes_done = 19 * 1024 * 1024
	tracker.reporting = true
	tracker.current = "art/environment/forest_tiles.png"
	_progress_refresh()
	await _gui_frames(20)
	await _gui_shot("window-progress", _progress_window)
	_progress_end()
	_selftest_auto_answer = "confirm"
	await _gui_cleanup(paths)
	return true


## Right-click at a point of the editor window (its own coordinates), as the
## mouse would. Pushed into the window's viewport: the OS input queue only
## reaches a window with focus, and a test's window may not have it.
func _gui_right_click(at: Vector2) -> void:
	var vp := EditorInterface.get_base_control().get_viewport()
	await _gui_hover(at)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_RIGHT
		e.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		e.pressed = pressed
		e.position = at
		e.global_position = at
		vp.push_input(e, true)
		await _gui_frames(2)


func _gui_hover(at: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = at
	e.global_position = at
	EditorInterface.get_base_control().get_viewport().push_input(e, true)
	await _gui_frames(2)


## The newest visible PopupMenu in the editor (a context menu just opened).
func _gui_open_menu() -> PopupMenu:
	var found: PopupMenu = null
	for p in get_tree().root.find_children("*", "PopupMenu", true, false):
		if (p as PopupMenu).visible:
			found = p
	return found


## Open the submenu whose item reads `label` in `menu`, by keyboard.
func _gui_open_submenu(menu: PopupMenu, label: String) -> PopupMenu:
	for i in menu.item_count:
		if menu.get_item_text(i) == label:
			menu.set_focused_item(i)
			var key := InputEventKey.new()
			key.keycode = KEY_RIGHT
			key.pressed = true
			menu.push_input(key)
			await _gui_frames(4)
			var sub := menu.get_item_submenu_node(i)
			if sub and not sub.visible:
				# Opened beside its item, where the mouse would have opened it.
				sub.popup(Rect2i(menu.position + Vector2i(menu.size.x, 0), Vector2i.ZERO))
				await _gui_frames(4)
			return sub
	return null


func _gui_test_editor() -> bool:
	await _gui_show_dock()
	_selftest_auto_answer = ""
	var ok := true
	# The FileSystem dock: the P4 submenu on a file, and the hover tooltip.
	var fs := EditorInterface.get_file_system_dock()
	fs.navigate_to_path("res://scripts/player.gd")
	await _gui_frames(20)
	var fs_tree: Tree = null
	for t in fs.find_children("*", "Tree", true, false):
		if (t as Tree).is_visible_in_tree() and (t as Tree).get_selected() != null:
			fs_tree = t
	if fs_tree:
		var item := fs_tree.get_selected()
		var rect := fs_tree.get_item_area_rect(item, 0)
		var at := fs_tree.get_global_rect().position + rect.position + rect.size * 0.5
		# The P4 lines come from status a first hover fetches; the second shows it.
		await _gui_hover(at)
		await _gui_frames(90)
		await _gui_hover(at + Vector2(0, 200))
		await _gui_frames(30)
		await _gui_hover(at)
		await _gui_frames(120)
		await _gui_shot("fs-tooltip")
		await _gui_right_click(at)
		await _gui_frames(5)
		var menu := _gui_open_menu()
		if menu:
			var sub := await _gui_open_submenu(menu, "P4")
			await _gui_shot("fs-menu")
			if sub:
				await _gui_shot("fs-p4-submenu", sub)
			menu.hide()
		else:
			_log("[selftest] FAIL: no FileSystem dock menu opened")
			ok = false
	else:
		_log("[selftest] FAIL: couldn't find the FileSystem tree")
		ok = false
	# An image's tooltip: Godot builds the rich kind (preview, type, size) for
	# images, which is where the plugin's lines go.
	fs.navigate_to_path("res://art/icon.svg")
	await _gui_frames(20)
	if fs_tree and fs_tree.get_selected():
		var img_item := fs_tree.get_selected()
		var img_rect := fs_tree.get_item_area_rect(img_item, 0)
		var img_at := fs_tree.get_global_rect().position + img_rect.position + img_rect.size * 0.5
		await _gui_hover(img_at)
		await _gui_frames(90)
		await _gui_hover(img_at + Vector2(0, 200))
		await _gui_frames(30)
		await _gui_hover(img_at)
		await _gui_frames(120)
		await _gui_shot("fs-tooltip-image")
		_log("[selftest] tooltip cache has icon.svg: %s" % _fstat_cache.has("res://art/icon.svg"))
	# The code editor: a script with changed lines (the marks), its P4
	# submenu, and Who Changed This Line.
	var script := load("res://scripts/player.gd") as Script
	EditorInterface.set_main_screen_editor("Script")
	EditorInterface.edit_script(script)
	await _gui_frames(30)
	var code := EditorInterface.get_script_editor().get_current_editor().get_base_editor() as CodeEdit
	if code:
		await _p4_exec_logged(["edit", ProjectSettings.globalize_path("res://scripts/player.gd")])
		code.text = "extends Node\n\n## Moves the player.\n\nfunc _ready() -> void:\n\tset_process(true)\n\n\nfunc _process(delta: float) -> void:\n\tposition_changed(delta)\n"
		code.text_changed.emit()
		await _gui_frames(60)
		await _gui_shot("code-marks")
		var line_rect := code.get_rect_at_line_column(4, 2)
		var at := code.get_global_rect().position + Vector2(line_rect.position) + Vector2(4, 4)
		code.set_caret_line(4)
		await _gui_right_click(at)
		await _gui_frames(5)
		var menu := _gui_open_menu()
		if menu:
			var sub := await _gui_open_submenu(menu, "P4")
			await _gui_shot("code-menu")
			if sub:
				await _gui_shot("code-p4-submenu", sub)
			menu.hide()
		await _gui_capture("dialog-who-changed", func() -> void:
			_show_who_changed_line("res://scripts/player.gd", 1, code.text, true))
		code.text = load("res://scripts/player.gd").source_code
		await _p4_exec_logged(["revert", ProjectSettings.globalize_path("res://scripts/player.gd")])
	else:
		_log("[selftest] FAIL: no code editor")
		ok = false
	_selftest_auto_answer = "confirm"
	return ok


# ---------------------------------------------------------------------------
# README pictures (GUI=1 DEMO=<Godot's Skeleton2D demo> tools/run-live-tests.sh
# gui-readme): the README's screenshots and its animated GIF, taken from a
# real game project in a realistic state. The runner has a teammate (mate)
# submit two changes to the player script first, so its history has two
# authors.
# ---------------------------------------------------------------------------

## Where an embedded window is drawn in the editor's picture, title bar and
## border included.
func _gui_window_rect(window: Window) -> Rect2i:
	var title := 0
	if not window.borderless:
		title = maxi(window.get_theme_constant("title_height"), int(32 * EditorInterface.get_editor_scale()))
	var margin := 6
	return Rect2i(window.position - Vector2i(margin, title + margin),
			window.size + Vector2i(margin * 2, title + margin * 2))


## Save the part of the editor's picture inside `rect` (plus a small border).
func _gui_shot_rect(name: String, rect: Rect2i) -> void:
	var dir := OS.get_environment("P4GODOT_SHOTS")
	if dir.is_empty():
		return
	await _gui_frames(3)
	var full := EditorInterface.get_base_control().get_window().get_texture().get_image()
	rect = rect.grow(8).intersection(Rect2i(Vector2i.ZERO, full.get_size()))
	var image := full.get_region(rect)
	var path := dir.path_join(name + ".png")
	image.save_png(path)
	_log("[selftest] screenshot %s (%dx%d)" % [path, image.get_width(), image.get_height()])


# The animated GIF's frames: PNGs of the editor plus a list of how long each
# is shown, put together by tools/readme-gif.py.
var _gif_frames := PackedStringArray()


func _gui_gif_frame(hold_ms: int) -> void:
	var dir := OS.get_environment("P4GODOT_SHOTS")
	if dir.is_empty():
		return
	await _gui_frames(3)
	DirAccess.make_dir_recursive_absolute(dir.path_join("gif"))
	var name := "%04d.png" % _gif_frames.size()
	EditorInterface.get_base_control().get_window().get_texture().get_image() \
			.save_png(dir.path_join("gif").path_join(name))
	_gif_frames.append("%s %d" % [name, hold_ms])


func _gui_gif_finish(crop: Rect2i) -> void:
	var dir := OS.get_environment("P4GODOT_SHOTS")
	if dir.is_empty():
		return
	var f := FileAccess.open(dir.path_join("gif/frames.txt"), FileAccess.WRITE)
	f.store_line("crop %d %d %d %d" % [crop.position.x, crop.position.y, crop.size.x, crop.size.y])
	for line in _gif_frames:
		f.store_line(line)
	f.close()
	_log("[selftest] gif: %d frames" % _gif_frames.size())


## Right-click a dock row and save the panel with its menu open.
func _gui_readme_row_menu(name: String, row: TreeItem) -> bool:
	if row == null:
		_log("[selftest] FAIL: no row for %s" % name)
		return false
	row.select(0)
	tree.scroll_to_item(row)
	await _gui_frames(2)
	var rect := tree.get_item_area_rect(row, 0)
	var at := Vector2i(tree.get_screen_position() + rect.position + Vector2(rect.size.x * 0.35, rect.size.y * 0.5))
	_context_target = row.get_metadata(0)
	_populate_context_menu(_context_target)
	context_menu.reset_size()
	context_menu.position = at
	context_menu.popup()
	await _gui_frames(4)
	var area := Rect2i(dock.get_global_rect()).merge(Rect2i(context_menu.position, context_menu.size))
	await _gui_shot_rect(name, area)
	context_menu.hide()
	return true


## Give the bottom panel `height` pixels, as dragging its divider would. The
## editor's split (4.7) ignores split_offset here (measured) but honours a
## minimum size on the panel, which is what this sets; 0 gives the panel back.
func _gui_panel_height(height: int) -> void:
	var panel: Node = dock
	while panel != null and not (panel.get_parent() is SplitContainer
			and (panel.get_parent() as SplitContainer).vertical):
		panel = panel.get_parent()
	if panel == null:
		_log("[selftest] no split above the panel")
		return
	(panel as Control).custom_minimum_size.y = height
	await _gui_frames(10)
	_log("[selftest] panel height %d (wanted %d)" % [int(dock.size.y), height])


func _gui_test_readme() -> bool:
	if not FileAccess.file_exists("res://player/player.gd"):
		_log("[selftest] FAIL: gui-readme takes DEMO=<Godot's Skeleton2D demo>")
		return false
	await _gui_show_dock()
	_selftest_auto_answer = ""
	var ok := true
	EditorInterface.open_scene_from_path("res://level.tscn")
	await _gui_frames(60)
	# --- The GIF: edit a script that isn't checked out, say yes, and the file
	# is in the default changelist.
	var player_res := "res://player/player.gd"
	var player := ProjectSettings.globalize_path(player_res)
	var script := load(player_res) as Script
	EditorInterface.set_main_screen_editor("Script")
	EditorInterface.edit_script(script)
	await _gui_frames(30)
	_rebuild_tree(await _query_pending_model())
	var code := EditorInterface.get_script_editor().get_current_editor().get_base_editor() as CodeEdit
	if code == null:
		_log("[selftest] FAIL: no code editor")
		return false
	var line := -1
	for i in code.get_line_count():
		if code.get_line(i).begins_with("const WALK_SPEED"):
			line = i
	var col := code.get_line(line).find("200.0")
	code.set_caret_line(line)
	code.set_caret_column(col)
	# Near the top, where the prompt (centred on the editor) won't cover it.
	code.set_line_as_first_visible(maxi(0, line - 3))
	await _gui_frames(10)
	await _gui_gif_frame(1600)
	code.select(line, col, line, col + 5)
	await _gui_gif_frame(800)
	code.delete_selection()
	code.insert_text_at_caret("2")
	code.text_changed.emit()
	await _gui_gif_frame(250)
	var prompt := await _gui_wait_dialog()
	if prompt == null:
		_log("[selftest] FAIL: editing showed no checkout prompt")
		return false
	await _gui_gif_frame(3200)
	_gui_press(prompt, true)
	var deadline := Time.get_ticks_msec() + 10000
	while _gui_row({"type": "file", "res_path": player_res}) == null and Time.get_ticks_msec() < deadline:
		await _gui_frames(5)
	ok = ok and _gui_row({"type": "file", "res_path": player_res}) != null
	await _gui_gif_frame(1200)
	for ch in ["4", "0", ".", "0"]:
		code.insert_text_at_caret(ch)
		code.text_changed.emit()
		await _gui_gif_frame(140)
	await _gui_gif_frame(3500)
	var se := EditorInterface.get_script_editor()
	await _gui_gif_finish(Rect2i(se.get_global_rect().position.x - 4, 0,
			se.get_global_rect().size.x + 8, EditorInterface.get_base_control().get_window().size.y))
	# More to the player change, for a diff with lines on both sides; saved the
	# way the script editor saves.
	var text := code.text
	text = text.replace("const JUMP_VELOCITY = -300", "const JUMP_VELOCITY = -340")
	text = text.replace("# Keep this in sync with the AnimationTree's state names.\n", "")
	text = text.replace("const TERMINAL_VELOCITY = 360\n", "const TERMINAL_VELOCITY = 360\n" +
			"## How long holding jump keeps adding height, in seconds.\nconst JUMP_HOLD_TIME = 0.2\n")
	code.text = text
	script.source_code = text
	ResourceSaver.save(script, player_res)
	code.tag_saved_version()
	EditorInterface.set_main_screen_editor("2D")
	# Room for every changelist in the panel pictures.
	await _gui_panel_height(420)
	# --- The rest of a working day. A first look at the project before any
	# of it, as the watcher has when the editor has been open a while: a
	# missing file is one it saw before.
	detect_external_checkbox.set_pressed_no_signal(true)
	auto_checkout_detected_checkbox.set_pressed_no_signal(false)
	await _selftest_watch_pass()
	var g := func(res: String) -> String: return ProjectSettings.globalize_path(res)
	var sprite := Image.load_from_file(g.call("res://player/gBot.png"))
	sprite.adjust_bcs(1.05, 1.0, 0.35)
	sprite.save_png(g.call("res://player/gBot_winter.png"))
	await _p4_exec_logged(["add", g.call("res://player/gBot_winter.png")])
	await _p4_exec_logged(["edit", _client_root.path_join("art/readme.txt")])
	var parallax := await _create_selftest_change("Parallax: slower clouds and a third layer of far platforms", "")
	DirAccess.copy_absolute(g.call("res://level/background/distant_platforms_2.png"),
			g.call("res://level/background/distant_platforms_3.png"))
	await _p4_exec_logged(["edit", "-c", parallax, g.call("res://level/parallax_background.tscn")])
	await _p4_exec_logged(["add", "-c", parallax, g.call("res://level/background/distant_platforms_3.png")])
	await _p4_exec_logged(["delete", "-c", parallax, g.call("res://level/background/cloud_3.png")])
	await _p4_exec_logged(["shelve", "-c", parallax])
	var tiles := await _create_selftest_change("Tileset: fix the seams along the grass edge", "")
	await _p4_exec_logged(["edit", "-c", tiles, g.call("res://level/tileset/tileset.tres")])
	# What the watcher lists, with automatic opening off: a script changed in
	# another editor, a new image, a deleted file.
	var level := g.call("res://level/level.gd") as String
	_set_file_writable(level, true)
	var lf := FileAccess.open(level, FileAccess.READ_WRITE)
	lf.seek_end()
	lf.store_string("\n# Camera limits follow the tileset's used rect.\n")
	lf.close()
	DirAccess.copy_absolute(g.call("res://level/background/sky.png"), g.call("res://level/background/sky_night.png"))
	# Read-only, as Perforce leaves it: Windows won't delete it until it isn't.
	_set_file_writable(g.call("res://README.md"), true)
	if DirAccess.remove_absolute(g.call("res://README.md")) != OK:
		_log("[selftest] FAIL: couldn't delete README.md")
		ok = false
	await _selftest_settle()
	await _selftest_watch_pass()
	_rebuild_tree(await _query_pending_model())
	await _gui_frames(30)
	# --- The pictures.
	ok = await _gui_readme_row_menu("changelist-dock", _gui_row({"type": "file", "res_path": player_res})) and ok
	ok = await _gui_readme_row_menu("watcher", _gui_row({"type": "detected", "action": "add"})) and ok
	var default_files: Array = []
	for cl in _last_changelists:
		if String(cl.change) == "default":
			default_files = cl.files
	var confirm_text := await _gui_capture("submit-confirm", func() -> void:
		_submit_changelist("default", default_files, "Player: faster walk, higher jump, and a winter skin"))
	ok = ok and confirm_text.contains("Submit the default changelist")
	_diff_path(player_res)
	await _gui_frames(60)
	await _gui_shot("diff-viewer", diff_window)
	diff_window.hide()
	_show_history(player_res)
	await _gui_frames(60)
	await _gui_shot("history", history_window)
	history_window.hide()
	_show_shelves(parallax)
	await _gui_frames(90)
	await _gui_shot("shelves", shelves_window)
	shelves_window.hide()
	await _gui_capture("connection-setup", func() -> void:
		_show_option_dialog("P4Godot - Connection Setup", ("Server: ssl:perforce.example.com:1666\nUser: dev\n\n" +
				"Found a workspace whose root contains this project.\nWorkspace to use for this project " +
				"(stored per-project, per-user):"), PackedStringArray(["dev-ws  (C:/Projects/Skeleton2D)",
				"dev-laptop  (D:/Work/Skeleton2D)"]), 0, "Use This Workspace", CHANGE_SERVER_TEXT))
	# The FileSystem dock's P4 submenu on the player script.
	var fs := EditorInterface.get_file_system_dock()
	fs.navigate_to_path(player_res)
	await _gui_frames(20)
	var fs_tree: Tree = null
	for t in fs.find_children("*", "Tree", true, false):
		if (t as Tree).is_visible_in_tree() and (t as Tree).get_selected() != null:
			fs_tree = t
	if fs_tree:
		var item := fs_tree.get_selected()
		var rect := fs_tree.get_item_area_rect(item, 0)
		var at := fs_tree.get_global_rect().position + rect.position + Vector2(rect.size.x * 0.3, rect.size.y * 0.5)
		await _gui_right_click(at)
		await _gui_frames(5)
		var menu := _gui_open_menu()
		if menu:
			# At the click, as the mouse would place it: under test Godot puts
			# it by the window's screen position, which embedding offsets.
			var bottom := EditorInterface.get_base_control().get_window().size.y
			menu.position = Vector2i(int(at.x), mini(int(at.y), bottom - menu.size.y - 8))
			await _gui_frames(2)
			var sub := await _gui_open_submenu(menu, "P4")
			var area := Rect2i(fs.get_global_rect()).merge(Rect2i(menu.position, menu.size))
			if sub:
				area = area.merge(Rect2i(sub.position, sub.size))
			await _gui_shot_rect("filesystem-dock", area)
			menu.hide()
		else:
			_log("[selftest] FAIL: no FileSystem dock menu opened")
			ok = false
	else:
		_log("[selftest] FAIL: couldn't find the FileSystem tree")
		ok = false
	# Back as it was, for the runner's check that nothing is left open.
	_selftest_auto_answer = "confirm"
	await _p4_exec_logged(["shelve", "-d", "-c", parallax])
	await _p4_exec_logged(["revert", "//%s/..." % _p4_client])
	await _p4_exec_logged(["change", "-d", parallax])
	await _p4_exec_logged(["change", "-d", tiles])
	return ok
