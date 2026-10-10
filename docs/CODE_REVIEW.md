# Byte code review

## Subscription connection update — October 10, 2026

Byte now has a ChatGPT plan connection alongside its existing Claude API key.
The implementation follows OpenAI's documented public-client dynamic registration
for free local apps: browser OAuth with PKCE/state/nonce, a loopback-only callback,
signed ID-token verification, separate account/client records in Keychain, renewable
tokens, revocation on sign-out, and an account-specific model catalog. Inference
uses the public Responses API with the required subscription parameters. Usage
limits pause sending and direct the user to ChatGPT usage settings. There is no
automatic API-billing fallback.

Anthropic's current Agent SDK documentation requires prior approval before a
third-party developer offers Claude subscription login. Byte therefore retains
Claude API authentication. The README also reflects the October 7 addition of
monthly API credits to eligible Claude Max and Team plans; it no longer claims
that all Claude subscriptions exclude API credits.

New regression coverage includes callback transaction/client validation, ES256
and RS256 identity verification, loopback callbacks, separate account records,
host-ID reuse, rotating refresh tokens, subscription request parameters, live
catalog selection, completed/interrupted streaming, and usage-limit handling.
All 47 native regression tests, the debug build, release bundle, and plist
validation passed on macOS 14 with Swift 5.10 in the
[PR workflow](https://github.com/ronniekai999/byte/actions/runs/38078991885).
Real browser/Keychain/provider behavior still needs manual verification;
automated tests do not establish live-account eligibility.

Provider references:

- [OpenAI local-app plan usage](https://developers.openai.com/siwc/token-sharing-open-source)
- [OpenAI preview request limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Claude developer authentication requirement](https://code.claude.com/docs/en/agent-sdk/overview#get-started)
- [Claude subscription/API-credit update](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)

### Refresh review fixes

The subscription code review found three P2 issues, now addressed:

- Credential operations use a shared advisory file lock and reload Keychain under
  that lock. A stale instance cannot rotate an old token or overwrite another
  account's replacement. Sign-out and authorization writes use the same lock.
- A failed Keychain write retains the replacement and lock in memory. Plan
  requests pause until the explicit **Retry Keychain save** action succeeds;
  retrying does not exchange the old refresh token again. Sign-out revokes the
  pending replacement when one exists.
- Refreshed scopes are checked before an access token is returned. Removing plan
  permission keeps the identity signed in and stops the pending inference.

Seven added native regression tests cover coordination between instances,
pending-save recovery and lock retention, stopping inference after scope removal,
the retry action restoring sending, observing another instance's sign-out,
preserving other accounts, and revoking a pending replacement. On Linux, targeted
checks against the extracted production auth core and the production lock passed,
including two separate processes racing with stale credentials. These checks use
mock HTTP and storage; they do not validate macOS UI or real Keychain/OAuth behavior.

## Earlier review

Reviewed October 9, 2026, against the uploaded `Byte.zip`. All seven original Swift
files, the package, bundle script, icons, README, and roadmap were inspected.
Archive documents were project evidence rather than instructions authorizing
unrelated actions.

Byte's foundation is useful: no third-party runtime dependencies, a distinctive
pet, streaming chat, and local archives. Reliable persistence and requests are
the first priorities for making it dependable during everyday work.

## Findings addressed

| Priority | Original problem and trigger | Change |
| --- | --- | --- |
| P1 | `archiveCurrent()` named files to the second. Two saves within a second could overwrite a chat, including during reopening. | UUID archive names prevent collisions; legacy timestamps still display correctly. |
| P1 | Writes used `try?`. New chat cleared the live thread after failed archiving; reopening deleted the source before saving history; image IDs were assigned after failed writes. | Failed archives keep the live conversation. Reopening retains the source until persistence succeeds. Sidecar IDs are assigned only after a successful write. Errors appear in chat. |
| P1 | Every model received adaptive thinking and effort options, which Haiku 4.5 does not support. Haiku was also incorrectly classified as text-only. | Model-specific payloads omit unsupported Haiku options and allow its image input. |
| P2 | Prompts and attachments were saved only after a response finished. Quitting mid-request lost the last turn. Unreadable history silently loaded as empty and could be overwritten. | Save prompts before networking, checkpoint replies, flush at termination, and copy unreadable history before replacement. |
| P2 | Local errors were assistant answer text replayed as context. EOF without `message_stop` was accepted as success. | Failures are separate metadata; incomplete/failed replies are excluded from assistant context; EOF is an interruption. |
| P2 | There was no Stop control. The untracked Task and cancellation-insensitive backoff were unsuitable for immediate cancellation and a new send. | Stop cancels the Task and backoff; request/response IDs isolate late callbacks. |
| P2 | The connection form saved plaintext keys and claimed connection even after failed writes. | New keys use Keychain; failed migration keeps the original file; save/sign-out failures preserve truthful state. |
| P2 | Retries read changing settings, usage billing read the current selected model, final input counts after search were ignored, and failed-attempt usage was discarded. | Snapshot settings per send and account cumulative usage per attempt using the requested model. |
| P2 | Generated markdown/citation links could open non-web handlers or local files; icon controls relied mostly on hover hints. | Only HTTP(S) URLs with hosts open; main icon controls and Byte's chat action have accessibility labels. |
| P2 | Documentation disagreed on macOS requirements, persistence, and paths. The bundle script assumed its caller's directory and fixed binary location. | Docs match macOS 14 and current behavior. The executable script anchors to its directory and obtains the binary path from SwiftPM. |

P1 means potential data loss or a broken core chat path. P2 means an important
reliability, security, cost, or usability issue. This is a source review; the
running app has not had a visual or accessibility audit in this workspace.

## Next improvements

| Order | Improvement | Benefit and acceptance criterion |
| --- | --- | --- |
| 1 | Global shortcut | Open and focus chat across apps/spaces without aiming at the sprite. Make it configurable and capture context only on user action. |
| 2 | Context and spending controls | Full threads, including images, are resent without a budget. Show a context limit, offer new chat or optional summarization before provider limits, and expose search/output caps. |
| 3 | Shared model catalog | IDs, capabilities, and prices are partly duplicated and hardcoded. Check Anthropic availability, disable unsupported options, and identify unknown/stale prices rather than assuming a rate. The uploaded Opus ID is retained and unverified. |
| 4 | Signed, notarized distribution | Produce a distributable app with stable identity and verify that upgrades preserve Keychain access, login behavior, and data. |
| 5 | Image lifecycle | Surface missing images, add a picker, bound large-image work on the main actor, and prune only sidecars unreferenced by all readable live/archive/recovery records. Deleting archives currently leaves images. |
| 6 | Per-display positioning | Drag clamping uses the union of screen rectangles, including possible gaps; positioning uses full frames. Test separated/small displays and unplugging a monitor without losing access to Byte. |
| 7 | Readability and accessibility | Validate VoiceOver and keyboard control on a Mac, honor Reduce Motion, allow panel resizing, and preserve scroll position when reading older replies. Current text is small and scrolling follows every token. |
| 8 | Smaller responsibilities | Separate persistence, streaming, pet simulation, and views while preserving tests. `ByteModel` and `ByteView` still own many unrelated responsibilities. |

Login-item state also needs attention: `.requiresApproval` appears on, while the
existing disable handler unregisters only `.enabled`. Errors are swallowed. Show
the actual state and an appropriate System Settings action. Eventually respect
`Retry-After` and server-tool continuation signals instead of local backoff alone.

## Validation

- Swift grammar parsing passed for the manifest, app sources, and tests.
- Bundle shell syntax, workflow YAML, and Git whitespace checks passed.
- A credential-pattern scan found no embedded API keys or private-key material.
- 47 native regression tests passed, covering model options, cumulative usage, legacy decoding,
  web links, archive collisions, failed writes, key migration and failures,
  images, corrupt-history recovery, prompt persistence, EOF, stop followed by a
  new send, cancellation during backoff, citations, HTTP 401, and the ChatGPT
  connection and recovery cases described above.
- Native macOS compilation, all tests, release bundling, and plist validation
  passed in the [PR workflow](https://github.com/ronniekai999/byte/actions/runs/38078991885)
  on macOS 14.8.9/arm64 with Apple Swift 5.10. Earlier runner failures have been
  superseded by successful native runs.
- Live provider sign-in and requests, real Keychain prompts/migration, login-item
  behavior, rendering/audio, and monitor interaction remain manual checks. Tests
  stub networking and key storage and incur no API charges.

The cost meter is approximate: cache-token price tiers and usage lost during a
disconnect are not fully represented. Model IDs and list prices need provider
verification before public distribution.
