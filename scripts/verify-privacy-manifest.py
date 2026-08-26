#!/usr/bin/env python3
"""Fail closed when Toj's privacy inventory, manifest, or built bundle drifts."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Toj" / "PrivacyInfo.xcprivacy"
INVENTORY = ROOT / "PRIVACY_DATA_MAP.md"
PURPOSE = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
LOCATION_TYPES = {
    "NSPrivacyCollectedDataTypePreciseLocation",
    "NSPrivacyCollectedDataTypeCoarseLocation",
}
LOCALIZATION_CATALOG = ROOT / "Toj" / "Localizable.xcstrings"


def inventory_entries() -> dict[str, bool]:
    entries: dict[str, bool] = {}
    for line_number, line in enumerate(INVENTORY.read_text().splitlines(), 1):
        match = re.match(r"^\| (NSPrivacyCollectedDataType\w+) \| (true|false) \|", line)
        if not match:
            continue
        identifier, linked = match.groups()
        if identifier in entries:
            raise SystemExit(f"{INVENTORY}:{line_number}: duplicate {identifier}")
        entries[identifier] = linked == "true"
    if not entries:
        raise SystemExit(f"{INVENTORY}: no machine-readable inventory rows")
    return entries


def manifest_entries(path: Path) -> dict[str, bool]:
    with path.open("rb") as source:
        manifest = plistlib.load(source)
    if manifest.get("NSPrivacyTracking") is not False:
        raise SystemExit(f"{path}: NSPrivacyTracking must be false")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        raise SystemExit(f"{path}: tracking domains must be empty")

    entries: dict[str, bool] = {}
    for item in manifest.get("NSPrivacyCollectedDataTypes", []):
        identifier = item.get("NSPrivacyCollectedDataType")
        if not isinstance(identifier, str):
            raise SystemExit(f"{path}: collected-data entry has no identifier")
        if identifier in entries:
            raise SystemExit(f"{path}: duplicate {identifier}")
        if item.get("NSPrivacyCollectedDataTypeTracking") is not False:
            raise SystemExit(f"{path}: {identifier} must not be marked as tracking")
        if item.get("NSPrivacyCollectedDataTypePurposes") != [PURPOSE]:
            raise SystemExit(f"{path}: {identifier} must use only App Functionality")
        linked = item.get("NSPrivacyCollectedDataTypeLinked")
        if not isinstance(linked, bool):
            raise SystemExit(f"{path}: {identifier} must declare linkage")
        entries[identifier] = linked
    return entries


def parsed_manifest(path: Path) -> dict[str, object]:
    with path.open("rb") as source:
        value = plistlib.load(source)
    if not isinstance(value, dict):
        raise SystemExit(f"{path}: privacy manifest root must be a dictionary")
    return value


def source_uses_location() -> list[str]:
    patterns = (
        re.compile(r"\bimport\s+CoreLocation\b"),
        re.compile(r"\bCLLocation(?:Manager|Coordinate2D)?\b"),
        re.compile(r"NSLocation(?:WhenInUse|Always)UsageDescription"),
    )
    hits: list[str] = []
    for relative in ("Toj", "Toj-Info.plist", "server/src"):
        target = ROOT / relative
        files = [target] if target.is_file() else target.rglob("*")
        for path in files:
            if not path.is_file() or path.suffix not in {".swift", ".ts", ".plist"}:
                continue
            text = path.read_text(errors="ignore")
            if any(pattern.search(text) for pattern in patterns):
                hits.append(str(path.relative_to(ROOT)))
    return hits


def verify_cloud_chat_claims() -> None:
    forbidden = {
        "Private conversation": "cloud chats are not end-to-end encrypted",
        "Connection: Protected": "connection state is not a message-privacy guarantee",
    }
    swift_sources = list((ROOT / "Toj" / "Features" / "Cloud").rglob("*.swift"))
    for claim, reason in forbidden.items():
        hits = [str(path.relative_to(ROOT)) for path in swift_sources if claim in path.read_text()]
        if hits:
            raise SystemExit(f"misleading cloud-chat claim {claim!r} ({reason}): {', '.join(hits)}")

    for relative in (
        "Toj/Features/Cloud/ConversationExperience.swift",
        "Toj/Features/Cloud/RichDemoSurfaces.swift",
        "Toj/Features/Cloud/GroupCreationView.swift",
    ):
        if 'systemImage: "lock.fill"' in (ROOT / relative).read_text():
            raise SystemExit(f"{relative}: cloud-message surfaces must not use a lock security claim")

    presentation = (ROOT / "Toj" / "Features" / "Cloud" / "MessagingPresentation.swift").read_text()
    required = ("cloud.fill", "not end-to-end encrypted", "Cloud encrypted")
    missing = [value for value in required if value not in presentation]
    if missing:
        raise SystemExit("truthful cloud-chat presentation is incomplete: " + ", ".join(missing))


def verify_safety_localizations() -> None:
    catalog = json.loads(LOCALIZATION_CATALOG.read_text())
    required = (
        "Cloud chat",
        "Cloud encrypted",
        "Cloud chats sync across your devices",
        "Connected",
        "Live sync",
        "Message privacy",
        "Cloud chat. Messages are not end-to-end encrypted.",
        "Saved Messages. Cloud chat. Messages are not end-to-end encrypted.",
        "Messages use encrypted connections and are stored encrypted on Toj’s servers. They are not end-to-end encrypted, so Toj can access them to deliver and sync messages and review safety reports.",
        "A safety reviewer can now examine the encrypted evidence snapshot.",
        "Add at least 10 characters of detail for Other.",
        "Additional details",
        "Block",
        "Report",
        "Block or report",
        "Block or report this contact?",
        "Block this contact?",
        "Block this account after submitting the report?",
        "Reason",
        "Report received",
        "Block account",
        "Blocking account…",
        "Blocking is a separate action. Your submitted report will remain received even if blocking fails.",
        "Blocking is confirmed separately and does not change the submitted report.",
        "Blocking prevents new messages and voice calls in both directions.",
        "Spam",
        "Scam or fraud",
        "Harassment",
        "Violence or threats",
        "Sexual content",
        "Child safety",
        "Other",
        "Details must be 500 characters or fewer.",
        "Reporting is not available on this server yet.",
        "Sending report…",
        "The account could not be verified.",
        "The server returned an invalid report acknowledgement.",
        "The report was submitted, but the account could not be blocked.",
        "This message can no longer be reported.",
        "Toj will securely include a bounded snapshot of recent conversation context. Full media files are never attached to a report.",
        "Your report was submitted",
    )
    for key in required:
        entry = catalog.get("strings", {}).get(key)
        if not entry:
            raise SystemExit(f"{LOCALIZATION_CATALOG}: missing safety localization key {key!r}")
        for locale in ("ru", "tg"):
            unit = entry.get("localizations", {}).get(locale, {}).get("stringUnit", {})
            if unit.get("state") != "translated" or not str(unit.get("value", "")).strip():
                raise SystemExit(
                    f"{LOCALIZATION_CATALOG}: {key!r} has no complete {locale} translation"
                )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-bundle", type=Path)
    args = parser.parse_args()

    expected = inventory_entries()
    actual = manifest_entries(MANIFEST)
    if actual != expected:
        raise SystemExit(f"privacy manifest does not match inventory: expected {expected!r}, got {actual!r}")

    location_hits = source_uses_location()
    location_declared = bool(LOCATION_TYPES.intersection(actual))
    if location_hits and not location_declared:
        raise SystemExit(
            "location APIs were added without privacy declarations: " + ", ".join(location_hits)
        )
    if not location_hits and location_declared:
        raise SystemExit("location is declared but no current location collection path exists")

    verify_cloud_chat_claims()
    verify_safety_localizations()

    if args.app_bundle:
        bundled = args.app_bundle / "PrivacyInfo.xcprivacy"
        if not bundled.is_file():
            raise SystemExit(f"built app is missing {bundled.name}: {args.app_bundle}")
        if manifest_entries(bundled) != expected:
            raise SystemExit(f"{bundled}: bundled privacy manifest differs from the inventory")
        if parsed_manifest(bundled) != parsed_manifest(MANIFEST):
            raise SystemExit(f"{bundled}: bundled privacy manifest differs from the source manifest")

    print(f"privacy manifest verified: {len(actual)} collected-data categories")


if __name__ == "__main__":
    main()
