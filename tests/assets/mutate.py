"""Produce adversarial asset archives for the real router installer."""
import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

source, output, mode = sys.argv[1:]
with tarfile.open(source, "r:gz") as archive:
    files = {member.name: archive.extractfile(member).read() for member in archive.getmembers()}
manifest = json.loads(files["manifest.json"])
entry = manifest["files"][0]
if mode == "version":
    manifest["version"] = "999.0.0"
elif mode == "foreign-source":
    entry = next(item for item in manifest["files"] if item["target"] == "fake")
    entry["source"] = "bol-van"
elif mode == "traversal":
    entry["path"] = "../outside"
elif mode == "forbidden":
    entry["target"] = "network"
elif mode == "duplicate":
    manifest["files"].append(copy.deepcopy(entry))
elif mode == "oversize":
    entry["size"] = 2**30
elif mode == "checksum":
    files[entry["path"]] += b"CORRUPTED"
elif mode == "missing":
    del files[entry["path"]]
elif mode == "changed":
    entry = next(item for item in manifest["files"] if item["path"] == "resources/exclude.txt")
    files[entry["path"]] = b"changed-from-new-release.example\n"
    entry["size"] = len(files[entry["path"]])
    entry["sha256"] = hashlib.sha256(files[entry["path"]]).hexdigest()
if mode == "changed":
    # Exercise replacement and rollback of an existing binary, not only list text.
    entry = next(item for item in manifest["files"] if item["target"] == "fake")
    files[entry["path"]] += b"SECOND RELEASE BINARY"
    entry["size"] = len(files[entry["path"]])
    entry["sha256"] = hashlib.sha256(files[entry["path"]]).hexdigest()
if mode.startswith("syntax-"):
    name = {"syntax-catalog": "catalogs/flowseal.json", "syntax-config": "resources/manager.json",
            "syntax-network": "resources/network.json", "syntax-urls": "resources/urls.txt",
            "syntax-list": "resources/exclude.txt"}[mode]
    entry = next(item for item in manifest["files"] if item["path"] == name)
    files[name] = b"{}" if name.endswith(".json") else b"BAD\x00DATA"
    entry["size"] = len(files[name])
    entry["sha256"] = hashlib.sha256(files[name]).hexdigest()
files["manifest.json"] = (json.dumps(manifest) + "\n").encode()
with tarfile.open(output, "w:gz", format=tarfile.USTAR_FORMAT) as archive:
    for name, payload in files.items():
        member = tarfile.TarInfo(name)
        member.size, member.mode = len(payload), 0o644
        if mode == "symlink" and name == entry["path"]:
            member.type, member.linkname, member.size = tarfile.SYMTYPE, "/etc/config/network", 0
        archive.addfile(member, io.BytesIO(payload) if member.isfile() else None)
    if mode == "extra":
        member = tarfile.TarInfo("../../jzm-assets-escape")
        member.size = 4
        archive.addfile(member, io.BytesIO(b"FAIL"))
    if mode == "duplicate-member":
        member = tarfile.TarInfo(entry["path"])
        member.size = len(files[entry["path"]])
        archive.addfile(member, io.BytesIO(files[entry["path"]]))
