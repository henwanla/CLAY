#!/usr/bin/env python3
"""Check staged source for common credential formats and local files."""

import subprocess
from pathlib import PurePosixPath


def main():
    paths = subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0")
    private_count = 0
    for raw in filter(None, paths):
        path = PurePosixPath(raw.decode("utf-8", errors="replace").lower())
        if (path.name in {"github-auth.txt", ".env", "local.properties", ".ds_store"}
                or path.name.startswith(("github_key", ".env."))
                or path.suffix in {".key", ".p12", ".pfx", ".mobileprovision", ".jks", ".keystore"}
                or path.parts[0] in {"dist", ".build"}):
            private_count += 1

    patterns = (
        r"(^|[^A-Za-z0-9_])gh[pours]_[A-Za-z0-9]{32,}",
        r"(^|[^A-Za-z0-9_])github_pat_[A-Za-z0-9_]{40,}",
        r"-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----",
        r"(^|[^A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Z0-9]|$)",
    )
    result = subprocess.run(["git", "grep", "--cached", "-I", "-l", "-z", "-E", "-e", "|".join(patterns), "--"],
                            stdout=subprocess.PIPE, check=False)
    if result.returncode not in (0, 1):
        raise SystemExit("Could not check indexed source.")
    signature_count = result.stdout.count(b"\0")
    if private_count or signature_count:
        # A filename can itself be sensitive. Do not print it or matched text to CI.
        raise SystemExit(f"Review staged source: {private_count} local file(s), "
                         f"{signature_count} text file(s) with a credential signature.")
    print("Staged source passed the local file and common credential signature checks.")


if __name__ == "__main__":
    main()
