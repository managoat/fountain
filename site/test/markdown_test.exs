defmodule Site.MarkdownTest do
  @moduledoc """
  The manual's renderer against hostile input. The pages are reviewed in this
  repository, but a bad paste must still not become live script: these are the
  Fountain #323 cases that `Managoat.Docs.Markdown` carried, kept with the
  renderer when it moved here.
  """
  use ExUnit.Case, async: true

  import Site.Markdown, only: [to_html: 1]

  describe "safe URLs pass through" do
    test "https, http and mailto links survive" do
      html = to_html("[a](https://x.com) [b](http://x.com) [c](mailto:a@b.c)")
      assert html =~ ~s(href="https://x.com")
      assert html =~ ~s(href="http://x.com")
      assert html =~ ~s(href="mailto:a@b.c")
    end

    test "relative and fragment links survive" do
      html = to_html("[a](/docs) [b](docs/page.md) [c](#section) [d](?q=a:b)")
      assert html =~ ~s(href="/docs")
      assert html =~ ~s(href="docs/page.md")
      assert html =~ ~s(href="#section")
      assert html =~ ~s(href="?q=a:b")
    end

    test "a colon later in a relative path is not treated as a scheme" do
      assert to_html("[a](/search?q=foo:bar)") =~ ~s(href="/search?q=foo:bar")
    end

    test "http images survive" do
      assert to_html("![i](https://x.com/i.png)") =~ ~s(src="https://x.com/i.png")
    end

    # The check is an allowlist, so normalisation is observable only in the
    # allow direction: HTTPS: is on the list only because of the downcase.
    test "case-folding is for the check only: uppercase safe schemes keep their href" do
      assert to_html("[x](HTTPS://x.com)") =~ ~s(href="HTTPS://x.com")
      assert to_html("[x](MailTo:a@b.c)") =~ ~s(href="MailTo:a@b.c")
    end

    test "a ref-encoded tab inside a safe scheme keeps the href" do
      assert to_html("[x](ht&#9;tps://x.com)") =~ "href"
    end
  end

  describe "unsafe URLs are dropped" do
    test "javascript: links lose their href but keep their text" do
      html = to_html("[click](javascript:alert&#40;1&#41;)")
      refute html =~ "javascript"
      refute html =~ "href"
      assert html =~ "click"
    end

    test "uppercase and mixed-case schemes are caught" do
      refute to_html("[x](JAVASCRIPT:alert(1))") =~ "href"
      refute to_html("[x](JaVaScRiPt:alert(1))") =~ "href"
    end

    test "character references cannot smuggle a scheme" do
      refute to_html("[x](&#106;avascript:alert(1))") =~ "href"
      refute to_html("[x](&#x6A;avascript:alert(1))") =~ "href"
      refute to_html("[x](javascript&colon;alert(1))") =~ "href"
      refute to_html("[x](javascript&amp;colon;alert(1))") =~ "href"
    end

    test "embedded whitespace cannot split the scheme" do
      refute to_html("[x](java\tscript:alert(1))") =~ "href"
      refute to_html("[x](&#9;javascript:alert(1))") =~ "href"
    end

    test "data: and vbscript: links are dropped" do
      refute to_html("[x](data:text/html;base64,PHNjcmlwdD4=)") =~ "href"
      refute to_html("[x](vbscript:msgbox)") =~ "href"
    end

    test "data: image sources are dropped, leaving the alt text" do
      html = to_html("![diagram](data:image/svg+xml;base64,AAAA)")
      refute html =~ "<img"
      assert html =~ "diagram"
    end

    test "mailto is not an allowed image scheme" do
      refute to_html("![i](mailto:a@b.c)") =~ "src"
    end
  end

  describe "raw HTML is neutralised" do
    test "block-level script tags are escaped, not emitted" do
      html = to_html("<script>alert(1)</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "block-level event-handler HTML is escaped" do
      html = to_html("para\n\n<img src=x onerror=alert(1)>\n\nend")
      refute html =~ "<img"
      assert html =~ "&lt;img"
    end

    test "nested elements and attributes are escaped" do
      html = to_html(~s(<div class="x"><span onclick=x>hi</span></div>))
      refute html =~ "<div"
      refute html =~ "<span"
      assert html =~ "hi"
    end

    test "inline HTML stays escaped" do
      html = to_html("text <b onclick=x>bold</b> end")
      refute html =~ "<b "
      assert html =~ "&lt;b"
    end

    test "an HTML comment block is dropped, not shown as text" do
      html = to_html("<!-- The changelog lives in the repo root -->\n\n# Changelog")
      refute html =~ "changelog lives"
      assert html =~ ~s(<h1 id="changelog">Changelog)
    end

    test "markup trailing a comment on the same line is still escaped" do
      html = to_html("<!-- x --><script>alert(1)</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "a figure/svg block is kept, scrubbed" do
    test "a clean diagram renders as markup" do
      html =
        to_html(~s|intro

<figure>
<svg viewBox="0 0 10 10"><rect fill="#b3760f"/><text fill="currentColor">hi</text></svg>
<figcaption>cap</figcaption>
</figure>

end|)

      assert html =~ ~s|<svg viewBox="0 0 10 10">|
      assert html =~ "<figcaption>cap</figcaption>"
      refute html =~ "&lt;svg"
    end

    test "script, style and foreignObject are stripped" do
      html =
        to_html(
          ~s|<figure><svg><script>alert(1)</script><style>x{}</style><foreignObject><b>y</b></foreignObject><rect/></svg></figure>|
        )

      refute html =~ "<script"
      refute html =~ "<style"
      refute html =~ "foreignObject"
      assert html =~ "<rect/>"
    end

    test "event handlers and javascript/data URLs are stripped" do
      html =
        to_html(
          ~s|<figure><svg onload="steal()"><a xlink:href="javascript:alert(1)">x</a><image href="data:text/html,evil"/></svg></figure>|
        )

      refute html =~ "onload"
      refute html =~ "javascript:"
      refute html =~ "data:text/html"
      assert html =~ "<svg>"
    end
  end

  describe "headings" do
    test "carry GFM-style ids so #anchor links resolve" do
      html = to_html("## Back up `MASTER_SECRETS_KEY`\n\n## Crons: alerting")
      assert html =~ ~s(<h2 id="back-up-master_secrets_key">)
      assert html =~ ~s(<h2 id="crons-alerting">)
    end
  end

  describe "fenced code" do
    test "a labelled fence is coloured and keeps its language" do
      html = to_html("```elixir\ndef run(x), do: x\n```")
      assert html =~ ~s(class="language-elixir")
      assert html =~ "style=\"color:"
    end

    test "an alias highlights as its language" do
      assert to_html("```sh\necho hi\n```") =~ ~s(class="language-bash")
      assert to_html("```ts\nconst x = 1;\n```") =~ ~s(class="language-typescript")
    end

    test "an unlabelled fence and a plaintext one render as plaintext" do
      assert to_html("```\njust some output\n```") =~ ~s(class="language-plaintext")
      assert to_html("```promql\nup == 0\n```") =~ ~s(class="language-plaintext")
    end

    test "an info string with more than a language uses the first word" do
      assert to_html(~s(```bash title="setup"\necho hi\n```)) =~ ~s(class="language-bash")
    end

    test "a language Lumis does not know fails the render rather than going plain" do
      assert_raise ArgumentError, ~r/not a Lumis language/, fn ->
        to_html("```notalanguage\nkeep me\n```")
      end
    end

    test "the closing fence does not leave a trailing blank line" do
      html = to_html("```ts\nconst x = 1;\n```")
      assert html =~ ~s(data-line="1")
      refute html =~ ~s(data-line="2")
    end

    test "code is escaped, so a fence cannot break out of its block" do
      html = to_html("```html\n</code></pre><script>alert(1)</script>\n```")
      refute html =~ "<script"
      assert html =~ "&lt;"
      assert length(String.split(html, "<pre")) == 2
    end
  end
end
