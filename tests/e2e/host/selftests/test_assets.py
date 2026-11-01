import hashlib
import io
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
import assets

def asset(version, suffix, data=b"archive"):
    name = f"Router-Emulator-{version}-{suffix}"
    return {"name": name, "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
            "browser_download_url": f"{assets.REPO}/releases/download/v{version}/{name}"}


def release(version, *suffixes, **fields):
    return {"tag_name": "v" + version, "assets": [asset(version, suffix) for suffix in suffixes], **fields}


class LoaderTests(unittest.TestCase):
    def test_presets_only_release_uses_latest_compatible_binary(self):
        selected = assets.select_assets([release("4.1.1", "presets.zip"),
                                         release("4.1", "linux-x86_64.tar.gz", "presets.zip")])
        self.assertEqual([r["tag_name"] for r, _ in selected], ["v4.1", "v4.1.1"])

    def test_prereleases_and_other_preset_families_are_ignored(self):
        selected = assets.select_assets([release("5.0", "linux-x86_64.tar.gz", "presets.zip", prerelease=True),
                                         release("4.2", "presets.zip"),
                                         release("4.1", "linux-x86_64.tar.gz", "presets.zip")])
        self.assertEqual([r["tag_name"] for r, _ in selected], ["v4.1", "v4.1"])

    def test_missing_compatible_presets_fails(self):
        with self.assertRaises(ValueError):
            assets.select_assets([release("4.2", "linux-x86_64.tar.gz"), release("4.1", "presets.zip")])

    def test_untrusted_metadata_is_rejected(self):
        for field, value in (("size", assets.MAX_ASSET + 1), ("digest", "sha256:wrong"),
                             ("browser_download_url", "https://other.example/file")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                entry = release("4.1", "linux-x86_64.tar.gz", "presets.zip")
                entry["assets"][0][field] = value
                assets.select_assets([entry])

    def test_tar_and_zip_have_the_same_normalized_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "binary.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("Router-Emulator/emulator.sh")
                member.size = 4
                member.mode = 0o755
                stream.addfile(member, io.BytesIO(b"test"))
            presets = root / "presets.zip"
            with zipfile.ZipFile(presets, "w") as stream:
                stream.writestr("Router-Emulator/presets/board.ini", "[preset]")
            target = root / "extract"
            assets.extract(archive, target)
            assets.extract(presets, target)
            self.assertEqual((target / "emulator.sh").read_bytes(), b"test")
            self.assertTrue((target / "presets/board.ini").is_file())

    def test_archive_traversal_and_links_are_rejected(self):
        for name in ("../escape", "/escape", "Router-Emulator/../../escape", "C:/escape", "..\\escape"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive = root / "bad.zip"
                with zipfile.ZipFile(archive, "w") as stream:
                    stream.writestr(name, "bad")
                with self.assertRaises(ValueError):
                    assets.extract(archive, root / "extract")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.tar.gz"
            with tarfile.open(archive, "w:gz") as stream:
                member = tarfile.TarInfo("Router-Emulator/link")
                member.type = tarfile.SYMTYPE
                member.linkname = "/etc/passwd"
                stream.addfile(member)
            with self.assertRaises(ValueError):
                assets.extract(archive, root / "extract")

    def test_expansion_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "large.zip"
            with zipfile.ZipFile(archive, "w") as stream:
                stream.writestr("large", "12345")
            with patch.object(assets, "MAX_EXPANDED", 4), self.assertRaises(ValueError):
                assets.extract(archive, root / "extract")

    def test_download_reuses_verified_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = asset("4.1", "presets.zip", b"valid")
            (root / metadata["name"]).write_bytes(b"valid")
            with patch.object(assets.urllib.request, "urlopen") as network:
                self.assertTrue(assets.download(metadata, root).is_file())
                network.assert_not_called()

    def test_corrupted_download_retries_without_publishing_partial_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = asset("4.1", "presets.zip", b"valid")
            (root / metadata["name"]).write_bytes(b"wrong")
            with patch.object(assets.urllib.request, "urlopen", side_effect=[io.BytesIO(b"wrong"), io.BytesIO(b"valid")]), \
                    patch.object(assets.time, "sleep"):
                self.assertEqual(assets.download(metadata, root).read_bytes(), b"valid")
            self.assertFalse(list(root.glob("*.part")))
