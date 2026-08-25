# Known issues

Things that work here but would not work for someone installing this gem.
Recorded rather than fixed — each one waits on community feedback before it is
worth the work.

## Agents launched by `mimic` have no web access out of the box

**Status:** open, deferred. Not a problem for this machine.

**Who it affects:** anyone but the author.

### What happens

`mimic claude` denies `WebSearch` and `WebFetch` (`Agent::Claude::DENIED_TOOLS`)
and wires in whatever `~/.mimic/mcp-servers.json` names. On a fresh install that
file does not exist, so the agent launches with no web tools at all and no hint
that anything is missing.

The deny is correct on its own terms: both are Anthropic server-executed tools,
llama.cpp's `/v1/messages` bridge has no implementation for them (server log:
`unsupported Responses tool type 'web_search'`), and they return zero results
rather than failing. Denying makes the failure visible. But the replacement the
deny assumes — an MCP server doing the crawling — is something the user has to
supply, and nothing tells them so at the point they hit it.

### Why it is invisible here

The author's server is `c4ai_mcp`, which lives in a private dotfiles repo at
`~/studio/dotfile/claude-share/c4ai_mcp` and is importable as
`python -m c4ai_mcp.fastmcp_server`. Until 2026-08-18 that command was hardcoded
into `Agent::Claude` and written into every user's isolated `.claude.json`
unconditionally — so the gem shipped a broken reference to a package no
installer could obtain. Making it opt-in fixed the wrong reference and exposed
this gap underneath it.

### Debug notes

`c4ai_mcp` is small — 387 lines over three files, none of it MCP protocol:

| file | lines | contents |
| --- | --- | --- |
| `fastmcp_server.py` | 148 | six `@mcp.tool` functions, each a signature, a docstring and one delegating call |
| `crawler.py` | 128 | `crawl4ai` async wrapper: `crawl_single`, `crawl_site`, `crawl_batch` |
| `searcher.py` | 111 | `ddgs` wrapper plus an image downloader |

Roughly half of `fastmcp_server.py` is docstrings, which are not documentation —
FastMCP derives each MCP tool schema from the type hints plus the docstring.
There is no JSON-RPC, stdio framing or capability negotiation anywhere in it;
`FastMCP` owns all of that.

Its declared dependencies are the real weight: `crawl4ai`, `playwright`,
`fastmcp`, `ddgs`, `nest-asyncio`, `anyio`, `requests`. Playwright means browser
binaries, not just wheels.

Only the crawling half needs any of that. `searcher.py` imports `ddgs` and
`requests` and nothing else — no crawl4ai, no browser.

### Options considered

**Vendor an equivalent MCP server into this repo as a plugin.** Acceptable in
principle. The blocker is not the code, which is small, but that it needs its
own install-and-use documentation — a Python package shipped inside a Ruby gem
is a second toolchain the README currently does not mention.

**Reimplement it in Ruby.** No crawl4ai Ruby client exists; RubyGems has nothing
under that name. crawl4ai's core is `AsyncWebCrawler` driving Playwright, so a
port means reimplementing browser automation rather than wrapping a library.
The `searcher.py` half would be straightforward Ruby; the `crawler.py` half
would not.

**Call crawl4ai over HTTP.** It self-hosts a server (default port 11235) with
`POST /crawl`, `POST /html`, `POST /execute_js`, `/md`, job endpoints and its
own `/mcp`, all reachable from `Net::HTTP`. This moves the Python dependency
into a container rather than removing it.

**Point users at `mcp-server-fetch`.** The MCP project's own reference server
(`modelcontextprotocol/servers`, `src/fetch`), configured as
`{"fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}}`. No API key, no
account, no install step beyond `uv`. One tool — `fetch(url, max_length,
start_index, raw)` — doing an HTTP GET and an HTML-to-markdown conversion, with
chunked re-reads through `start_index`. It takes `--proxy-url`, `--user-agent`
and `--ignore-robots-txt`; robots.txt is obeyed by default for model-initiated
calls. Upstream carries a caution that it can reach local and internal IP
addresses.

The name collides with something this repo denies, so: Claude Code's built-in
`WebFetch` is Anthropic server-executed and unusable here. `mcp-server-fetch` is
unrelated — a local stdio subprocess, the same shape as c4ai, whose results come
back as ordinary tool results to whatever model is behind the `/v1/messages`
bridge.

It is a reference, not an equivalent. It has no search, so a model holding no
other web tool has no way to obtain a URL to pass it. It does no JS rendering,
so a single-page app returns its empty shell. It reads one URL per call, with no
`crawl_site` or `crawl_batch`. The 5000-character default truncation turns a
long page into several round trips, which a local model pays for in context.
Keyless search has no official server at all — `nickclyde/duckduckgo-mcp-server`
and `zhsama/duckduckgo-mcp-server` are community ones. Every vendor server
(Firecrawl, Tavily, Exa, Bright Data, Apify) wants an account and a key.

**Do nothing beyond documenting it.** Current choice. `README.md` explains the
opt-in file and shows the `mcpServers` shape, so a user who wants web access has
a documented path even though the gem picks no server for them.

### Revisit when

Someone outside this machine reports that agents launched by `mimic` cannot
reach the web, or asks which MCP server to use.
