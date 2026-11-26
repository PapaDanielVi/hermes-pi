#!/usr/bin/env python3
"""Local Playwright + stealth HTTP fallback server for Hermes Agent.

Exposes /health, /search (DuckDuckGo HTML), and /fetch (rendered page text) on
loopback only (127.0.0.1). Chromium launches lazily on the first request and
shuts down automatically after an idle period so it does not hold Raspberry Pi
RAM while Hermes uses its built-in web_search / browser_exec tools.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import parse_qs, quote_plus, unquote, urlparse

import uvicorn
from fastapi import FastAPI, HTTPException
from playwright.async_api import async_playwright
from pydantic import BaseModel, Field

logger = logging.getLogger("hermes-browser")

BROWSER_HOST = os.environ.get("BROWSER_SERVER_HOST", "127.0.0.1")
BROWSER_PORT = int(os.environ.get("BROWSER_SERVER_PORT", "5555"))
IDLE_TIMEOUT_SECONDS = int(os.environ.get("BROWSER_IDLE_TIMEOUT", "300"))
MAX_CONTENT_CHARS = int(os.environ.get("BROWSER_MAX_CONTENT_CHARS", "50000"))
MAX_SEARCH_COUNT = 20
NAVIGATION_TIMEOUT_MS = 30000

CHROMIUM_ARGS = [
    "--no-sandbox",
    "--disable-setuid-sandbox",
    "--disable-dev-shm-usage",
    "--disable-accelerated-2d-canvas",
    "--disable-gpu",
    "--window-size=1280,800",
]


class SearchRequest(BaseModel):
    """Request body for search endpoint."""

    query: str = Field(..., min_length=1, max_length=500)
    count: int = Field(default=10, ge=1, le=MAX_SEARCH_COUNT)


class FetchRequest(BaseModel):
    """Request body for fetch endpoint."""

    url: str = Field(..., min_length=1, max_length=2048)


class FetchResponse(BaseModel):
    """Response body for fetch endpoint."""

    title: str
    content: str


class SearchResult(BaseModel):
    """Single search result."""

    title: str
    url: str
    snippet: str


class SearchResponse(BaseModel):
    """Response body for search endpoint."""

    results: list[SearchResult]


def get_chromium_path() -> str | None:
    """Find the system Chromium binary path on Raspberry Pi, or None for Playwright's bundle."""
    for path in (
        "/usr/bin/chromium-browser",
        "/usr/bin/chromium",
        "/usr/bin/google-chrome",
    ):
        if os.path.exists(path):
            return path
    return None


async def apply_stealth(page: Any) -> None:
    """Apply playwright-stealth across both v2 (Stealth class) and v1 (stealth_async) APIs."""
    try:
        from playwright_stealth import Stealth  # type: ignore[attr-defined]

        await Stealth().apply_stealth_async(page)
        return
    except ImportError:
        pass
    except Exception as exc:
        logger.debug("playwright-stealth v2 failed: %s", exc)

    try:
        from playwright_stealth import stealth_async  # type: ignore[attr-defined]

        await stealth_async(page)
    except Exception as exc:
        logger.debug("playwright-stealth v1 unavailable: %s", exc)


def unwrap_ddg_url(raw_url: str) -> str:
    """Extract the real destination URL from DuckDuckGo's /l/?uddg=... redirect links."""
    if not raw_url:
        return ""
    candidate = f"https:{raw_url}" if raw_url.startswith("//") else raw_url
    parsed = urlparse(candidate)
    if parsed.netloc.endswith("duckduckgo.com") and parsed.path.startswith("/l/"):
        uddg = parse_qs(parsed.query).get("uddg")
        if uddg and uddg[0]:
            return unquote(uddg[0])
    return candidate


def validate_http_url(raw_url: str) -> str:
    """Require an http or https URL so local file:// or javascript: schemes are rejected."""
    parsed = urlparse(raw_url.strip())
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise HTTPException(
            status_code=400,
            detail="URL must use http:// or https:// and include a hostname.",
        )
    return raw_url.strip()


class LazyBrowserManager:
    """Owns one async Playwright Chromium instance, launched lazily and reaped when idle."""

    def __init__(self) -> None:
        self._playwright: Any = None
        self._browser: Any = None
        self._lock = asyncio.Lock()
        self._last_used = 0.0
        self._active_requests = 0
        self._reaper_task: asyncio.Task[None] | None = None

    def start_reaper(self) -> None:
        if self._reaper_task is None:
            self._reaper_task = asyncio.create_task(self._reaper_loop())

    async def _reaper_loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(30)
                async with self._lock:
                    if (
                        self._browser is not None
                        and self._active_requests == 0
                        and (time.monotonic() - self._last_used) >= IDLE_TIMEOUT_SECONDS
                    ):
                        logger.info("Closing idle Chromium instance to free RAM.")
                        await self._close_unlocked()
        except asyncio.CancelledError:
            pass

    async def _ensure_browser_unlocked(self) -> Any:
        if self._browser is not None and self._browser.is_connected():
            return self._browser
        await self._close_unlocked()
        self._playwright = await async_playwright().start()
        launch_kwargs: dict[str, Any] = {"headless": True, "args": CHROMIUM_ARGS}
        chromium_path = get_chromium_path()
        if chromium_path:
            launch_kwargs["executable_path"] = chromium_path
        self._browser = await self._playwright.chromium.launch(**launch_kwargs)
        return self._browser

    async def _close_unlocked(self) -> None:
        if self._browser is not None:
            try:
                await self._browser.close()
            except Exception:
                pass
            self._browser = None
        if self._playwright is not None:
            try:
                await self._playwright.stop()
            except Exception:
                pass
            self._playwright = None

    @asynccontextmanager
    async def page(self):
        async with self._lock:
            browser = await self._ensure_browser_unlocked()
            self._active_requests += 1
            self._last_used = time.monotonic()

        context = None
        page = None
        try:
            context = await browser.new_context(viewport={"width": 1280, "height": 800})
            page = await context.new_page()
            await apply_stealth(page)
            yield page
        finally:
            if page is not None:
                try:
                    await page.close()
                except Exception:
                    pass
            if context is not None:
                try:
                    await context.close()
                except Exception:
                    pass
            async with self._lock:
                self._active_requests = max(0, self._active_requests - 1)
                self._last_used = time.monotonic()

    async def shutdown(self) -> None:
        if self._reaper_task is not None:
            self._reaper_task.cancel()
            try:
                await self._reaper_task
            except asyncio.CancelledError:
                pass
            self._reaper_task = None
        async with self._lock:
            await self._close_unlocked()


manager = LazyBrowserManager()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Start the idle reaper on startup and tear down Chromium cleanly on exit."""
    manager.start_reaper()
    try:
        yield
    finally:
        await manager.shutdown()


app = FastAPI(
    title="Hermes Browser Server",
    lifespan=lifespan,
)


@app.get("/health")
async def health() -> dict[str, str]:
    """Health check endpoint."""
    return {"status": "healthy"}


@app.post("/search", response_model=SearchResponse)
async def search(request: SearchRequest) -> SearchResponse:
    """Perform a DuckDuckGo web search using local Playwright Chromium."""
    encoded_query = quote_plus(request.query.strip())
    search_url = f"https://duckduckgo.com/html/?q={encoded_query}"

    try:
        async with manager.page() as page:
            await page.goto(
                search_url,
                wait_until="domcontentloaded",
                timeout=NAVIGATION_TIMEOUT_MS,
            )
            results: list[SearchResult] = []
            result_elements = await page.query_selector_all("a.result__a")

            for element in result_elements[: request.count]:
                try:
                    title = (await element.inner_text()).strip()
                    raw_href = await element.get_attribute("href")
                    url = unwrap_ddg_url(raw_href or "")
                    if not url:
                        continue
                    snippet = await element.evaluate(
                        "el => el.closest('.result')?.querySelector('.result__snippet')?.innerText || ''"
                    )
                    results.append(
                        SearchResult(
                            title=title,
                            url=url,
                            snippet=(snippet or "").strip(),
                        )
                    )
                except Exception:
                    continue

            return SearchResponse(results=results)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Search failed: {exc}") from exc


@app.post("/fetch", response_model=FetchResponse)
async def fetch(request: FetchRequest) -> FetchResponse:
    """Fetch and extract readable text content from an HTTP(S) URL."""
    url = validate_http_url(request.url)

    try:
        async with manager.page() as page:
            await page.goto(
                url,
                wait_until="domcontentloaded",
                timeout=NAVIGATION_TIMEOUT_MS,
            )
            try:
                await page.wait_for_load_state("networkidle", timeout=5000)
            except Exception:
                # Some pages keep long-polling connections open; domcontentloaded is enough.
                pass

            title = (await page.title()) or ""
            content = await page.evaluate(
                """() => {
                    document.querySelectorAll('script, style, noscript').forEach(el => el.remove());
                    const main = document.querySelector('main') ||
                                 document.querySelector('article') ||
                                 document.querySelector('[role="main"]') ||
                                 document.querySelector('.content') ||
                                 document.body;
                    return main ? main.innerText : (document.body ? document.body.innerText : '');
                }"""
            )
            text = (content or "").strip()
            if len(text) > MAX_CONTENT_CHARS:
                text = text[:MAX_CONTENT_CHARS] + "\n\n[truncated]"
            return FetchResponse(title=title.strip(), content=text)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Fetch failed: {exc}") from exc


if __name__ == "__main__":
    uvicorn.run(app, host=BROWSER_HOST, port=BROWSER_PORT)
