#!/usr/bin/env python3
"""
filter-stream.py — Data-block-aware git fast-export stream filter.

Processes a git fast-export stream on stdin and writes filtered output to stdout.
Two responsibilities:
  1. Rewrite author/committer emails using a mailmap file.
     Fails loudly if an unmapped internal email is encountered.
  2. Strip empty commits (commits with no file operations).

The fast-export format uses 'data <N>' directives followed by N raw bytes.
This filter is aware of that structure — it only rewrites author/committer lines
and passes data blocks through untouched.
"""

import sys
import re
import argparse
from pathlib import Path


def load_mailmap(mailmap_path: str) -> dict[str, tuple[str, str]]:
    """Load a mailmap file and return a dict mapping internal emails to (name, safe_email).

    Mailmap format (one per line):
        Canonical Name <safe-email> <internal-email>

    Returns:
        { "internal@example.com": ("Canonical Name", "safe@example.com"), ... }
    """
    mapping = {}
    mailmap = Path(mailmap_path)
    if not mailmap.exists():
        print(f"ERROR: Mailmap file not found: {mailmap_path}", file=sys.stderr)
        sys.exit(1)

    for line_num, line in enumerate(mailmap.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        # Parse: Name <safe-email> <internal-email>
        match = re.match(r"^(.+?)\s+<([^>]+)>\s+<([^>]+)>$", line)
        if not match:
            print(f"WARNING: Skipping malformed mailmap line {line_num}: {line}", file=sys.stderr)
            continue

        name, safe_email, internal_email = match.groups()
        mapping[internal_email.lower()] = (name.strip(), safe_email.strip())

    return mapping


# Domains considered internal — any author/committer email matching these
# must be in the mailmap or the filter aborts.
INTERNAL_DOMAINS = {"microsoft.com"}


def is_internal_email(email: str) -> bool:
    """Check if an email belongs to an internal domain."""
    parts = email.lower().rsplit("@", 1)
    return len(parts) == 2 and parts[1] in INTERNAL_DOMAINS


def rewrite_identity_line(line: str, mailmap: dict[str, tuple[str, str]], line_type: str) -> str:
    """Rewrite an author or committer line if the email is in the mailmap.

    Line format: 'author Name <email> timestamp timezone'
    or:          'committer Name <email> timestamp timezone'

    Returns the rewritten line, or exits with error if internal email is unmapped.
    """
    # Match: type Name <email> timestamp timezone
    pattern = rf"^({line_type}) (.+?) <([^>]+)> (.+)$"
    m = re.match(pattern, line)
    if not m:
        return line  # Malformed — pass through unchanged

    prefix, name, email, timestamp_tz = m.groups()
    email_lower = email.lower()

    if email_lower in mailmap:
        mapped_name, mapped_email = mailmap[email_lower]
        return f"{prefix} {mapped_name} <{mapped_email}> {timestamp_tz}"
    elif is_internal_email(email):
        print(
            f"ERROR: Unmapped internal email found in {line_type} line: {name} <{email}>",
            file=sys.stderr,
        )
        print("Add this email to the sync-mailmap file before syncing.", file=sys.stderr)
        sys.exit(1)
    else:
        return line  # External email, no rewrite needed


def read_data_block(stream) -> bytes:
    """Read a 'data <N>' block from the stream and return 'data <N>\\n' + N bytes.

    The 'data <N>' line has already been read; this reads the N content bytes.
    """
    # The line has already been consumed by the caller; we just need the byte count.
    # Actually, this function receives the full line and stream.
    raise NotImplementedError("Use read_data_block_from_line instead")


def rewrite_ref_line(line: str, command: str, source_ref: str, target_ref: str) -> str:
    """Rewrite the ref on a 'commit <ref>' or 'reset <ref>' line.

    Only rewrites if the ref exactly matches source_ref. Returns the line unchanged
    otherwise. This is data-block-aware because it only operates on parsed command
    lines, never inside a 'data N' block.
    """
    expected = f"{command} {source_ref}"
    if line == expected:
        return f"{command} {target_ref}"
    return line


def filter_stream(
    input_stream,
    output_stream,
    mailmap: dict[str, tuple[str, str]],
    source_ref: str | None = None,
    target_ref: str | None = None,
) -> None:
    """Process a fast-export stream, rewriting emails and stripping empty commits.

    Reads from input_stream (binary mode), writes to output_stream (binary mode).

    If source_ref and target_ref are provided, also rewrites 'commit <source_ref>'
    and 'reset <source_ref>' lines to point to target_ref. This is safer than a
    post-filter sed pass because it only touches command lines, not data blocks.
    """
    do_ref_rewrite = source_ref is not None and target_ref is not None
    # We need byte-level control for data blocks, so work in binary mode.
    # But most lines are text. Strategy: read line by line in binary, decode
    # text lines as UTF-8, and handle data blocks as raw bytes.

    # Commit accumulator: we buffer each commit and only emit it if it has
    # file operations (M/D/R/C lines).
    in_commit = False
    commit_buffer = []
    has_file_ops = False

    def flush_commit():
        """Write buffered commit to output if it has file operations."""
        nonlocal in_commit, commit_buffer, has_file_ops
        if in_commit and has_file_ops:
            for chunk in commit_buffer:
                output_stream.write(chunk)
        # If no file ops, the commit is silently dropped (empty commit stripping).
        in_commit = False
        commit_buffer = []
        has_file_ops = False

    while True:
        raw_line = input_stream.readline()
        if not raw_line:
            # End of stream — flush any pending commit
            flush_commit()
            break

        # Try to decode as UTF-8 text for line parsing
        try:
            line = raw_line.decode("utf-8")
        except UnicodeDecodeError:
            # Binary data outside a data block — shouldn't happen, but pass through
            if in_commit:
                commit_buffer.append(raw_line)
            else:
                output_stream.write(raw_line)
            continue

        stripped = line.rstrip("\n")

        # Detect start of a new commit
        if stripped.startswith("commit "):
            # Flush previous commit (if any)
            flush_commit()
            in_commit = True
            if do_ref_rewrite:
                rewritten = rewrite_ref_line(stripped, "commit", source_ref, target_ref)
                commit_buffer.append((rewritten + "\n").encode("utf-8"))
            else:
                commit_buffer.append(raw_line)
            continue

        # Handle data blocks — read exactly N bytes and pass through
        data_match = re.match(r"^data (\d+)$", stripped)
        if data_match:
            byte_count = int(data_match.group(1))
            if in_commit:
                commit_buffer.append(raw_line)
                # Read exactly byte_count bytes
                data = input_stream.read(byte_count)
                commit_buffer.append(data)
            else:
                output_stream.write(raw_line)
                data = input_stream.read(byte_count)
                output_stream.write(data)
            continue

        # Rewrite author/committer lines
        if stripped.startswith("author "):
            rewritten = rewrite_identity_line(stripped, mailmap, "author")
            encoded = (rewritten + "\n").encode("utf-8")
            if in_commit:
                commit_buffer.append(encoded)
            else:
                output_stream.write(encoded)
            continue

        if stripped.startswith("committer "):
            rewritten = rewrite_identity_line(stripped, mailmap, "committer")
            encoded = (rewritten + "\n").encode("utf-8")
            if in_commit:
                commit_buffer.append(encoded)
            else:
                output_stream.write(encoded)
            continue

        # Track file operations for empty-commit detection
        if in_commit and re.match(r"^[MDRC] ", stripped):
            has_file_ops = True

        # Handle 'reset', 'blob', 'tag', etc. — not inside a commit
        if stripped.startswith(("reset ", "blob", "tag ", "progress ", "feature ", "option ")):
            flush_commit()
            if do_ref_rewrite and stripped.startswith("reset "):
                rewritten = rewrite_ref_line(stripped, "reset", source_ref, target_ref)
                output_stream.write((rewritten + "\n").encode("utf-8"))
            else:
                output_stream.write(raw_line)
            continue

        # Everything else: buffer if in commit, pass through otherwise
        if in_commit:
            commit_buffer.append(raw_line)
        else:
            output_stream.write(raw_line)

    output_stream.flush()


def main():
    parser = argparse.ArgumentParser(
        description="Filter a git fast-export stream: rewrite emails and strip empty commits."
    )
    parser.add_argument(
        "--mailmap",
        required=True,
        help="Path to the sync-mailmap file for email rewriting.",
    )
    parser.add_argument(
        "--source-ref",
        default=None,
        help="Source ref name as it appears in the stream (e.g., refs/heads/main). "
        "If provided with --target-ref, rewrites commit/reset lines to point to target-ref.",
    )
    parser.add_argument(
        "--target-ref",
        default=None,
        help="Target ref name to rewrite to (e.g., refs/heads/sync/dry-run-XYZ).",
    )
    args = parser.parse_args()

    if (args.source_ref is None) != (args.target_ref is None):
        print("ERROR: --source-ref and --target-ref must be provided together.", file=sys.stderr)
        sys.exit(1)

    mailmap = load_mailmap(args.mailmap)

    # Work in binary mode to handle data blocks correctly
    input_stream = sys.stdin.buffer
    output_stream = sys.stdout.buffer

    filter_stream(input_stream, output_stream, mailmap, args.source_ref, args.target_ref)


if __name__ == "__main__":
    main()
