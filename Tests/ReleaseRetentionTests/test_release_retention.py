import importlib.util
import base64
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script/release_retention.py"
spec = importlib.util.spec_from_file_location("release_retention", SCRIPT)
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)
STABLE = "v0.1.26"
OLD_STABLE = "v0.1.25"
ALPHA = "alpha-20261008000000-abcdef123456"
OLD_ALPHA = "alpha-20261007000000-abcdef123456"


class ReleaseRetentionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def feed(self, name, releases):
        path = self.root / name
        rss = ET.Element("rss")
        channel = ET.SubElement(rss, "channel")
        for tag, version in releases:
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, f"{{{retention.SPARKLE}}}version").text = str(version)
            if tag.startswith("alpha-"):
                ET.SubElement(item, f"{{{retention.SPARKLE}}}channel").text = "alpha"
            ET.SubElement(item, "enclosure", url=f"https://github.com/euforic/AgentDock/releases/download/{tag}/AgentDock.zip")
        ET.ElementTree(rss).write(path)
        return path

    def test_new_stable_removes_older_alpha_and_stable(self):
        path = self.feed("stable.xml", [(STABLE, 103), (ALPHA, 102), (OLD_STABLE, 101)])
        retention.prune(path)
        self.assertEqual([entry[3] for entry in retention.entries(path)[2]], [STABLE])

    def test_new_alpha_keeps_only_latest_alpha_and_stable(self):
        path = self.feed("alpha.xml", [(ALPHA, 104), (OLD_ALPHA, 103), (STABLE, 102), (OLD_STABLE, 101)])
        retention.prune(path)
        self.assertEqual({entry[3] for entry in retention.entries(path)[2]}, {STABLE, ALPHA})

    def test_superseded_downloads_are_deleted_but_tags_drafts_and_other_releases_are_not(self):
        stable = self.feed("stable.xml", [(STABLE, 103)])
        alpha = self.feed("alpha.xml", [(ALPHA, 104), (STABLE, 103)])
        releases = self.root / "releases.json"
        pages = [
            [{"id": 1, "tag_name": STABLE, "draft": False}, {"id": 2, "tag_name": ALPHA, "draft": False}],
            [{"id": 3, "tag_name": OLD_STABLE, "draft": False}, {"id": 4, "tag_name": OLD_ALPHA, "draft": False},
             {"id": 5, "tag_name": "v0.1.27", "draft": True}, {"id": 6, "tag_name": "preview", "draft": False}],
        ]
        for page in pages:
            for release in page:
                release["published_at"] = "2026-10-08T01:00:00Z" if release["tag_name"] == ALPHA else "2026-10-08T00:00:00Z"
        releases.write_text(json.dumps(pages))
        result = subprocess.run(["python3", str(SCRIPT), "obsolete", str(releases), str(stable), str(alpha)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "3\n4\n")

    def test_cleanup_fails_closed_for_missing_release_or_inconsistent_feeds(self):
        stable = self.feed("stable.xml", [(STABLE, 103)])
        alpha = self.feed("alpha.xml", [(STABLE, 103)])
        releases = self.root / "releases.json"
        releases.write_text("[[]]")
        with self.assertRaisesRegex(ValueError, "not published"):
            retention.obsolete(releases, stable, alpha)
        alpha = self.feed("alpha.xml", [(OLD_STABLE, 102)])
        with self.assertRaisesRegex(ValueError, "do not agree"):
            retention.obsolete(releases, stable, alpha)

    def test_cleanup_preserves_newer_uploads_whose_feed_publication_failed(self):
        stable = self.feed("stable.xml", [(STABLE, 103)])
        alpha = self.feed("alpha.xml", [(STABLE, 103)])
        releases = self.root / "releases.json"
        current = {"id": 1, "tag_name": STABLE, "draft": False, "published_at": "2026-10-08T00:00:00Z"}
        for tag, message in [("v0.1.27", "Latest Stable"), (ALPHA, "Latest Alpha")]:
            newer = {"id": 2, "tag_name": tag, "draft": False, "published_at": "2026-10-08T01:00:00Z"}
            releases.write_text(json.dumps([[current, newer]]))
            with self.assertRaisesRegex(ValueError, message):
                retention.obsolete(releases, stable, alpha)

    def test_pruning_removes_delta_downloads_and_accepts_legacy_build_attributes(self):
        path = self.feed("stable.xml", [(STABLE, 103)])
        tree = ET.parse(path)
        item = tree.find("channel/item")
        item.remove(item.find(f"{{{retention.SPARKLE}}}version"))
        item.find("enclosure").set(f"{{{retention.SPARKLE}}}version", "103")
        ET.SubElement(item, f"{{{retention.SPARKLE}}}deltas")
        tree.write(path)
        retention.prune(path)
        self.assertEqual(retention.entries(path)[2][0][1], 103)
        self.assertIsNone(ET.parse(path).find(f"channel/item/{{{retention.SPARKLE}}}deltas"))

    def test_invalid_metadata_is_rejected(self):
        for version in ["bad", "1.2"]:
            path = self.feed("bad.xml", [(STABLE, version)])
            with self.assertRaisesRegex(ValueError, "numeric"):
                retention.prune(path)
        path = self.feed("bad.xml", [(STABLE, 103)])
        tree = ET.parse(path)
        tree.find("channel/item/enclosure").set("url", "https://example.com/download.zip")
        tree.write(path)
        with self.assertRaisesRegex(ValueError, "Unexpected release"):
            retention.prune(path)
        with self.assertRaisesRegex(ValueError, "requires a Stable"):
            retention.prune(self.feed("alpha-only.xml", [(ALPHA, 104)]))

    def test_pruned_feed_can_be_resigned_and_verified_by_sparkle(self):
        signer = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        # Public RFC 8032 test vector; no production key or Keychain access.
        key = base64.b64encode(bytes.fromhex(
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
        )).decode()
        path = self.feed("signed.xml", [(STABLE, 103), (ALPHA, 102)])
        for verify in [False, True]:
            command = [str(signer), "--ed-key-file", "-", str(path)]
            if verify:
                retention.prune(path)
                result = subprocess.run(command, input=key, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                command.append("--verify")
            result = subprocess.run(command, input=key, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([entry[3] for entry in retention.entries(path)[2]], [STABLE])


if __name__ == "__main__":
    unittest.main()
