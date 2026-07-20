# Desktop handoff contracts

Status: adapter contract selected on 2026-07-18; real launches remain in the M6 acceptance matrix.

## Result

Go2Codex constructs desktop URLs with `URLComponents` and one `URLQueryItem`, asks `NSWorkspace.urlForApplication(toOpen:)` for the Launch Services handler, and requires that handler's bundle identifier to match the selected target (`com.openai.codex` or `com.anthropic.claudefordesktop`). It then passes that exact verified application URL to the asynchronous `NSWorkspace.open(_:withApplicationAt:configuration:)` API, instead of asking Launch Services to resolve the default handler a second time. It never resolves an application by display name or a guessed path, and a different application claiming the same scheme is treated as unavailable.

| Agent Target | Scheme | Host | Path | Query | Minimal URL |
| --- | --- | --- | --- | --- | --- |
| Codex App | `codex` | `new` | empty | `path` | `codex://new?path=<Workspace>` |
| Claude Desktop Code | `claude` | `code` | `/new` | `folder` | `claude://code/new?folder=<Workspace>` |

Only the absolute Workspace path is supplied. Go2Codex never sends `prompt`, `q`, `file`, `originUrl`, or any other target-owned field. `URLQueryItem` performs one encoding pass; hand-built query strings and pre-percent-encoded values are forbidden.

## Evidence

The installed Codex client is displayed as ChatGPT but declares bundle identifier `com.openai.codex` and the `codex` scheme. In version 26.715.21425 build 5488, its signed application archive parses host `new`, reads query key `path`, resolves it to an absolute path, requires a directory, selects it as the Workspace root, and focuses a fresh composer without submitting a prompt. The inspected archive SHA-256 was `5db4c67090c0521fa717e83e46cb0a6175cb6c16fb89064223753bdf05cff0aa`; route parsing is in `.vite/build/window-all-closed-DXvqe7lL.js` and dispatch is in `.vite/build/main-hw0RxS4P.js`. No public OpenAI page documenting this route was found, so publication must revalidate it against the release client rather than presenting it as a public API.

Anthropic documents `claude://code/new?folder=<absolute URL-encoded path>` in [Open Claude Desktop with a link](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link). The installed Claude client declares the `claude` scheme and routes this form to a new Code draft. Its separate `claude-cli` URL-handler helper is not the desktop target and is deliberately ignored.

Read-only Launch Services lookup on the development Mac resolved `codex` to the ChatGPT bundle and `claude` to the Claude bundle even though their names and locations differ. A fabricated scheme returned no handler.

## Ownership boundary

The adapter has four local stages:

1. validate that Workspace is an accessible directory;
2. construct the fixed URL;
3. require the registered Launch Services handler to have the selected target's exact bundle identifier;
4. submit the URL specifically through the verified handler application URL and await the open completion handler.

A failure in any of these stages is a pre-handoff Launch Failure. A successful completion means only that Launch Services accepted delivery. Claude may then present its own trust confirmation; either target may reject a route, be cancelled, or fail internally. Go2Codex does not poll, infer, retry, or fall back after delivery.

## Deterministic cases

The production builder tests must round-trip paths containing spaces, apostrophes, `+`, `#`, `%`, `&`, `?`, Simplified Chinese, and emoji. Tests also require exactly one target-specific query key, exact handler identity plus missing/wrong-handler branches, an asynchronous open success/error branch, and no post-success callback into Go2Codex ownership.

Fail-closed behavior: malformed components, non-absolute Workspace paths, missing handlers, and open completion errors perform no alternate handoff.
