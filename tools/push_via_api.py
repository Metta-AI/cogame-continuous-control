#!/usr/bin/env python3
"""Pushes the working tree to GitHub through the Git Data API.

The sandbox's git credential helper is scoped to `claude/*` branches, so a
plain `git push` to `main` of a coworld repo is refused. The playbook's
documented path is the Git Data API (bootstrapping a brand-new repo through the
Contents API first, because the Data API cannot create a repo's first object).

    python3 tools/push_via_api.py Metta-AI/cogame-continuous-control main "<message>"

No token is ever printed: everything goes through `gh api`, which reads GH_TOKEN
itself.
"""

import base64
import json
import subprocess
import sys


def gh(args, payload=None):
    cmd = ["gh", "api"] + args
    if payload is not None:
        cmd += ["--input", "-"]
        out = subprocess.run(cmd, input=json.dumps(payload), text=True,
                             capture_output=True)
    else:
        out = subprocess.run(cmd, text=True, capture_output=True)
    if out.returncode != 0:
        raise SystemExit("gh api failed: %s\n%s" % (" ".join(args), out.stderr))
    return json.loads(out.stdout) if out.stdout.strip() else {}


def main():
    repo, branch, message = sys.argv[1], sys.argv[2], sys.argv[3]
    listing = subprocess.run(["git", "ls-files", "-s"], text=True,
                             capture_output=True, check=True).stdout
    entries = []
    for line in listing.splitlines():
        meta, path = line.split("\t", 1)
        mode, _sha, _stage = meta.split()
        entries.append((mode, path))

    parent = None
    base_tree = None
    try:
        ref = gh(["repos/%s/git/refs/heads/%s" % (repo, branch)])
        parent = ref["object"]["sha"]
    except SystemExit:
        # A brand-new repo: the Data API cannot create the first object, so
        # bootstrap one file through the Contents API.
        boot = gh(["-X", "PUT", "repos/%s/contents/.bootstrap" % repo], {
            "message": "chore: bootstrap the repository",
            "branch": branch,
            "content": base64.b64encode(b"bootstrap\n").decode()})
        parent = boot["commit"]["sha"]

    tree = []
    for index, (mode, path) in enumerate(entries):
        with open(path, "rb") as handle:
            data = handle.read()
        blob = gh(["-X", "POST", "repos/%s/git/blobs" % repo], {
            "content": base64.b64encode(data).decode(), "encoding": "base64"})
        tree.append({"path": path, "mode": mode, "type": "blob",
                     "sha": blob["sha"]})
        if (index + 1) % 20 == 0:
            print("  %d/%d blobs" % (index + 1, len(entries)), flush=True)

    made = gh(["-X", "POST", "repos/%s/git/trees" % repo], {"tree": tree})
    commit = gh(["-X", "POST", "repos/%s/git/commits" % repo], {
        "message": message, "tree": made["sha"], "parents": [parent]})
    gh(["-X", "PATCH", "repos/%s/git/refs/heads/%s" % (repo, branch)],
       {"sha": commit["sha"], "force": False})
    print("pushed", commit["sha"])


if __name__ == "__main__":
    main()
