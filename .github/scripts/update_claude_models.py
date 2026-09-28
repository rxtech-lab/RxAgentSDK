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


def fetch_models() -> list[dict]:
    # `list()` auto-paginates across every page.
    return [model.model_dump(mode="json") for model in anthropic.Anthropic().models.list()]


def latest_by_family(models: list[dict]) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    for model in models:
        match = re.fullmatch(r"claude-([a-z]+)-[0-9-]+", model["id"])
        if not match:
            continue
        family = match.group(1)
        if family not in latest or model["created_at"] > latest[family]["created_at"]:
            latest[family] = model
    return latest


def main() -> int:
    latest = latest_by_family(fetch_models())
    with open(SWIFT_FILE) as f:
        source = f.read()

    changes: list[str] = []

    def replace(match: re.Match) -> str:
        newest = latest.get(match["family"])
        if newest is None or newest["id"] == match["id"]:
            return match[0]
        wants_1m = bool(match["suffix"])
        has_1m = wants_1m and (newest.get("max_input_tokens") or 0) >= ONE_MILLION
        new_id = newest["id"] + ("[1m]" if has_1m else "")
        new_name = newest["display_name"].removeprefix("Claude ") + (" (1M)" if has_1m else "")
        changes.append(f"- `{match['id']}{match['suffix'] or ''}` → `{new_id}` ({new_name})")
        return f'AgentModelOption(id: "{new_id}", displayName: "{new_name}")'

    updated = ENTRY.sub(replace, source)
    if updated != source:
        with open(SWIFT_FILE, "w") as f:
            f.write(updated)
        print("\n".join(changes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
