---
name: local-browser
description: Web search, page extraction, and local Playwright stealth browser fallback on Raspberry Pi
---

# Web Search and Local Browser Usage

## Preferred tools (use these first)

1. **`web_search` and `web_extract`**: Fast keyless web search and article extraction with built-in caching. Use these first for news, documentation, fact lookups, and reading static pages.
2. **`browser_exec`**: Full headless Chromium inside the container over CDP. Use this when you need to interact with a real page (click buttons, fill forms, scroll JS-rendered apps, inspect the DOM, or capture screenshots).

## Local Playwright stealth fallback (`http://127.0.0.1:{{BROWSER_SERVER_PORT}}`)

If `web_search` hits rate limits or `web_extract` is blocked by bot checks, a local Playwright + stealth Chromium HTTP service runs on loopback port `{{BROWSER_SERVER_PORT}}`. Call it via the `terminal` tool with `curl`:

### Search (DuckDuckGo via local Chromium)

```bash
curl -sS -X POST http://127.0.0.1:{{BROWSER_SERVER_PORT}}/search \
  -H 'Content-Type: application/json' \
  -d '{"query": "raspberry pi 5 news", "count": 5}'
```

Returns `{"results": [{"title": "...", "url": "...", "snippet": "..."}]}`.

### Fetch readable text from a URL

```bash
curl -sS -X POST http://127.0.0.1:{{BROWSER_SERVER_PORT}}/fetch \
  -H 'Content-Type: application/json' \
  -d '{"url": "https://example.com"}'
```

Returns `{"title": "...", "content": "..."}`.

### Health check

```bash
curl -sS http://127.0.0.1:{{BROWSER_SERVER_PORT}}/health
```

## Notes

- Prefer `web_search` / `web_extract` / `browser_exec` before calling the local HTTP fallback.
- When passing dynamic queries or URLs through `terminal`, build the JSON body with `jq -n --arg q "$Q" '{query: $q, count: 5}'` so quotes and special characters are escaped properly.
- If both built-in web tools and the local fallback fail, tell the user plainly instead of guessing.
