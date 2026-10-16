"""The bundle transport must preserve the lock's integrity and extracted files."""

import gzip
import importlib.util
import io
import pathlib
import shutil
import tarfile
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "acp-bundle.py"
SPEC = importlib.util.spec_from_file_location("acp_bundle", SCRIPT)
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)
ADAPTER = "node_modules/@agentclientprotocol/codex-acp"


def archive(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as stream:
        for name, content, mode in files:
            member = tarfile.TarInfo("package/" + name)
            member.size = len(content)
            member.mode = mode
            member.mtime = 123456789
            stream.addfile(member, io.BytesIO(content))
    return output.getvalue()


def row(path, data, platform=("-", "-", "-")):
    return "\t".join((path, "https://registry.npmjs.org/test/-/test.tgz", bundle.integrity(data), *platform))


class BundleTest(unittest.TestCase):
    def test_platform_and_image_filter_preserve_adapter_root(self):
        data = b"fixture"
        raw = "\n".join((row(ADAPTER, data), row("node_modules/ordinary", data),
                         row("node_modules/@openai/codex-linux-x64", data, ("linux", "x64", "-")),
                         row("node_modules/macos", data, ("darwin", "x64", "-")),
                         row("node_modules/arm", data, ("linux", "arm64", "-")),
                         row("node_modules/musl", data, ("linux", "x64", "musl")))).encode()
        self.assertEqual([entry[0] for entry in bundle.manifest_rows(raw, "codex")], [ADAPTER, "node_modules/ordinary"])

    def test_bad_destinations_and_missing_root_are_rejected(self):
        for path in ("../outside", "/node_modules/absolute", "node_modules/../outside", "node_modules//ambiguous"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                bundle.manifest_rows(row(path, b"fixture").encode(), "codex")
        with self.assertRaisesRegex(ValueError, "root missing"):
            bundle.manifest_rows(row("node_modules/ordinary", b"fixture").encode(), "codex")

    def test_tampered_package_never_produces_an_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = root / "codex-acp@1.0.0.tsv"
            manifest.write_text(row(ADAPTER, b"expected") + "\n")
            with self.assertRaisesRegex(ValueError, "integrity mismatch"):
                bundle.build(manifest, "codex", root / "out", lambda _: b"tampered")
            self.assertEqual(list((root / "out").iterdir()), [])

    def test_archive_traversal_is_rejected(self):
        data = archive([("../../escaped", b"not allowed", 0o644)])
        with tempfile.TemporaryDirectory() as temporary, self.assertRaises(ValueError):
            bundle.unpack(data, pathlib.Path(temporary) / "package")

    def test_escaping_symbolic_link_is_rejected(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w:gz") as stream:
            member = tarfile.TarInfo("package/link")
            member.type = tarfile.SYMTYPE
            member.linkname = "../../outside"
            stream.addfile(member)
        with tempfile.TemporaryDirectory() as temporary, self.assertRaises(tarfile.FilterError):
            bundle.unpack(data.getvalue(), pathlib.Path(temporary) / "package")

    @unittest.skipUnless(shutil.which("tar") and shutil.which("zstd"), "GNU tar and zstd required")
    def test_reproducible_archives_preserve_bytes_notices_and_executable_modes(self):
        data = archive([("package.json", b'{"name":"@agentclientprotocol/codex-acp","version":"1.0.0"}', 0o644),
                        ("dist/index.js", b"#!/usr/bin/env node\n", 0o755),
                        ("LICENSE", b"retained upstream notice\n", 0o644)])
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = root / "codex-acp@1.0.0.tsv"
            manifest.write_text(row(ADAPTER, data) + "\n")
            first = bundle.build(manifest, "codex", root / "first", lambda _: data)
            second = bundle.build(manifest, "codex", root / "second", lambda _: data)
            self.assertEqual(first, second)
            for entry in first["artifacts"].values():
                self.assertEqual((root / "first" / entry["file"]).read_bytes(), (root / "second" / entry["file"]).read_bytes())
            compressed = root / "first" / first["artifacts"]["gzip"]["file"]
            with tarfile.open(fileobj=io.BytesIO(gzip.decompress(compressed.read_bytes()))) as stream:
                self.assertEqual(stream.extractfile(ADAPTER + "/LICENSE").read(), b"retained upstream notice\n")
                entry = stream.getmember(ADAPTER + "/dist/index.js")
                self.assertEqual(entry.mode, 0o755)
                self.assertEqual((entry.uid, entry.gid, entry.mtime), (0, 0, 0))
            with self.assertRaisesRegex(ValueError, "already exists"):
                bundle.build(manifest, "codex", root / "first", lambda _: data)


if __name__ == "__main__":
    unittest.main()
