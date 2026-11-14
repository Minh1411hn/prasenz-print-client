---
name: writing-durable-comments
description: Use when writing or reviewing a code comment or docstring, especially right after fixing a bug, debugging, or refactoring, before committing
---

# Writing Durable Comments

## Overview

A comment is read by someone with zero knowledge of this conversation. Anything that only makes
sense because of what "we" just did — the investigation, the alternative that got rejected, the
contrast with how the code used to look — belongs in the commit message or PR description, not in
the code.

## The Test

Before writing a comment, ask: would this sentence make sense to someone who never saw the
previous version of this code and never talked to the user?

- Yes → keep it (durable fact: invariant, constraint, workaround for a bug in external code)
- No → cut it, or move it to the commit message

## Before / After

Real example — a docstring written immediately after fixing a hang caused by mutating a FastAPI
app's routes from inside `BaseHTTPMiddleware`:

```python
# Before — narrates the investigation, not the code
class LazyMountASGIMiddleware:
    """Mount the portal for a request's path if not already mounted

    A plain ASGI wrapper (not @app.middleware/BaseHTTPMiddleware) so mounting a portal's
    routes on the app doesn't happen from inside the app's own middleware/request stack.
    BaseHTTPMiddleware runs downstream calls through an anyio task group + stream, which
    doesn't tolerate mutating the app's own routing table from within its own dispatch -
    it silently hangs subsequent requests instead of erroring.
    """
```

```python
# After — states the constraint and its consequence, nothing else
class LazyMountASGIMiddleware:
    """Mount the portal for a request's path on first hit, outside Starlette's middleware stack

    Must stay a plain ASGI callable, not @app.middleware/BaseHTTPMiddleware: mutating
    app.routes from inside BaseHTTPMiddleware's own dispatch hangs later requests instead
    of erroring.
    """
```

Kept: the invariant ("must stay a plain ASGI callable") and the concrete failure mode if violated —
that's what protects the next editor from reintroducing the bug. Cut: the "not X" contrast framing
and the anyio/stream mechanism trivia — neither is needed to safely maintain this code.

## Red Flags

- "now", "instead of", "used to", "previously", "no longer"
- "the user", "this session", "we found", "turns out"
- Explaining what the code *isn't* more than what it *is*
- A sentence that would be a fine PR description bullet but a bad comment

## Quick Reference

| Ask | Keep in the comment if... |
|---|---|
| Would this confuse someone with no chat context? | No |
| Is this narrating a fix rather than stating a fact? | No |
| Could this be a commit message bullet instead? | No |
