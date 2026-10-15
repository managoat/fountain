import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
from urllib.request import Request

from check_external_links import PublicRedirects, check, links


class ExternalLinksTest(unittest.TestCase):
    def test_links_include_references_and_autolinks_but_not_code_or_other_hosts(self):
        source = '''[`app`](https://github.com/managoat/demos#readme)
[app]: https://github.com/managoat/managoat
<https://github.com/managoat/docs>
`https://github.com/example/placeholder`
```bash
https://github.com/example/code
~~~
```
[elsewhere](https://example.com)
[lookalike](https://github.com.example.com/private)
'''
        self.assertEqual(list(links(source)), [
            (1, "https://github.com/managoat/demos"),
            (2, "https://github.com/managoat/managoat"),
            (3, "https://github.com/managoat/docs"),
        ])

    def test_redirects_cannot_expand_the_host_allowlist(self):
        handler = PublicRedirects()
        request = Request("https://github.com/old/repo")
        with self.assertRaises(ValueError):
            handler.redirect_request(request, None, 302, "", {}, "http://localhost/private")
        redirected = handler.redirect_request(request, None, 301, "", {}, "https://github.com/new/repo")
        self.assertEqual(redirected.full_url, "https://github.com/new/repo")

    @patch("check_external_links.build_opener")
    def test_a_private_or_missing_repo_is_a_failure_without_auth(self, build):
        build.return_value.open.side_effect = HTTPError("url", 404, "Not Found", {}, None)
        self.assertEqual(check("https://github.com/private/repo"), "HTTP 404")
        request = build.return_value.open.call_args.args[0]
        self.assertFalse(request.has_header("Authorization"))
        self.assertEqual(build.return_value.open.call_count, 1)

    @patch("check_external_links.time.sleep")
    @patch("check_external_links.build_opener")
    def test_transient_failure_retries_then_accepts_success(self, build, sleep):
        response = Mock(status=200)
        context = Mock()
        context.__enter__ = Mock(return_value=response)
        context.__exit__ = Mock(return_value=False)
        build.return_value.open.side_effect = [HTTPError("url", 503, "Unavailable", {}, None), context]
        self.assertIsNone(check("https://github.com/public/repo"))
        sleep.assert_called_once_with(1)
