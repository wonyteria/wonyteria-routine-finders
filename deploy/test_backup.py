import base64
import contextlib
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("backup", Path(__file__).with_name("backup.py"))
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


def fixture_payload(payload):
    storage = payload / "storage"
    storage.mkdir()
    for name, table in zip(backup.DATABASES, backup.REQUIRED_TABLES):
        with contextlib.closing(sqlite3.connect(storage / name)) as db:
            db.execute('CREATE TABLE "' + table + '" (id INTEGER PRIMARY KEY)')
            db.execute('INSERT INTO "' + table + '" VALUES (1)')
            if name == "production.sqlite3":
                db.execute("CREATE TABLE active_storage_blobs (key TEXT, byte_size INTEGER, checksum TEXT, service_name TEXT)")
                data = b"real attachment fixture"
                key = "abcdefghijklmnop"
                path = storage / key[:2] / key[2:4] / key
                path.parent.mkdir(parents=True)
                path.write_bytes(data)
                checksum = base64.b64encode(hashlib.md5(data).digest()).decode()
                db.execute("INSERT INTO active_storage_blobs VALUES (?, ?, ?, ?)", (key, len(data), checksum, "local"))
            db.commit()
    return backup.database_report(storage, normalize=True)


class RetentionTests(unittest.TestCase):
    def test_union_keeps_hours_days_weeks_months(self):
        current = dt.datetime(2026, 9, 20, 14, tzinfo=backup.UTC)
        records = [(f"h{n}", current - dt.timedelta(hours=n)) for n in range(24)]
        records += [(f"d{n}", current - dt.timedelta(days=n)) for n in range(1, 8)]
        records += [(f"w{n}", current - dt.timedelta(weeks=n)) for n in range(1, 6)]
        records += [("august", current.replace(month=8)), ("july", current.replace(month=7)), ("june", current.replace(month=6))]
        kept = backup.retention_keep(records, current)
        self.assertTrue({f"h{n}" for n in range(24)} <= kept)
        self.assertIn("d6", kept)
        self.assertIn("w3", kept)
        self.assertNotIn("august", kept)  # w3 is the newer snapshot in August.
        self.assertIn("july", kept)
        self.assertNotIn("june", kept)
        self.assertNotIn("w5", kept)

    def test_keeps_newest_per_calendar_bucket(self):
        current = dt.datetime(2026, 9, 20, 14, tzinfo=backup.UTC)
        records = [("latest", current), ("older", current - dt.timedelta(days=2, hours=2)),
                   ("newer", current - dt.timedelta(days=2))]
        self.assertEqual(backup.retention_keep(records, current), {"latest", "newer"})

    def test_timezone_day_boundary(self):
        current = dt.datetime(2026, 9, 23, tzinfo=backup.UTC)
        records = [("before", dt.datetime(2026, 9, 20, 14, 59, tzinfo=backup.UTC)),
                   ("after", dt.datetime(2026, 9, 20, 15, 1, tzinfo=backup.UTC))]
        self.assertEqual(backup.retention_keep(records, current), {"before", "after"})

    def test_future_timestamp_blocks_pruning(self):
        current = backup.now()
        with self.assertRaises(ValueError):
            backup.retention_keep([("future", current + dt.timedelta(hours=1))], current)


class ArchiveTests(unittest.TestCase):
    def test_rejects_traversal_links_devices_and_duplicate_files(self):
        for name, kind, duplicate in [("../escape", tarfile.REGTYPE, False),
                                      ("/absolute", tarfile.REGTYPE, False),
                                      ("link", tarfile.SYMTYPE, False),
                                      ("hardlink", tarfile.LNKTYPE, False),
                                      ("device", tarfile.CHRTYPE, False),
                                      ("same", tarfile.REGTYPE, True)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as root:
                archive = Path(root) / "bad.tar.gz"
                with tarfile.open(archive, "w:gz") as tar:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "target"
                    tar.addfile(member)
                    if duplicate:
                        tar.addfile(member)
                destination = Path(root) / "out"
                destination.mkdir()
                with self.assertRaises(ValueError):
                    backup.unpack(archive, destination)

    def test_detects_missing_and_corrupt_attachments(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            report = fixture_payload(root)
            self.assertEqual(report["verified_attachments"], 1)
            path = root / "storage/ab/cd/abcdefghijklmnop"
            original = path.read_bytes()
            path.write_bytes(b"x" * len(original))
            with self.assertRaisesRegex(ValueError, "checksum"):
                backup.database_report(root / "storage")
            path.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                backup.database_report(root / "storage")

    def test_rejects_missing_tables_and_corrupt_database(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            fixture_payload(root)
            db_path = root / "storage/production_cache.sqlite3"
            with contextlib.closing(sqlite3.connect(db_path)) as db:
                db.execute("DROP TABLE solid_cache_entries")
                db.commit()
            with self.assertRaisesRegex(ValueError, "table missing"):
                backup.database_report(root / "storage")
            db_path.write_bytes(b"not a database")
            with self.assertRaises(sqlite3.DatabaseError):
                backup.database_report(root / "storage")


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.service = Path(self.temporary.name)
        self.manager = backup.Backups(self.service)
        self.capture = patch.object(self.manager, "capture", side_effect=fixture_payload)
        self.capture.start()
        self.notice = patch.object(backup, "notify_failure")
        self.notice.start()
        self.addCleanup(self.notice.stop)

    def tearDown(self):
        self.capture.stop()
        self.temporary.cleanup()

    def test_backup_restore_roundtrip_and_private_permissions(self):
        state = self.manager.backup()
        snapshot = self.manager.root / state["last_verified_snapshot"]
        with tempfile.TemporaryDirectory() as restored:
            manifest = self.manager.verify(snapshot, Path(restored))
            self.assertEqual(manifest["database_report"]["tables"]["production.sqlite3"]["users"], 1)
            self.assertEqual((Path(restored) / "storage/ab/cd/abcdefghijklmnop").read_bytes(), b"real attachment fixture")
        self.assertEqual((snapshot / "snapshot.tar.gz").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.manager.root.stat().st_mode & 0o777, 0o700)

    def test_failure_never_prunes_existing_backups(self):
        first = self.manager.backup()
        before = {p.name for p in self.manager.snapshots()}
        with patch.object(self.manager, "capture", side_effect=RuntimeError("disk failure")), patch.object(self.manager, "prune") as prune:
            with self.assertRaises(RuntimeError):
                self.manager.backup()
            prune.assert_not_called()
        self.assertEqual(before, {p.name for p in self.manager.snapshots()})
        state = backup.read_json(self.manager.root / "status.json")
        self.assertEqual(state["state"], "failed")
        self.assertEqual(state["last_success_at"], first["last_success_at"])

    def test_restore_verification_failure_never_publishes_or_prunes(self):
        self.manager.backup()
        before = {p.name for p in self.manager.snapshots()}
        with patch.object(backup, "unpack", side_effect=ValueError("bad archive")), patch.object(self.manager, "prune") as prune:
            with self.assertRaises(ValueError):
                self.manager.backup()
            prune.assert_not_called()
        self.assertEqual(before, {p.name for p in self.manager.snapshots()})

    def test_pruning_only_owned_snapshots_preserves_migration_files(self):
        migration = self.service / "backups/final-migration.tar.gz"
        migration.parent.mkdir(parents=True)
        migration.write_bytes(b"preserve original")
        old = dt.datetime(2025, 1, 1, tzinfo=backup.UTC)
        with patch.object(backup, "now", return_value=old):
            first = self.manager.backup()
        for month in range(1, 10):
            with patch.object(backup, "now", return_value=dt.datetime(2026, month, 20, tzinfo=backup.UTC)):
                self.manager.backup()
        self.assertFalse((self.manager.root / first["last_verified_snapshot"]).exists())
        self.assertEqual(migration.read_bytes(), b"preserve original")

    def test_unknown_contents_prevent_pruning(self):
        first = self.manager.backup()
        snapshot = self.manager.root / first["last_verified_snapshot"]
        (snapshot / "user-notes.txt").write_text("preserve")
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            self.manager.backup()
        self.assertTrue((snapshot / "snapshot.tar.gz").exists())
        self.assertEqual((snapshot / "user-notes.txt").read_text(), "preserve")

    def test_foreign_snapshot_owner_and_corrupted_archive_rejected(self):
        state = self.manager.backup()
        snapshot = self.manager.root / state["last_verified_snapshot"]
        manifest_path = snapshot / "manifest.json"
        original = backup.read_json(manifest_path)
        foreign = {**original, "repository_id": "foreign"}
        backup.atomic_json(manifest_path, foreign)
        with self.assertRaisesRegex(ValueError, "ownership"):
            self.manager.manifest(snapshot)
        backup.atomic_json(manifest_path, original)
        (snapshot / "snapshot.tar.gz").write_bytes(b"corrupt")
        with tempfile.TemporaryDirectory() as restored:
            with self.assertRaisesRegex(ValueError, "checksum"):
                self.manager.verify(snapshot, Path(restored))

    def test_symlink_and_nonempty_repository_rejected(self):
        self.manager.root.mkdir(parents=True)
        (self.manager.root / "unknown.txt").write_text("preserve")
        with self.assertRaisesRegex(ValueError, "unmanaged"):
            with self.manager.locked():
                self.fail("adopted unmanaged directory")
        (self.manager.root / "unknown.txt").unlink()
        self.manager.root.rmdir()
        other = self.service / "other"
        other.mkdir()
        self.manager.root.symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            with self.manager.locked():
                self.fail("followed symlink")

    def test_concurrent_invocation_is_rejected(self):
        with self.manager.locked():
            with self.assertRaisesRegex(RuntimeError, "already running"):
                with self.manager.locked():
                    self.fail("double locked")

    def test_low_space_never_captures_or_prunes(self):
        with patch.object(backup.shutil, "disk_usage") as space, patch.object(self.manager, "prune") as prune:
            space.return_value.free = 1
            with self.assertRaisesRegex(RuntimeError, "1 GiB"):
                self.manager.backup()
            self.manager.capture.assert_not_called()
            prune.assert_not_called()

    def test_restore_cli_refuses_existing_destination(self):
        state = self.manager.backup()
        destination = self.service / "existing-live-data"
        destination.mkdir()
        (destination / "keep.txt").write_text("do not overwrite")
        argv = ["backup.py", "--service-directory", str(self.service), "restore",
                state["last_verified_snapshot"], "--to", str(destination)]
        with patch("sys.argv", argv), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(backup.main(), 1)
        self.assertEqual((destination / "keep.txt").read_text(), "do not overwrite")
        self.assertEqual(len(list(destination.iterdir())), 1)

    def test_restore_cli_exports_verified_data_to_new_directory(self):
        state = self.manager.backup()
        destination = self.service / "restored-copy"
        argv = ["backup.py", "--service-directory", str(self.service), "restore",
                state["last_verified_snapshot"], "--to", str(destination)]
        with patch("sys.argv", argv), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(backup.main(), 0)
        report = backup.database_report(destination / "storage")
        self.assertEqual(report["verified_attachments"], 1)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o700)

    def test_status_reports_overdue_backup(self):
        state = self.manager.backup()
        later = dt.datetime.fromisoformat(state["last_success_at"]) + dt.timedelta(hours=3)
        output = io.StringIO()
        argv = ["backup.py", "--service-directory", str(self.service), "status"]
        with patch("sys.argv", argv), patch.object(backup, "now", return_value=later), contextlib.redirect_stdout(output):
            self.assertEqual(backup.main(), 1)
        self.assertTrue(json.loads(output.getvalue())["overdue"])

    def test_repeated_failure_does_not_repeat_notifications(self):
        with patch.object(self.manager, "capture", side_effect=RuntimeError("unavailable")), patch.object(backup, "notify_failure") as notice:
            for _ in range(2):
                with self.assertRaises(RuntimeError):
                    self.manager.backup()
            notice.assert_called_once()


if __name__ == "__main__":
    unittest.main()
