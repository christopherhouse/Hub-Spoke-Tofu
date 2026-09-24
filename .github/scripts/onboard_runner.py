#!/usr/bin/env python3
"""Insert a self-hosted runner entry into infra/main.bicepparam.

Run by .github/workflows/onboard-runner.yml. The entry goes between the `// BEGIN runners`
and `// END runners` markers in the `githubRunners` parameter, which is why those markers
must not be removed from the parameter file.

Writing the entry here rather than in shell keeps the quoting honest: a repository name is
interpolated into Bicep source, and a stray quote would otherwise produce a file that still
looks plausible but no longer builds.
"""

from __future__ import annotations

import os
import pathlib
import re
import sys

PARAM_FILE = pathlib.Path("infra/main.bicepparam")
BEGIN_MARKER = "// BEGIN runners"
END_MARKER = "// END runners"

# GitHub's own rules. Enforced here so an invalid value fails with a clear message rather
# than as a deployment error much later.
OWNER_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
LABEL_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def fail(message: str) -> None:
    print(f"::error::{message}")
    sys.exit(1)


def emit_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as handle:
        handle.write(f"{name}={value}\n")


def main() -> None:
    repository = os.environ.get("REPOSITORY", "").strip()
    if repository.count("/") != 1:
        fail(f"Expected a repository as owner/name, got {repository!r}.")

    owner, name = (part.strip() for part in repository.split("/"))
    if not OWNER_PATTERN.match(owner):
        fail(f"{owner!r} is not a valid GitHub account name.")
    if not REPOSITORY_PATTERN.match(name):
        fail(f"{name!r} is not a valid GitHub repository name.")

    labels = [label.strip() for label in os.environ.get("LABELS", "").split(",")]
    labels = [label for label in labels if label]
    for label in labels:
        if not LABEL_PATTERN.match(label):
            fail(f"{label!r} is not a valid runner label.")

    max_executions = os.environ.get("MAX_EXECUTIONS", "5").strip() or "5"
    if not max_executions.isdigit() or not 1 <= int(max_executions) <= 100:
        fail(f"max_executions must be a whole number from 1 to 100, got {max_executions!r}.")

    source = PARAM_FILE.read_text(encoding="utf-8")

    if BEGIN_MARKER not in source or END_MARKER not in source:
        fail(f"{PARAM_FILE} is missing the {BEGIN_MARKER!r} / {END_MARKER!r} markers.")

    # Idempotent. Re-running for a repository that is already listed is a no-op rather than a
    # second job definition with a colliding name.
    if re.search(
        rf"repositoryOwner:\s*'{re.escape(owner)}'\s*\n\s*repositoryName:\s*'{re.escape(name)}'",
        source,
    ):
        print(f"{repository} is already onboarded; nothing to do.")
        emit_output("changed", "false")
        return

    # The first line is unindented: it is substituted in place of the END marker, whose own
    # two leading spaces supply the indentation.
    lines = [
        "{",
        f"    repositoryOwner: '{owner}'",
        f"    repositoryName: '{name}'",
    ]
    if labels:
        lines.append("    labels: [")
        lines.extend(f"      '{label}'" for label in labels)
        lines.append("    ]")
    if max_executions != "5":
        lines.append(f"    maxExecutions: {max_executions}")
    lines.append("  }")

    entry = "\n".join(lines)
    updated = source.replace(END_MARKER, f"{entry}\n  {END_MARKER}", 1)

    PARAM_FILE.write_text(updated, encoding="utf-8")

    print(f"Added {repository} to {PARAM_FILE}.")
    emit_output("changed", "true")
    emit_output("branch", f"feat/onboard-runner-{owner}-{name}".lower())


if __name__ == "__main__":
    main()
