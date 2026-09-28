#!/usr/bin/env python3
"""Bump pinned Claude model IDs in ClaudeCodeClient.swift to the newest release.

Only entries pinned to a full ID (`claude-<family>-...`) are touched; bare
aliases such as `fable` or `sonnet` already track the latest model in the CLI.
A `[1m]` suffix is kept when the new model still has a 1M-token context.

Prints a Markdown summary of the changes to stdout (empty when up to date).

Authenticates with ANTHROPIC_API_KEY (or `ant auth login` locally).
"""

import re
import sys

import anthropic

SWIFT_FILE = "Sources/RxAgentClients/ClaudeCodeClient.swift"
ONE_MILLION = 1_000_000

# AgentModelOption(id: "claude-opus-5-5[1m]", displayName: "Opus 5.5 (1M)")
ENTRY = re.compile(
    r'AgentModelOption\(id: "(?P<id>claude-(?P<family>[a-z]+)-[0-9a-z-]+?)(?P<suffix>\[1m\])?", '
    r'displayName: "(?P<name>[^"]*)"\)'
)


def log(message: str) -> None:
    # stdout is captured as the PR body, so logs go to stderr.
    print(message, file=sys.stderr)


def fetch_models() -> list[dict]:
    # `list()` auto-paginates across every page.
    models = [model.model_dump(mode="json") for model in anthropic.Anthropic().models.list()]
    log(f"Fetched {len(models)} models from the Models API")
    return models


def latest_by_family(models: list[dict]) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    for model in models:
        match = re.fullmatch(r"claude-([a-z]+)-[0-9-]+", model["id"])
        if not match:
            continue
        family = match.group(1)
        if family not in latest or model["created_at"] > latest[family]["created_at"]:
            latest[family] = model
    for family, model in sorted(latest.items()):
        log(f"Latest {family}: {model['id']} ({model['display_name']}, released {model['created_at']})")
    return latest


def main() -> int:
    latest = latest_by_family(fetch_models())
    with open(SWIFT_FILE) as f:
        source = f.read()

    changes: list[str] = []

    def replace(match: re.Match) -> str:
        current = match["id"] + (match["suffix"] or "")
        newest = latest.get(match["family"])
        if newest is None:
            log(f"{current}: no {match['family']} models on the Models API, skipping")
            return match[0]
        if newest["id"] == match["id"]:
            log(f"{current}: up to date")
            return match[0]
        wants_1m = bool(match["suffix"])
        has_1m = wants_1m and (newest.get("max_input_tokens") or 0) >= ONE_MILLION
        new_id = newest["id"] + ("[1m]" if has_1m else "")
        new_name = newest["display_name"].removeprefix("Claude ") + (" (1M)" if has_1m else "")
        if wants_1m and not has_1m:
            log(f"{current}: {newest['id']} has no 1M context, dropping the [1m] suffix")
        log(f"{current}: updating to {new_id} ({new_name})")
        changes.append(f"- `{current}` → `{new_id}` ({new_name})")
        return f'AgentModelOption(id: "{new_id}", displayName: "{new_name}")'

    updated, pinned = ENTRY.subn(replace, source)
    log(f"Found {pinned} pinned model ID(s) in {SWIFT_FILE}")
    if updated != source:
        with open(SWIFT_FILE, "w") as f:
            f.write(updated)
        log(f"Updated {len(changes)} model ID(s)")
        print("\n".join(changes))
    else:
        log("All pinned model IDs are up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
