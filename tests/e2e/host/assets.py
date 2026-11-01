import hashlib
import json
import os
import re
import shutil
import stat
import tarfile
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
# Release discovery and verified archive extraction.
REPO = "https://github.com/stavultras/router-emulator"
API = "https://api.github.com/repos/stavultras/router-emulator/releases?per_page=100"
MAX_ASSET = 128 * 1024 * 1024
MAX_EXPANDED = 512 * 1024 * 1024


def select_assets(releases):
    stable = [r for r in releases if not r.get("draft") and not r.get("prerelease")]
    binary = None
    for release in stable:
        for asset in release.get("assets", []):
            found = re.fullmatch(r"Router-Emulator-(\d+\.\d+(?:\.\d+)?)-linux-x86_64\.tar\.gz", asset["name"])
            if found:
                binary = (release, asset, found[1].split(".")[:2])
                break
        if binary:
            break
    if not binary:
        raise ValueError("no stable Linux x86_64 release among the last 100 releases")
    for release in stable:
        for asset in release.get("assets", []):
            found = re.fullmatch(r"Router-Emulator-(\d+\.\d+(?:\.\d+)?)-presets\.zip", asset["name"])
            if found and found[1].split(".")[:2] == binary[2]:
                selected = [(binary[0], binary[1]), (release, asset)]
                for rel, item in selected:
                    expected = f"{REPO}/releases/download/{rel['tag_name']}/{item['name']}"
                    if item.get("browser_download_url") != expected or not re.fullmatch(r"v?\d+(?:\.\d+){1,2}", rel["tag_name"]):
                        raise ValueError("invalid asset URL or release tag")
                    if not 0 < item.get("size", 0) <= MAX_ASSET:
                        raise ValueError("invalid asset size")
                    if item.get("digest") and not re.fullmatch(r"sha256:[a-f0-9]{64}", item["digest"]):
                        raise ValueError("invalid asset digest")
                return selected
    raise ValueError("no matching presets archive for the latest binary release")


def verified(path, asset):
    if not path.is_file() or path.stat().st_size != asset["size"]:
        return False
    digest = asset.get("digest")
    if not digest:
        return False  # Without a published digest, do not trust a previously interrupted cache.
    with path.open("rb") as stream:
        actual = hashlib.sha256()
        for chunk in iter(lambda: stream.read(65536), b""):
            actual.update(chunk)
    return actual.hexdigest() == digest[7:]


def download(asset, folder):
    target = folder / asset["name"]
    if verified(target, asset):
        return target
    partial = target.with_suffix(target.suffix + ".part")
    for attempt in range(3):
        try:
            digest, count = hashlib.sha256(), 0
            request = urllib.request.Request(asset["browser_download_url"], headers={"User-Agent": "JZM-emulator-setup"})
            with urllib.request.urlopen(request, timeout=30) as response, partial.open("wb") as output:
                for chunk in iter(lambda: response.read(65536), b""):
                    count += len(chunk)
                    if count > asset["size"]:
                        raise ValueError("asset exceeds its published size")
                    output.write(chunk)
                    digest.update(chunk)
            if count != asset["size"] or (asset.get("digest") and asset["digest"][7:] != digest.hexdigest()):
                raise ValueError("asset size/SHA256 mismatch")
            os.replace(partial, target)
            return target
        except (OSError, ValueError):
            partial.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(1)
    raise AssertionError("unreachable")


def member_path(name, root):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name:
        raise ValueError(f"unsafe archive member: {name!r}")
    parts = path.parts
    if parts and parts[0] == "Router-Emulator":
        parts = parts[1:]
    return root.joinpath(*parts)


def extract(archive, destination):
    # Extract only directories/regular files into a new private directory; reject all links/devices.
    total = 0
    if archive.name.endswith(".tar.gz"):
        with tarfile.open(archive, "r:gz") as source:
            for item in source:
                path = member_path(item.name, destination)
                if item.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                if not item.isfile():
                    raise ValueError(f"unsupported archive member: {item.name}")
                total += item.size
                if total > MAX_EXPANDED:
                    raise ValueError("archive too large")
                path.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(item) as stream, path.open("xb") as output:
                    shutil.copyfileobj(stream, output)
                path.chmod(item.mode & 0o777)
    else:
        with zipfile.ZipFile(archive) as source:
            for item in source.infolist():
                path = member_path(item.filename, destination)
                mode = item.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise ValueError("symlink in presets ZIP")
                if item.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                total += item.file_size
                if total > MAX_EXPANDED:
                    raise ValueError("archive too large")
                path.parent.mkdir(parents=True, exist_ok=True)
                with source.open(item) as stream, path.open("xb") as output:
                    shutil.copyfileobj(stream, output)


def install(root):
    headers = {"User-Agent": "JZM-emulator-setup", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    with urllib.request.urlopen(urllib.request.Request(API, headers=headers), timeout=30) as response:
        data = response.read(8 * 1024 * 1024 + 1)
    if len(data) > 8 * 1024 * 1024:
        raise ValueError("release metadata too large")
    selected = select_assets(json.loads(data))
    downloads = root / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=root) as temporary:
        staging = Path(temporary)
        for release, asset in selected:
            print(f"Downloading {release['tag_name']}: {asset['name']}", flush=True)
            extract(download(asset, downloads), staging)
        for name in ("emulator.sh", "qemu/qemu-system-aarch64", "tools/prepare-nand.sh", "presets/cudy-wr3000p-v1.ini"):
            if not (staging / name).is_file():
                raise ValueError(f"incomplete release: {name}")
        (root / ".jzm-release.json").unlink(missing_ok=True)
        shutil.copytree(staging, root, dirs_exist_ok=True)
    marker = root / ".jzm-release.json.tmp"
    marker.write_text(json.dumps([{"tag": r["tag_name"], "asset": a} for r, a in selected], indent=2) + "\n", encoding="utf-8")
    marker.replace(root / ".jzm-release.json")
