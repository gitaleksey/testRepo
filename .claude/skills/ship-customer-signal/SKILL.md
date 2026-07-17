---
name: ship-customer-signal
description: >
  Per-user routine for the AI Forward Deployed shared-context system. Ships ALL
  customer-matched signal from your personal-account sources — Google Meet
  transcripts, customer email threads + attachments, and customer meeting
  metadata — to the central Drive dropzone the team intake pipeline reads.
  These are the sources no central process can reach (they live in your own
  Drive / Gmail / Calendar). Transport only: verbatim content, no summarizing,
  no redacting. The single gate is whether a registered DP (on the DP Registry) was involved;
  anything internal-only never leaves your machine. Runs daily as a routine;
  also on demand: "ship my customer signal", "run the signal shipper".
---

# ship-customer-signal — Per-user personal-account signal shipper

## What this does

Captures the customer signal that lives in *your* accounts and copies it, verbatim, into the central Drive dropzone the team's intake pipeline ingests. It writes to **no shared record**, summarizes nothing, redacts nothing — it crosses the personal-account boundary the central pipeline can't, and hands the raw material to the central pipeline, which does all the extraction and routing.

Three sources, one filter:

| Source | Ships | Form |
|---|---|---|
| **Google Meet** | Transcripts of customer-facing calls (hosted + attended) | Verbatim transcript when Meet transcription was on; else the Gemini Notes, tagged `transcript_present: false` |
| **Gmail** | Registered-DP email threads **+ attachments** | Verbatim recent messages + extracted attachment text |
| **Calendar** | Customer meeting events (past + upcoming), attendees + responseStatus | Metadata only — not a transcript |

**The single gate:** an external participant whose domain is on the **DP Registry** must be involved (Registry `Domains` match on the call participants / email From-To-CC / event attendees). Not on the Registry → not shipped — that covers both internal-only content *and* any customer/prospect not (yet) a registered DP. This one filter is the entire privacy boundary *and* the account scope — it keeps internal/personal content (incl. sensitive meeting titles) out, and limits the dropzone to curated DP accounts, while letting registered-DP signal through verbatim.

## Google access — direct API via a `gws` OAuth token (not the desktop connectors)

This skill talks to Google through the **direct REST APIs** using an OAuth token, via the shared helper `~/.claude/skills/_shared/gsheets.sh` (`gws_token`, `gsheet_get`, `_gws_curl`). It does **not** use the Claude desktop Google connectors — they can't target a Sheet tab and they collapse empty columns, which silently breaks the Registry read. The same mechanism works with or without Zscaler (the helper adds `--cacert <zscaler-root>` only when that cert is present; off-Zscaler it uses system trust). One-time setup (install `googleworkspace-cli`, `gws auth login`, `cryptography`, and — behind Zscaler — the cert): see the **ship-customer-signal Google Access Setup** guide.

What it touches (all via that token):
- **Drive** — read your Meet *Recordings* folder + shared/attached transcript docs; **write** the dropzone folder.
- **Gmail** — read email threads + attachments; find Meet "recording ready" notifications.
- **Calendar** — read customer meeting events + attendance.
- **Sheets** — read the DP Registry.
- Write access to the shared dropzone + read access to the Registry are **already granted to the FDE/CTO team**.

## Configuration — none to fill in

Nothing for the user to set. Shared constants are baked in, per-user bits are auto-detected, dedup state is internal:
- **Dropzone** (write target): `1ubMJjUwivXf7XyxB6D54dbJwYV2YZL4z` (`shared-context-automation/dropzone`).
- **Account map — sole source**: DP Registry Sheet `1YWYqqWsk9Eu-uC7l9b--YYv-HV7967XYywNGcFuhEdg`, the **`Design Partner Registry`** tab (multi-tab workbook — not the first tab) — `Domains` (col K) for matching, `account_slug` (col L) for routing + folder name. Read it tab-aware / all-columns (see Step 0 — a naive Drive read grabs the wrong tab and drops K/L). Nothing local; not on the Registry → not processed.
- **Your email** + **your Meet Recordings folder**: auto-detected at runtime (Step 0).
- **Dedup state**: `~/.claude/state/ship-customer-signal.json`, managed automatically — you never touch it.

## Dropzone write format (self-contained — this skill needs no other file)

Every file is Markdown with YAML frontmatter, written to `dropzone/{account_slug}/{YYYY-MM-DD}_{type}_{slug}.md` (`{account_slug}` = the Registry `account_slug`, col L; `{slug}` = a short kebab slug of the meeting/thread title).

**Common frontmatter — every file, every type:**
```yaml
---
type: meet | email | calendar
account: "<Registry DP Name, col B>"
account_slug: "<Registry account_slug, col L>"
account_type: DP
date: YYYY-MM-DD
participants:
  - { name: "Full Name", email: "person@customer.com", org: "Customer" }
  - { name: "You", email: "you@snyk.io", org: "Snyk" }
shipped_by: "<your @snyk.io email>"
source_ref: "<Drive fileId | Gmail threadId | Calendar eventId>"   # the dedup key
shipped_at: "<ISO-8601 UTC, e.g. 2026-07-07T21:00:00Z>"
---
```

**Per type:**
- **`meet`** — extra header: `meeting_title`, `transcript_present: true|false` (**required**), `duration_min` if known. Body = the **full verbatim transcript** (speaker turns) when `transcript_present: true`; the Gemini Notes verbatim (headed `[notes-only — no verbatim transcript]`) when `false`. No summarizing, no truncation.
- **`email`** — extra header: `subject`, `thread_message_count`, `long_thread: true` if the thread has >5 messages. Body = the up-to-3 most-recent messages **verbatim, most-recent first**, then a `## Attachments` section: each product-relevant attachment's filename + its **extracted text verbatim** (set `attachment_truncated: true` if you couldn't capture all of it).
- **`calendar`** — **metadata only, no body.** Extra header: `meeting_title`, `start`, `end`, `when: past | upcoming`, `attendees:` (list of `{email, responseStatus}`), `meet_recording_shipped: true|false` (did you also ship a `meet` file for this event this run?).

`source_ref` is the dedup key; `account_slug` is the routing key. That's the whole contract — central reads these files and does all extraction, routing, and any Gong reconciliation.

## Step 0 — Self-configure + load state
- **Account map — the DP Registry Sheet is the SOLE source.** Read the **`Design Partner Registry`** tab (headers row 2, data row 3+). Build `{domain → account}` from two columns: **`Domains` (col K)** — split comma-separated, match ALL (e.g. JPMC = `jpmchase.com, jpmorgan.com, chase.com`) — and **`account_slug` (col L)**, which is the routing key + dropzone folder name. Every processed account is `account_type = DP`.
- **HOW to read it — use the direct Sheets API, not the desktop connectors.** This workbook has ~37 tabs and `Design Partner Registry` is NOT the first, so the connectors fail *silently*: `read_file_content`/CSV export return the workbook's first tab (the wrong one) and collapse empty cells, hiding cols K/L — the columns the whole gate depends on. Read tab-aware and exact via the shared helper: `source ~/.claude/skills/_shared/gsheets.sh` then `gsheet_get 1YWYqqWsk9Eu-uC7l9b--YYv-HV7967XYywNGcFuhEdg 'Design Partner Registry!A2:L'` — it's a Sheets `values.get` on the named tab+range using your `gws` OAuth token (works with or without Zscaler). **Never use `read_file_content` or CSV export for the Registry.**
  - **Sanity gate:** the row-2 headers you read back must include both `Domains` and `account_slug`. If not, the read is wrong — stop; do not proceed with an empty gate (that ships nothing, or mis-scopes).
- **HARD RULE — Registry-only. If an account is not on the DP Registry, do not process it at all.** No `customers/*.md`, no other local files, no `_unmatched/` triage. A call / email / event whose external participants match no Registry domain is simply not shipped — same as internal-only. This is the entire account gate.
- **INTERNAL-DOMAIN EXCLUSION (overrides everything above).** `snyk.io` — and any other Snyk-owned domain — is ALWAYS internal and is NEVER a customer match, even if it appears in the Registry `Domains` column. Hardcode `INTERNAL_DOMAINS = {snyk.io}` and drop these domains from the match set before applying the Registry gate. Rationale: the Registry contains a "Snyk, Inc." dogfooding DP row; without this override, a Registry entry of `snyk.io` would make every internal Snyk-only call/email/meeting match that row and ship — destroying the internal-privacy boundary. The exclusion is belt-and-suspenders: it holds even if someone re-adds `snyk.io` to the Registry.
- A Registry row with an empty `Domains` (K) can't be matched (nothing to key on) — skip it and note the count; a row with empty `account_slug` (L) can't be routed — skip and note. Both are Registry data gaps to fix on the sheet, not worked around here.
- **Your identity (auto):** get the authenticated account's email; find your Meet Recordings folder by Drive-searching for the `Meet Recordings` folder you own.
- **State (auto):** read `~/.claude/state/ship-customer-signal.json` (create if absent) → already-shipped `source_ref`s. Window = since last successful run (fallback 24h); calendar +7-day lookahead.

## Step 1 — Meet transcripts
- **Path A (hosted):** list `MEET_RECORDINGS_FOLDER_ID` for transcripts **created** in the window — key on `createdTime` (≈ meeting time), **never `modifiedTime`**. A re-opened or re-indexed old doc bumps `modifiedTime`, which would resurface months-old calls as if fresh (this is exactly how a May transcript wrongly reappeared in a July run).
- **Path B (attended, not hosted):** find recordings/transcripts you can access but didn't host — **two kinds, catch both:** (a) Google Meet auto "recording is ready" notifications (`subject:recording OR subject:transcript` / `"recording is ready"`); **and (b) recordings/transcripts shared *manually* by a teammate** in a customer-matched email — a Drive link to a recording or "Notes by Gemini" transcript doc (at Snyk this is the common case — e.g. an account TSM emailing "Meeting Recordings" to the thread). For both, extract the Drive fileId and export the transcript. For Path-B shared docs, bound the window by `sharedWithMeTime` (when the doc first reached you), not `modifiedTime`. Validation 2026-06-29: the literal "recording is ready" query returned nothing in 21d while manual recording-shares existed — so (b) is essential, not optional.
- For each, get participants (transcript header + matching Calendar event). **Apply the gate.**
- **Prefer the full transcript; fall back to notes; always tag which one you shipped.** Export the doc with `files/{id}/export?mimeType=text/plain` — this returns **both** the AI Notes/Summary section **and** the full verbatim `📝 Transcript` section (timestamped speaker turns) *when Meet transcription was enabled for that call*. Read the **whole** export — do not stop at the Notes/Summary.
  - If a `📝 Transcript` / `## Transcript` section is present → ship the **full transcript verbatim**, no truncation, and set `transcript_present: true`.
  - If only Notes/Summary exist (transcription was off for that call) → ship the Notes verbatim and set `transcript_present: false`. This tells central the authoritative transcript is elsewhere (its own Gong pull) and to prefer that.
- **Ship every Registry-matched call — even if it may also be in Gong. Never skip a transcript for "redundancy."** You have no Gong visibility (and neither do most FDEs running this); Gong-vs-Drive dedup is central's job, not yours. Shipping a call Gong already has is harmless; *not* shipping one Gong missed is a permanent gap.
- Write to dropzone: `{account}/{YYYY-MM-DD}_meet_{slug}.md`, header `type: meet` (include `transcript_present`).

## Step 2 — Customer email threads + attachments
- Search Gmail per account with the domain OR-set and the noise filter:
  `{from:*@d1 OR to:*@d1 OR from:*@d2 ...} after:[date] -subject:"Accepted" -subject:"Declined" -subject:"Invitation:" -subject:"Cancelled" -label:automated`
- For each thread: read up to the 3 most recent messages (threads >5 messages: most recent only, flag for manual review). **Skip threads where all participants are @snyk.io** (internal — never ships).
- **Fetch and extract attachments** when the thread carries product-relevant files (`.xlsx`/`.csv`/`.pdf`/`.docx` — FP lists, scan results, requirements, asks). Extract their text verbatim; if too large, capture what you can and flag it. (This is the JPMC `Scan_issues.xlsx` case — do not skip attachments.)
- Write to dropzone: `{account}/{YYYY-MM-DD}_email_{slug}.md`, header `type: email`, body = verbatim messages + attachment extracts.

## Step 3 — Calendar (metadata only)
- Pull events in the past window (meetings that happened) and the 7-day lookahead (upcoming). Apply the gate: at least one attendee whose domain is on the DP Registry (col K). **Ignore room/resource addresses** (`*.calendar.google.com`, e.g. `…@resource.calendar.google.com`) — they are not participants, and counting them makes an internal meeting look customer-facing.
- Ship **metadata only** — title, date, attendees with responseStatus, past/future flag, matched account. No transcript, no body.
- Write to dropzone: `{account}/{YYYY-MM-DD}_cal_{slug}.md`, header `type: calendar`.
- **You do not compute the no-recording flag here.** Central intake does that — it's the only place that can see Gong *and* your shipped Meet transcripts together. Your job is just to ship the calendar data so central can cross-check it.

## Step 4 — Dedupe + heartbeat
- Skip any source item already in `STATE_FILE` (`~/.claude/state/ship-customer-signal.json`); record newly shipped IDs. Idempotent — safe to re-run.
- Log a one-line summary (per source: seen / shipped / skipped-internal / already-shipped). Never log the content of skipped-internal items.

## Constraints

- **Verbatim content; metadata-only calendar.** Transport, not synthesis — central owns extraction, records, and any external scrub.
- **Registry-match is the sole gate.** An external participant whose domain is on the DP Registry (col K) → ship. Everything else — internal-only *and* any customer/prospect not on the Registry — is not shipped, full stop. There is no `_unmatched/` path. This protects internal content and keeps the dropzone to curated DP accounts only.
- **Your credentials only.** Reads your Drive/Gmail/Calendar; writes only the dropzone. Never another person's accounts, never the shared records.
- **Stay Gong-blind by design.** This skill runs for people without Gong API access (most FDEs). Never make shipping conditional on Gong. All Gong-vs-Drive reconciliation — the no-recording flag *and* transcript dedup — is central's, because that's the only layer with Gong. Ship generously; central dedups a shipped `meet` file against its Gong pull by (account + date + title), preferring the Gong transcript when `transcript_present: false` and using your Drive transcript when Gong has no record of the call.

## Behavioral note for the person running this
- Google Meet **"Transcription"** and Gemini **"Take notes"** are separate toggles. Notes-only calls ship as `transcript_present: false` and lean on central's Gong pull for the real transcript. **Turn on Meet *transcription* for customer calls** — that generates a full `📝 Transcript` section in your own Drive, which this skill then captures verbatim regardless of Gong. Highest-leverage habit for transcript coverage; costs nothing.
