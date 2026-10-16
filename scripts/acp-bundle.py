#!/usr/bin/env python3
"""Build image-reuse bundles from an existing ACP TSV, without resolving dependencies."""

import argparse
import base64
import concurrent.futures
import gzip
import hashlib
import io
import json
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request


PROFILES = {
    "claude": ("claude-agent-acp", "node_modules/@anthropic-ai/claude-agent-sdk-"),
    "codex": ("codex-acp", "node_modules/@openai/codex-"),
}
PROFILE = "linux-x64-glibc-image"


def integrity(data):
    return "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode("ascii")


def manifest_rows(raw, runtime):
    package, omitted = PROFILES[runtime]
    rows, seen = [], set()
    for line in raw.decode("utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 6:
            raise ValueError("manifest rows must have six fields")
        path, url, digest, os_name, cpu, libc = fields
        parts = pathlib.PurePosixPath(path).parts
        if not parts or parts[0] != "node_modules" or ".." in parts or "\\" in path or path != str(pathlib.PurePosixPath(path)):
            raise ValueError("unsafe package destination")
        if path in seen:
            raise ValueError("duplicate package destination")
        seen.add(path)
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or parsed.hostname != "registry.npmjs.org" or parsed.username or parsed.password or parsed.port not in (None, 443):
            raise ValueError("expected an HTTPS npm registry tarball")
        if not digest.startswith("sha512-"):
            raise ValueError("expected a SHA-512 integrity pin")
        try:
            decoded = base64.b64decode(digest[7:], validate=True)
        except ValueError as error:
            raise ValueError("invalid integrity pin") from error
        if len(decoded) != 64:
            raise ValueError("invalid integrity pin length")
        if path.startswith(omitted):
            continue
        if any(value != "-" and wanted not in value.split(",") for value, wanted in zip((os_name, cpu, libc), ("linux", "x64", "glibc"))):
            continue
        rows.append((path, url, digest))
    if not any(row[0] == "node_modules/@agentclientprotocol/" + package for row in rows):
        raise ValueError("adapter root missing from selected packages")
    return sorted(rows)


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read()


def unpack(data, target):
    """Strip the npm archive root, refusing traversal, devices, and escaping links."""
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        members = []
        for member in archive.getmembers():
            parts = pathlib.PurePosixPath(member.name).parts
            if not parts or parts[0] in ("/", "..") or ".." in parts:
                raise ValueError("unsafe archive path")
            if len(parts) == 1:
                continue
            member.name = str(pathlib.PurePosixPath(*parts[1:]))
            if member.islnk():
                link = pathlib.PurePosixPath(member.linkname).parts
                if not link or link[0] != parts[0] or ".." in link:
                    raise ValueError("unsafe archive hard link")
                member.linkname = str(pathlib.PurePosixPath(*link[1:]))
            members.append(member)
        archive.extractall(target, members=members, filter="data")


def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda p: str(p.relative_to(root)).encode()):
        if path.is_file() and not path.is_symlink():
            relative = str(path.relative_to(root))
            if "\n" in relative or "\\" in relative:
                raise ValueError("unsupported file name in tree digest")
            digest.update((hashlib.sha256(path.read_bytes()).hexdigest() + "  " + relative + "\n").encode())
    return digest.hexdigest()


def build(manifest, runtime, output, fetch_bytes=fetch):
    raw = manifest.read_bytes()
    rows = manifest_rows(raw, runtime)
    output.mkdir(parents=True, exist_ok=True)
    basename = manifest.stem + "." + PROFILE
    for suffix in (".tar.gz", ".tar.zst", ".json"):
        if (output / (basename + suffix)).exists():
            raise ValueError("output already exists; immutable bundles are never overwritten")
    with tempfile.TemporaryDirectory(prefix="acp-bundle-") as temporary:
        work = pathlib.Path(temporary)
        tree = work / "tree"
        tree.mkdir()

        def verified(row):
            data = fetch_bytes(row[1])
            if integrity(data) != row[2]:
                raise ValueError("package integrity mismatch")
            return data

        # Download concurrently; extract in deterministic parent-before-child order.
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            for row, data in zip(rows, pool.map(verified, rows)):
                unpack(data, tree / row[0])
        package = PROFILES[runtime][0]
        root_package = json.loads((tree / "node_modules" / "@agentclientprotocol" / package / "package.json").read_text())
        if root_package.get("name") != "@agentclientprotocol/" + package or manifest.stem != package + "@" + root_package.get("version", ""):
            raise ValueError("adapter package does not match the manifest filename pin")
        for directory in tree.rglob("*"):
            if directory.is_dir() and not directory.is_symlink():
                directory.chmod(0o755)
        tar = work / "bundle.tar"
        subprocess.run(["tar", "--format=gnu", "--sort=name", "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner", "-cf", str(tar), "-C", str(tree), "node_modules"], check=True)
        compressed = work / "bundle.tar.gz"
        with tar.open("rb") as source, compressed.open("wb") as destination:
            with gzip.GzipFile(fileobj=destination, mode="wb", filename="", mtime=0, compresslevel=9) as compressor:
                shutil.copyfileobj(source, compressor)
        zstd = work / "bundle.tar.zst"
        subprocess.run(["zstd", "-q", "-T1", "-9", str(tar), "-o", str(zstd)], check=True)
        result = {
            "profile": PROFILE,
            "runtime": runtime,
            "pin": manifest.stem,
            "manifest_sha256": hashlib.sha256(raw).hexdigest(),
            "packages": len(rows),
            "tree_sha256": tree_digest(tree),
            "artifacts": {},
        }
        for encoding, path in (("gzip", compressed), ("zstd", zstd)):
            name = basename + (".tar.gz" if encoding == "gzip" else ".tar.zst")
            data = path.read_bytes()
            result["artifacts"][encoding] = {"file": name, "bytes": len(data), "integrity": integrity(data)}
            with (output / name).open("xb") as destination:
                destination.write(data)
        with (output / (basename + ".json")).open("x") as destination:
            destination.write(json.dumps(result, indent=2) + "\n")
        return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", choices=PROFILES)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    print(json.dumps(build(args.manifest, args.runtime, args.output), indent=2))
