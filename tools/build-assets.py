#!/usr/bin/env python3
"""Resolve external data on the build host; the router receives ready local assets."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
MAX_FILE = 2 * 1024 * 1024
MAX_TOTAL = 16 * 1024 * 1024
REPO = "Flowseal/zapret-discord-youtube"
MANAGER_REPO = "StressOzz/Zapret-Manager"
# The package's 4pda.bin and this Flowseal payload are byte-identical (284 bytes).
MANAGER_FAKE_ALIASES = {"4pda.bin": "tls_clienthello_4pda_to.bin"}
SAFE_BIN = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,155}\.bin\Z")


def fetch(url, limit=MAX_FILE):
    request = urllib.request.Request(url, headers={"User-Agent": "JZM asset builder"})
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read(limit + 1)
    if not body or len(body) > limit:
        raise ValueError("empty or oversized upstream resource: " + url)
    return body


def source_revision(repo=REPO):
    remote = subprocess.check_output(["git", "ls-remote", "https://github.com/" + repo + ".git",
                                      "refs/heads/main"], text=True, timeout=60).strip().split()
    if len(remote) != 2 or remote[1] != "refs/heads/main" or not re.fullmatch(r"[a-f0-9]{40}", remote[0]):
        raise ValueError("invalid Flowseal revision")
    return remote[0]


def source_files(revision, repo=REPO):
    cache = ROOT / ".test-tmp/assets-cache" / repo / revision / "source.tar.gz"
    if not cache.is_file():
        body = fetch("https://codeload.github.com/" + repo + "/tar.gz/" + revision, 64 * 1024 * 1024)
        cache.parent.mkdir(parents=True, exist_ok=True)
        staged = cache.with_name(cache.name + ".tmp")
        staged.write_bytes(body)
        staged.replace(cache)
    prefix = repo.split("/")[1] + "-" + revision + "/"
    selected, expanded = {}, 0
    with tarfile.open(cache, "r:gz") as archive:
        for member in archive:
            expanded += member.size
            if expanded > 256 * 1024 * 1024:
                raise ValueError("oversized Flowseal source archive")
            if member.isdir() and member.name == prefix.rstrip("/"):
                continue
            if not member.name.startswith(prefix):
                raise ValueError("unexpected upstream archive root")
            path = member.name[len(prefix):]
            wanted = (path in {"Zapret-Manager.sh", "files/StrYoutube"}) if repo == MANAGER_REPO else (
                path in {"lists/list-google.txt", "lists/list-general.txt", "lists/list-exclude.txt",
                         "utils/targets.txt", "service.bat"} or (
                path.startswith("bin/") and SAFE_BIN.fullmatch(path[4:])) or re.fullmatch(
                    r"general[A-Za-z0-9_ .()-]*\.bat", path, re.I))
            if not wanted:
                continue
            if not member.isfile() or member.size > MAX_FILE or path in selected:
                raise ValueError("invalid upstream asset: " + path)
            body = archive.extractfile(member).read(MAX_FILE + 1)
            if not body or len(body) != member.size:
                raise ValueError("invalid upstream payload: " + path)
            selected[path] = body
    return selected


def version():
    return re.search(r"VERSION = '([^']+)'", (ROOT / "src/lib/resources.uc").read_text()).group(1)


def build(output, fixtures=False):
    files, entries, fakes, origins = {}, [], [], []
    binaries = {}
    revision = "a" * 40
    with tempfile.TemporaryDirectory(prefix="jzm-assets-") as temporary:
        work = Path(temporary)
        if fixtures:
            bats = [("general.bat", (ROOT / "tests/fixtures/flowseal.bat").read_bytes())]
            manager_revision = revision
            manager_source = (ROOT / "tests/fixtures/manager.txt").read_bytes()
            youtube_source = (ROOT / "tests/fixtures/youtube.txt").read_bytes()
            needed = {"ACTIVE_DISCORD_UDP.bin", "ACTIVE_GAME_UDP.bin", "tls_clienthello_www_google_com.bin",
                      "quic_initial_steamcommunity_com.bin", "tls_clienthello_4pda_to.bin", "stun.bin", "tls_clienthello_max_ru.bin", "tls_test.bin", "tls_alternate.bin"}
            binaries = {("flowseal", name): b"FLOWSEAL\x00\xffBINARY" for name in sorted(needed)}
            lists = {"exclude.txt": b"refreshed.example\n", "google.txt": b"youtube.com\n",
                     "user.txt": b"^dns.google\ngeneral.example\n"}
            targets = b'Discord = "https://discord.com"\nDNS = "PING:1.1.1.1"\n'
            game_ports = {"tcp_ports": "1024-65535", "udp_ports": "1024-65535"}
        else:
            revision = source_revision()
            upstream = source_files(revision)
            manager_revision = source_revision(MANAGER_REPO)
            manager_files = source_files(manager_revision, MANAGER_REPO)
            manager_source = manager_files["Zapret-Manager.sh"]
            youtube_source = manager_files["files/StrYoutube"]
            bats = []
            for path in sorted(upstream):
                if path.startswith("bin/") and SAFE_BIN.fullmatch(path[4:]):
                    binaries["flowseal", path[4:]] = upstream[path]
                if re.fullmatch(r"general[A-Za-z0-9_ .()-]*\.bat", path, re.I):
                    bats.append((path, upstream[path]))
            lists = {local: upstream[remote] for local, remote in {
                "exclude.txt": "lists/list-exclude.txt", "google.txt": "lists/list-google.txt",
                "user.txt": "lists/list-general.txt"}.items()}
            targets = upstream["utils/targets.txt"]
            service = upstream["service.bat"].decode("utf-8-sig")
            game_ports = {}
            for protocol in ("TCP", "UDP"):
                match = re.search(r'set "GameFilter' + protocol + r'Range=([0-9,-]+)"', service)
                if not match:
                    raise ValueError("missing Flowseal game ports: " + protocol)
                game_ports[protocol.lower() + "_ports"] = match[1]
        origins = [{"source": "flowseal", "repo": REPO, "revision": revision},
                   {"source": "manager", "repo": MANAGER_REPO, "revision": manager_revision}]
        bat_files = []
        for number, (name, body) in enumerate(sorted(bats)):
            file = work / (str(number) + ".bat")
            file.write_bytes(body)
            bat_files.append({"name": name, "file": str(file)})
        (work / "manager.txt").write_bytes(manager_source)
        (work / "youtube.txt").write_bytes(youtube_source)
        request = work / "input.json"
        request.write_text(json.dumps({"flowseal": bat_files, "game_ports": game_ports,
                                       "manager": str(work / "manager.txt"), "youtube": str(work / "youtube.txt")}))
        env = {**os.environ, "ZM_HOME": str(ROOT)}
        converted = json.loads(subprocess.check_output(["ucode", "-S", "-L", str(ROOT / "src/lib"), str(ROOT / "tools/prepare-catalogs.uc"), str(request)], env=env))

        def add(path, payload, target, name, source=None):
            if len(payload) > MAX_FILE:
                raise ValueError("oversized asset: " + path)
            entry = {"path": path, "target": target, "name": name, "size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
            if source is not None:
                entry["source"] = source
            files[path] = payload
            entries.append(entry)
            return entry

        for (source, name), payload in sorted(binaries.items()):
            add("fakes/" + name, payload, "fake", name, source)
            path = "/opt/zapret/fakes/" + name
            fakes.append({"source": source, "name": name, "path": path, "revision": revision})

        resources = {name: (ROOT / "data" / name).read_bytes() for name in ("manager.json", "network.json")}
        resources.update(lists)
        urls = re.findall(r'^\s*[A-Za-z0-9_]+\s*=\s*"(https?://[^"\s]+)"\s*$',
                          targets.decode("utf-8-sig"), re.M)
        if not urls or len(urls) > 64:
            raise ValueError("invalid Flowseal URL targets")
        resources["urls.txt"] = ("\n".join(dict.fromkeys(urls)) + "\n").encode()
        text = converted["flowseal"]
        for name in set(re.findall(r"/opt/zapret/fakes/([A-Za-z0-9_.-]+\.bin)", text)):
            if ("flowseal", name) not in binaries:
                raise ValueError("required Flowseal fake is missing: " + name)
        # Keep every Manager preset. Missing Flowseal payloads are explicit metadata,
        # never fetched from another source or replaced with a guessed binary.
        manager_text = converted["manager"].replace("/opt/zapret/files/fake/", "/opt/zapret/fakes/")
        for original, flowseal_name in MANAGER_FAKE_ALIASES.items():
            if ("flowseal", flowseal_name) not in binaries:
                raise ValueError("required Flowseal alias payload is missing: " + flowseal_name)
            manager_text = manager_text.replace("/opt/zapret/fakes/" + original, "/opt/zapret/fakes/" + flowseal_name)
        unavailable = {}
        for section in manager_text.split("#")[1:]:
            name, _, body = section.partition("\n")
            missing = sorted({name for name in re.findall(r"/opt/zapret/fakes/([A-Za-z0-9_.-]+\.bin)", body)
                              if ("flowseal", name) not in binaries})
            if missing:
                unavailable[name.strip()] = missing
        resources["strategies.txt"] = "".join("#" + part for part in text.split("#")[1:]
            if part.startswith("general")).encode()
        for name, payload in sorted(resources.items()):
            add("resources/" + name, payload, "resource", name)
        for kind, catalog, rev in [("flowseal", text, revision), ("manager", manager_text, manager_revision)]:
            doc = {"format": 1, "source": kind, "revision": rev, "catalog": catalog,
                   "skipped": converted["skipped"] if kind == "flowseal" else [],
                   "unavailable": unavailable if kind == "manager" else {}}
            add("catalogs/" + kind + ".json", (json.dumps(doc, ensure_ascii=False) + "\n").encode(), "catalog", kind + ".json")
        manifest = {"format": 1, "version": version(), "origins": origins, "files": entries, "fakes": fakes}
        files["manifest.json"] = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
        if sum(map(len, files.values())) > MAX_TOTAL:
            raise ValueError("expanded asset archive exceeds 16 MiB")
        output = Path(output).resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        staged = output.with_name(output.name + ".tmp")
        with staged.open("wb") as target, gzip.GzipFile(filename="", mode="wb", fileobj=target, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for name, payload in sorted(files.items()):
                    member = tarfile.TarInfo(name)
                    member.size, member.mode, member.mtime = len(payload), 0o644, 0
                    archive.addfile(member, io.BytesIO(payload))
        staged.replace(output)
        print(f"{output}: {len(fakes)} fakes, {len(entries)} files, {output.stat().st_size} bytes")
        for name, missing in unavailable.items():
            print("Unavailable Manager preset: " + name + ": " + ", ".join(missing))
        for skipped in converted["skipped"]:
            print("Skipped: " + skipped)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--fixtures", action="store_true")
    args = parser.parse_args()
    build(args.output, args.fixtures)
