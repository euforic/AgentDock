#!/usr/bin/env python3
"""Keep the latest Stable and, only when newer, the latest Alpha download."""

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
from urllib.parse import urlparse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
STABLE_TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+")
ALPHA_TAG = re.compile(r"alpha-[0-9]{14}-[0-9a-f]{7,40}")


def entries(path):
    tree = ET.parse(path)
    channel = tree.find("channel")
    if channel is None:
        raise ValueError("Appcast has no channel")
    result = []
    for item in channel.findall("item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            raise ValueError("Appcast item has no enclosure")
        version = item.findtext(f"{{{SPARKLE}}}version") or enclosure.get(f"{{{SPARKLE}}}version", "")
        if not re.fullmatch(r"[0-9]+", version):
            raise ValueError("Appcast build number must be numeric")
        release_channel = item.findtext(f"{{{SPARKLE}}}channel", "stable")
        url = urlparse(enclosure.get("url", ""))
        parts = url.path.split("/")
        if (url.scheme != "https" or url.netloc != "github.com" or url.query or url.fragment
                or len(parts) != 7 or parts[1:5] != ["euforic", "AgentDock", "releases", "download"]
                or not parts[6].endswith(".zip")):
            raise ValueError("Unexpected release download URL")
        tag = parts[5]
        pattern = {"stable": STABLE_TAG, "alpha": ALPHA_TAG}.get(release_channel)
        if pattern is None or not pattern.fullmatch(tag):
            raise ValueError("Release tag does not match its channel")
        result.append((item, int(version), release_channel, tag))
    if not result:
        raise ValueError("Appcast has no releases")
    return tree, channel, result


def retained(entries):
    stable = max((entry for entry in entries if entry[2] == "stable"), key=lambda e: e[1], default=None)
    alpha = max((entry for entry in entries if entry[2] == "alpha"), key=lambda e: e[1], default=None)
    if stable is None:
        raise ValueError("Retention requires a Stable release")
    return [stable] + ([alpha] if alpha and alpha[1] > stable[1] else [])


def prune(path):
    tree, channel, items = entries(path)
    keep = {entry[0] for entry in retained(items)}
    for item, _, _, _ in items:
        if item not in keep:
            channel.remove(item)
        else:
            for deltas in item.findall(f"{{{SPARKLE}}}deltas"):
                item.remove(deltas)
    # The caller must re-sign the modified feed before publication.
    tree.write(path, encoding="utf-8", xml_declaration=True)


def obsolete(releases_path, stable_path, alpha_path):
    stable_items = entries(stable_path)[2]
    alpha_items = entries(alpha_path)[2]
    if len(stable_items) != 1 or stable_items[0][2] != "stable":
        raise ValueError("Stable feed must contain exactly one Stable release")
    keep = retained(alpha_items)
    if len(keep) != len(alpha_items) or keep[0][3] != stable_items[0][3]:
        raise ValueError("Feeds do not agree on release retention")
    keep_tags = {entry[3] for entry in keep}
    pages = json.loads(Path(releases_path).read_text())
    releases = [release for page in pages for release in page]
    published_tags = {r["tag_name"] for r in releases if not r["draft"]}
    if not keep_tags <= published_tags:
        raise ValueError("A retained release is not published; refusing cleanup")
    stable_releases = [r for r in releases if not r["draft"] and STABLE_TAG.fullmatch(r["tag_name"])]
    latest_stable = max(stable_releases, key=lambda r: tuple(map(int, r["tag_name"][1:].split("."))))
    if latest_stable["tag_name"] != keep[0][3]:
        raise ValueError("Latest Stable release is absent from the feeds; refusing cleanup")
    alpha_releases = [r for r in releases if not r["draft"] and ALPHA_TAG.fullmatch(r["tag_name"])]
    published_at = lambda r: datetime.fromisoformat(r["published_at"].replace("Z", "+00:00"))
    latest_alpha = max(alpha_releases, key=published_at, default=None)
    expected_alpha = latest_alpha if latest_alpha and published_at(latest_alpha) > published_at(latest_stable) else None
    feed_alpha = next((entry[3] for entry in keep if entry[2] == "alpha"), None)
    if feed_alpha != (expected_alpha["tag_name"] if expected_alpha else None):
        raise ValueError("Latest Alpha release disagrees with the feeds; refusing cleanup")
    for release in releases:
        tag = release["tag_name"]
        if not release["draft"] and (STABLE_TAG.fullmatch(tag) or ALPHA_TAG.fullmatch(tag)) and tag not in keep_tags:
            print(int(release["id"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("prune").add_argument("appcast")
    cleanup = commands.add_parser("obsolete")
    cleanup.add_argument("releases")
    cleanup.add_argument("stable")
    cleanup.add_argument("alpha")
    args = parser.parse_args()
    try:
        if args.command == "prune":
            prune(args.appcast)
        else:
            obsolete(args.releases, args.stable, args.alpha)
    except (ValueError, KeyError, ET.ParseError) as error:
        parser.exit(1, f"Release retention failed: {error}\n")


if __name__ == "__main__":
    main()
