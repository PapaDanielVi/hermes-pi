# Browser Search Skill

## Overview

This skill teaches Hermes how to use the local browser server for web search and content fetching. The browser server runs on `localhost:5555` and uses Playwright with Chromium to perform searches and fetch web content.

## API Endpoints

### Search
- **Endpoint**: `POST /search`
- **Body**: `{"query": "your search terms", "count": 10}`
- **Returns**: JSON array of search results with title, URL, and snippet

### Fetch
- **Endpoint**: `POST /fetch`
- **Body**: `{"url": "https://example.com"}`
- **Returns**: `{"content": "extracted text content", "title": "page title"}`

### Health
- **Endpoint**: `GET /health`
- **Returns**: `{"status": "healthy"}` or service error

## When to Use This Tool

Use the browser tool for:
1. Current events or recent news
2. Verifying facts that may have changed
3. Looking up documentation for libraries/tools
4. Searching for specific technical information
5. Fetching content from URLs directly

## How to Call

The browser server is called via the `http_request` tool configured in config.yaml. Use it when you need to:

- Search the web for information: Make a POST to `http://localhost:5555/search` with your query
- Get the content of a specific page: Make a POST to `http://localhost:5555/fetch` with the URL

## Error Handling

If the browser server is unavailable or returns an error:
- The search will fail gracefully
- Fall back to using your training knowledge with a disclaimer about potential staleness
- Report the failure to the user if the information is critical