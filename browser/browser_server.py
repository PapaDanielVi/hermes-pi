#!/usr/bin/env python3
"""
Browser server for Hermes Agent - FastAPI + Playwright with stealth for web search/fetch.

This server provides HTTP endpoints for web search and content fetching using a local
Chromium browser instance. It uses playwright-stealth to bypass bot protections.
"""

import os
import sys
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# Playwright imports
from playwright.sync_api import sync_playwright

# Default port from environment
BROWSER_PORT = int(os.environ.get("BROWSER_SERVER_PORT", "5555"))


class SearchRequest(BaseModel):
    """Request body for search endpoint."""

    query: str
    count: int = 10


class FetchRequest(BaseModel):
    """Request body for fetch endpoint."""

    url: str


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


# Global Playwright browser instance
browser: Any = None
playwright: Any = None


def get_chromium_path() -> str:
    """Find the Chromium binary path on Raspberry Pi."""
    chromium_paths = [
        "/usr/bin/chromium-browser",
        "/usr/bin/chromium",
        "/usr/bin/google-chrome",
    ]
    for path in chromium_paths:
        if os.path.exists(path):
            return path
    # Fallback to Playwright's bundled Chromium
    return "chromium"


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage browser lifecycle."""
    global browser, playwright

    playwright = sync_playwright().start()
    chromium_path = get_chromium_path()

    # Detect if using system Chromium or Playwright's bundled version
    if chromium_path != "chromium":
        browser = playwright.chromium.launch(
            executable_path=chromium_path,
            headless=True,
            args=[
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
                "--disable-accelerated-2d-canvas",
                "--disable-gpu",
                "--window-size=1920,1080",
            ],
        )
    else:
        browser = playwright.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-dev-shm-usage",
                "--disable-accelerated-2d-canvas",
                "--disable-gpu",
                "--window-size=1920,1080",
            ],
        )

    yield

    if browser:
        browser.close()
    if playwright:
        playwright.stop()


app = FastAPI(
    title="Hermes Browser Server",
    lifespan=lifespan,
)


@app.get("/health")
def health() -> dict[str, str]:
    """Health check endpoint."""
    return {"status": "healthy"}


@app.post("/search", response_model=SearchResponse)
def search(request: SearchRequest) -> SearchResponse:
    """
    Perform a web search using DuckDuckGo.

    Uses Playwright with stealth to avoid bot detection.
    """
    if not browser:
        raise HTTPException(status_code=503, detail="Browser not initialized")

    try:
        page = browser.new_page()
        # DuckDuckGo search URL
        search_url = f"https://duckduckgo.com/html/?q={request.query}"
        page.goto(search_url, wait_until="networkidle", timeout=30000)

        # Extract search results
        results = []
        result_elements = page.query_selector_all("a.result__a")

        for i, element in enumerate(result_elements[: request.count]):
            try:
                title = element.inner_text()
                url = element.get_attribute("href")
                if url:
                    # Get snippet from sibling element
                    snippet = ""
                    snippet_elem = element.evaluate(
                        "el => el.closest('.result').querySelector('.result__snippet')?.innerText || ''"
                    )
                    results.append(
                        SearchResult(title=title, url=url, snippet=snippet_elem or "")
                    )
            except Exception:
                continue

        page.close()
        return SearchResponse(results=results)

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")


@app.post("/fetch", response_model=FetchResponse)
def fetch(request: FetchRequest) -> FetchResponse:
    """
    Fetch and extract text content from a URL.

    Uses Playwright to load the page and extract readable content.
    """
    if not browser:
        raise HTTPException(status_code=503, detail="Browser not initialized")

    try:
        page = browser.new_page()
        page.goto(request.url, wait_until="networkidle", timeout=30000)

        # Extract page title
        title = page.title() or ""

        # Extract main text content - try multiple selectors
        content = page.evaluate(
            """() => {
                // Remove script and style elements
                document.querySelectorAll('script, style').forEach(el => el.remove());

                // Try to get main content
                const main = document.querySelector('main') ||
                             document.querySelector('article') ||
                             document.querySelector('.content') ||
                             document.body;

                return main ? main.innerText : document.body.innerText;
            }"""
        )

        page.close()
        return FetchResponse(title=title, content=content or "")

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Fetch failed: {str(e)}")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=BROWSER_PORT)