"""End-to-end journal enforcement against the mock HTTP server."""
import json
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import ClassVar
from unittest.mock import patch

import test_client as fixture

State = fixture.State


class JournalTest(unittest.TestCase):
    settings: dict
    temp: ClassVar[tempfile.TemporaryDirectory]

    @classmethod
    def setUpClass(cls):
        fixture.SilverBulletPluginTest.setUpClass.__func__(cls)

    @classmethod
    def tearDownClass(cls):
        fixture.SilverBulletPluginTest.tearDownClass.__func__(cls)

    setUp = fixture.SilverBulletPluginTest.setUp
    _register = fixture.SilverBulletPluginTest._register
    _call = staticmethod(fixture.SilverBulletPluginTest._call)

    def test_create_journals_same_space_at_new_york_date_boundary(self):
        context = self._register()
        module = sys.modules["inigo_silverbullet"]
        # 00:30 UTC is still the previous day in New York.
        clock = datetime(2026, 10, 25, 0, 30, tzinfo=timezone.utc)
        with patch.object(module, "_journal_now", return_value=clock, create=True):
            for space in ("personal", "ksp"):
                result = self._call(context, "silverbullet_create", {
                    "space": space, "page": "Odd [name](ok)|note", "content": "body",
                    "change_summary": "Saved [source](https://evil) <script> & details",
                })
                self.assertTrue(result["journal"]["verified"])
                self.assertEqual(result["journal"]["page"], "Journal/2026-10-24.md")
                journal = State.spaces[space]["Journal/2026-10-24.md"]["content"]
                self.assertIn("/Odd%20%5Bname%5D%28ok%29%7Cnote", journal)
                self.assertNotIn("<script>", journal)
                self.assertNotIn("](https://evil)", journal)
                self.assertEqual(journal.count("<!-- inigo-journal:"), 1)

    def test_links_are_space_root_relative_not_deployment_relative(self):
        result = self._call(self._register(), "silverbullet_create", {
            "space": "ksp", "page": "Projects/Decision", "content": "body",
            "change_summary": "Recorded decision",
        })
        entry = State.spaces["ksp"][result["journal"]["page"]]["content"]
        self.assertIn("[note](/Projects/Decision.md)", entry)
        self.assertNotIn("[note](/ksp/", entry)
        source = Path(self.temp.name) / "space-root.png"
        source.write_bytes(b"image")
        upload = self._call(self._register(), "silverbullet_upload_file", {
            "space": "ksp", "source_path": str(source), "destination": "assets/root.png",
            "change_summary": "Saved diagram",
        })
        self.assertEqual(upload["markdown_image"], "![root.png](/assets/root.png)")

    def test_all_mutations_require_summary_and_log_once(self):
        for space in ("personal", "ksp"):
            with self.subTest(space=space):
                context = self._register()
                page = "Shared.md"
                stamp = State.spaces[space][page]["last_modified"]
                operations = [
                    ("append", {"page": page, "content": "more", "expected_last_modified": stamp}),
                    ("update", {"page": page, "content": "replacement"}),
                    ("move", {"source": page, "destination": "Archive/New.md"}),
                    ("soft_delete", {"page": "Archive/New.md"}),
                    ("soft_delete", {"page": "Trash/Archive/New.md", "permanent": True}),
                ]
                for tool, args in operations:
                    source = args.get("page", args.get("source"))
                    args.update(space=space, expected_last_modified=State.spaces[space][source]["last_modified"])
                    before = {key: dict(value) for key, value in State.spaces[space].items()}
                    refused = self._call(context, "silverbullet_" + tool, args)
                    self.assertIn("change_summary", refused.get("error", ""))
                    self.assertEqual(State.spaces[space], before)
                    args["change_summary"] = "Changed the note"
                    result = self._call(context, "silverbullet_" + tool, args)
                    self.assertNotIn("error", result)
                    self.assertTrue(result["journal"]["verified"])
                journal = next(v["content"] for k, v in State.spaces[space].items() if k.startswith("Journal/"))
                self.assertEqual(journal.count("<!-- inigo-journal:"), 5)
                self.assertIn("Archive/New.md", journal)
                self.assertIn("Trash/Archive/New.md", journal)

    def test_journal_failure_is_partial_and_retry_survives_new_registration(self):
        context = self._register()
        State.fail_journal_put = True
        result = self._call(context, "silverbullet_create", {
            "space": "ksp", "page": "New", "content": "body", "change_summary": "Saved facts",
        })
        self.assertTrue(result.get("verified"), result)
        self.assertFalse(result["journal"]["verified"])
        self.assertTrue(result["partial_completion"])
        self.assertIn("retry", result["journal"])
        payload = result["journal"]["retry"]
        self.assertEqual(set(payload), {"space", "journal_page", "entry", "operation_id"})
        self.assertIn("New.md", State.spaces["ksp"])
        State.fail_journal_put = False
        # A new plugin/client has no local operation state.
        context = self._register()
        retry = self._call(context, "silverbullet_journal_retry", payload)
        self.assertTrue(retry["verified"], retry)
        stamp = State.spaces["ksp"][payload["journal_page"]]["last_modified"]
        retry = self._call(self._register(), "silverbullet_journal_retry", payload)
        self.assertTrue(retry["already_present"])
        journal = State.spaces["ksp"][payload["journal_page"]]
        self.assertEqual(journal["last_modified"], stamp)
        self.assertEqual(journal["content"].count("<!-- inigo-journal:"), 1)
        # An entirely fresh interpreter must also recognize the persisted marker.
        code = (
            "import json,sys; from test_client import SilverBulletPluginTest; "
            "data=json.load(sys.stdin); test=SilverBulletPluginTest(); "
            "test.settings=data['settings']; context=test._register(); "
            "print(json.dumps(test._call(context,'silverbullet_journal_retry',data['payload'])))"
        )
        child = subprocess.run(
            [sys.executable, "-c", code], input=json.dumps({"settings": self.settings, "payload": payload}),
            text=True, capture_output=True, timeout=15, cwd=Path(__file__).parent,
        )
        self.assertEqual(child.returncode, 0, child.stderr)
        retry = json.loads(child.stdout)
        self.assertTrue(retry["already_present"], retry)
        self.assertEqual(journal["last_modified"], stamp)
        self.assertNotIn(payload["journal_page"], State.spaces["personal"])

    def test_unchanged_update_preserves_version_and_skips_journal(self):
        context = self._register()
        original = dict(State.spaces["personal"]["Shared.md"])
        result = self._call(context, "silverbullet_update", {
            "page": "Shared", "content": original["content"],
            "expected_last_modified": original["last_modified"], "change_summary": "Same content",
        })
        self.assertEqual(result["action"], "unchanged")
        self.assertTrue(result["verified"])
        self.assertNotIn("journal", result)
        self.assertEqual(State.spaces["personal"]["Shared.md"], original)
        self.assertEqual(State.journal_puts, 0)

    def test_journal_conflicts_retry_bounded_and_preserve_existing_entries(self):
        context = self._register()
        State.journal_conflicts = 2
        result = self._call(context, "silverbullet_create", {
            "page": "One", "content": "first", "change_summary": "Saved first",
        })
        self.assertTrue(result["journal"]["verified"], result)
        self.assertEqual(State.journal_puts, 3)
        State.journal_conflicts = 10
        result = self._call(context, "silverbullet_create", {
            "page": "Two", "content": "second", "change_summary": "Saved second",
        })
        self.assertTrue(result["verified"])
        self.assertFalse(result["journal"]["verified"])
        self.assertEqual(State.journal_puts, 6)
        payload = result["journal"]["retry"]
        State.journal_conflicts = 0
        result = self._call(context, "silverbullet_journal_retry", payload)
        self.assertTrue(result["verified"])
        journal = State.spaces["personal"][payload["journal_page"]]["content"]
        self.assertEqual(journal.count("<!-- inigo-journal:"), 2)
        self.assertIn("Saved first", journal)
        self.assertIn("Saved second", journal)

    def test_upload_requires_summary_and_logs_only_new_asset(self):
        source = Path(self.temp.name) / "journal-image.png"
        source.write_bytes(b"image")
        context = self._register()
        args = {"space": "ksp", "source_path": str(source), "destination": "assets/image.png"}
        refused = self._call(context, "silverbullet_upload_file", args)
        self.assertIn("change_summary", refused.get("error", ""))
        self.assertNotIn("assets/image.png", State.spaces["ksp"])
        args["change_summary"] = "Saved diagram"
        result = self._call(context, "silverbullet_upload_file", args)
        self.assertTrue(result["journal"]["verified"])
        page = result["journal"]["page"]
        self.assertIn("/assets/image.png", State.spaces["ksp"][page]["content"])
        before = dict(State.spaces["ksp"][page])
        result = self._call(context, "silverbullet_upload_file", args)
        self.assertEqual(result["action"], "already_present")
        self.assertNotIn("journal", result)
        self.assertEqual(State.spaces["ksp"][page], before)

    def test_retry_refuses_unsafe_entries_paths_and_operation_collision(self):
        context = self._register()
        valid = {"space": "personal", "journal_page": "Journal/2026-10-24.md",
                 "operation_id": "a" * 32, "entry": "- created: [note](/New.md) — Saved facts"}
        for updates in ({"entry": "- <script>alert(1)</script>"},
                        {"entry": "- created: [note](javascript:alert) — Bad"},
                        {"entry": "- created: [note](/New.md) — first\u2028second"},
                        {"journal_page": "Journal/../Escape.md"},
                        {"journal_page": "Library/2026-10-24.md"},
                        {"journal_page": "Journal/2026-02-30.md"},
                        {"journal_page": "journal/2026-10-24.md"},
                        {"operation_id": "<!-- bad -->"}, {"space": "unknown"}):
            with self.subTest(updates=updates):
                result = self._call(context, "silverbullet_journal_retry", {**valid, **updates})
                self.assertIn("error", result)
        self.assertEqual(State.journal_puts, 0)
        result = self._call(context, "silverbullet_journal_retry", valid)
        self.assertTrue(result["verified"])
        result = self._call(context, "silverbullet_journal_retry", {
            **valid, "entry": "- created: [note](/New.md) — Different facts",
        })
        self.assertIn("different journal entry", result["error"])
        self.assertEqual(State.journal_puts, 1)
        self.settings["spaces"]["personal"]["allowed_write_paths"] = ["Projects"]
        denied = self._call(self._register(), "silverbullet_journal_retry", valid)
        self.assertIn("allowlist", denied["error"])

    def test_schema_documents_conditionally_required_summary(self):
        context = self._register()
        for name in ("create", "append", "update", "move", "soft_delete", "upload_file"):
            schema = context.tools["silverbullet_" + name]["schema"]
            summary = schema["parameters"]["properties"].get("change_summary")
            self.assertIsNotNone(summary)
            self.assertEqual(summary["maxLength"], 240)
            self.assertIn("journal", summary["description"].lower())

    def test_new_journal_creation_never_overwrites_concurrent_human_entry(self):
        State.journal_create_race = True
        result = self._call(self._register(), "silverbullet_create", {
            "page": "New", "content": "body", "change_summary": "Saved facts",
        })
        self.assertTrue(result["journal"]["verified"], result)
        journal = State.spaces["personal"][result["journal"]["page"]]["content"]
        self.assertIn("Concurrent human entry", journal)
        self.assertIn("Saved facts", journal)

    def test_delete_requires_verified_absence_before_logging_success(self):
        State.ignore_delete = True
        result = self._call(self._register(), "silverbullet_soft_delete", {
            "page": "Shared", "permanent": True, "expected_last_modified": 1_750_000_000_000,
            "change_summary": "Removed outdated note",
        })
        self.assertIn("verification failed", result.get("error", ""))
        self.assertIn("Shared.md", State.spaces["personal"])
        self.assertEqual(State.journal_puts, 0)

    def test_only_daily_journal_paths_are_exempt(self):
        context = self._register()
        for page in ("Journal/Project work", "journal/2026-10-24.md"):
            with self.subTest(page=page):
                refused = self._call(context, "silverbullet_create", {
                    "page": page, "content": "body",
                })
                self.assertIn("change_summary", refused.get("error", ""))
                created = self._call(context, "silverbullet_create", {
                    "page": page, "content": "body", "change_summary": "Recorded work",
                })
                self.assertTrue(created["journal"]["verified"], created)

    def test_journal_only_mutations_need_no_summary_and_never_recurse(self):
        context = self._register()
        page = "Journal/2026-10-24.md"
        result = self._call(context, "silverbullet_create", {"page": page, "content": "day"})
        self.assertNotIn("error", result)
        for tool, content in (("append", "entry"), ("update", "edited day")):
            result = self._call(context, "silverbullet_" + tool, {
                "page": page, "content": content, "expected_last_modified": result["last_modified"],
            })
            self.assertNotIn("error", result)
            self.assertNotIn("journal", result)
        result = self._call(context, "silverbullet_move", {
            "source": page, "destination": "Journal/2026-10-23.md",
            "expected_last_modified": result["last_modified"],
        })
        self.assertNotIn("error", result)
        self.assertNotIn("journal", result)
        result = self._call(context, "silverbullet_soft_delete", {
            "page": result["page"], "expected_last_modified": result["last_modified"],
        })
        self.assertNotIn("error", result)
        self.assertNotIn("journal", result)
        self.assertEqual([key for key in State.spaces["personal"] if key.startswith("Journal/")], [])
        self.assertEqual(State.journal_puts, 4)

    def test_failures_never_log_and_denied_journal_reports_partial(self):
        context = self._register()
        for name, args in (
            ("update", {"page": "Shared", "content": "bad", "expected_last_modified": 0}),
            ("append", {"page": "Shared", "content": "bad"}),
            ("create", {"page": "Shared", "content": "bad"}),
            ("move", {"source": "Shared", "destination": "New", "expected_last_modified": 0}),
            ("soft_delete", {"page": "Shared", "expected_last_modified": 0}),
            ("create", {"page": "Library/Bad", "content": "bad"}),
        ):
            result = self._call(context, "silverbullet_" + name, {**args, "change_summary": "Attempted edit"})
            self.assertIn("error", result)
        self.assertEqual(State.journal_puts, 0)
        self.settings["spaces"]["personal"]["allowed_write_paths"] = ["Projects"]
        result = self._call(self._register(), "silverbullet_create", {
            "page": "Projects/New", "content": "new", "change_summary": "Saved facts",
        })
        self.assertTrue(result["verified"])
        self.assertTrue(result["partial_completion"])
        self.assertFalse(result["journal"]["verified"])
        self.assertIn("allowlist", result["journal"]["error"])
        self.assertIn("Projects/New.md", State.spaces["personal"])
        self.assertEqual(State.journal_puts, 0)

    def test_concurrent_mutations_share_the_journal_lock(self):
        context = self._register()

        def create(index):
            return self._call(context, "silverbullet_create", {
                "page": f"Concurrent/{index}", "content": "body", "change_summary": f"Saved note {index}",
            })
        with ThreadPoolExecutor(max_workers=6) as executor:
            results = list(executor.map(create, range(6)))
        self.assertTrue(all(result.get("journal", {}).get("verified") for result in results), results)
        journal = State.spaces["personal"][results[0]["journal"]["page"]]["content"]
        self.assertEqual(journal.count("<!-- inigo-journal:"), 6)
        for index in range(6):
            self.assertIn(f"Saved note {index}", journal)

    def test_partial_completion_recovery_survives_output_truncation(self):
        self.settings["max_result_chars"] = 1000
        State.fail_journal_put = True
        context = self._register()
        result = self._call(context, "silverbullet_create", {
            "page": "N" * 100, "content": "body", "change_summary": "x" * 240,
        })
        self.assertTrue(result.get("verified"), result)
        self.assertTrue(result["partial_completion"])
        self.assertFalse(result["journal"]["verified"])
        self.assertIn("operation_id", result["journal"]["retry"])
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False)), 1000)

    def test_unreturnable_recovery_payload_is_rejected_before_mutation(self):
        self.settings["max_result_chars"] = 1000
        result = self._call(self._register(), "silverbullet_create", {
            "page": "New", "content": "body", "change_summary": "[" * 240,
        })
        self.assertIn("recovery payload", result.get("error", ""))
        self.assertNotIn("New.md", State.spaces["personal"])
        self.assertEqual(State.journal_puts, 0)

    def test_missing_timezone_data_fails_before_note_mutation(self):
        from zoneinfo import ZoneInfoNotFoundError
        context = self._register()
        module = sys.modules["inigo_silverbullet"]
        with patch.object(module, "_journal_now", side_effect=ZoneInfoNotFoundError("missing tzdata")):
            result = self._call(context, "silverbullet_create", {
                "page": "New", "content": "body", "change_summary": "Saved facts",
            })
        self.assertIn("timezone", result.get("error", "").lower())
        self.assertNotIn("New.md", State.spaces["personal"])

    def test_create_requires_summary_before_mutating(self):
        context = self._register()
        for summary in (None, "", "two\nlines", "two\u2028lines", "two\u2029lines", "x" * 241, True):
            args: dict[str, object] = {"page": "New", "content": "body"}
            if summary is not None:
                args["change_summary"] = summary
            result = self._call(context, "silverbullet_create", args)
            self.assertIn("change_summary", result.get("error", ""))
            self.assertNotIn("New.md", State.spaces["personal"])


if __name__ == "__main__":
    unittest.main()
