#!/usr/bin/env python3
"""Check public GitHub links in the manual and contributor guide, without auth."""
from concurrent.futures import ThreadPoolExecutor
import html
from pathlib import Path
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urldefrag, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[2]
# Scope network requests deliberately; examples and other vendors are not gates.
HOSTS = {"github.com"}


def links(markdown):
    fence = None
    for number, line in enumerate(markdown.splitlines(), 1):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if marker:
            chars = marker[1]
            if fence is None:
                fence = chars
            elif chars[0] == fence[0] and len(chars) >= len(fence):
                fence = None
            continue
        if fence:
            continue
        line = re.sub(r"(`+).*?\1", "", line)
        for match in re.finditer(r'https://[^\s<>\)\]"\']+', line):
            url = urldefrag(html.unescape(match[0].rstrip(".,;:!?")))[0]
            if urlsplit(url).hostname in HOSTS:
                yield number, url


class PublicRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urlsplit(newurl)
        if target.scheme != "https" or target.hostname not in HOSTS:
            raise ValueError(f"redirect left the allowed hosts: {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check(url):
    opener = build_opener(PublicRedirects())
    request = Request(url, headers={"User-Agent": "Fountain-docs-link-check"})
    for attempt in range(3):
        try:
            with opener.open(request, timeout=15) as response:
                if response.status != 200:
                    return f"HTTP {response.status}"
                return None
        except HTTPError as error:
            reason = f"HTTP {error.code}"
            if error.code != 429 and error.code < 500:
                return reason
        except (URLError, TimeoutError, ValueError) as error:
            reason = str(error)
        if attempt < 2:
            time.sleep(2 ** attempt)
    return reason


def main():
    sources = [ROOT / "CLAUDE.md"]
    for directory in [ROOT / "docs"]:
        sources.extend(sorted(directory.rglob("*.md")))
    references = {}
    for path in sources:
        for number, url in links(path.read_text()):
            references.setdefault(url, []).append(f"{path.relative_to(ROOT)}:{number}")
    if not references:
        raise SystemExit("No allowlisted documentation links found")
    failed = 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        for url, error in zip(references, pool.map(check, references)):
            if error:
                failed += 1
                print(f"{error}: {url}\n  " + ", ".join(references[url]), file=sys.stderr)
    print(f"Checked {len(references)} public GitHub links; {failed} failed")
    return int(failed > 0)


if __name__ == "__main__":
    sys.exit(main())
