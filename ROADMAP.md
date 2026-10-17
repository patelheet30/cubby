# Cubby roadmap

Next release: **v0.2.0**, four features that no other clipboard manager combines. Each one ships with `--self-test` checks and is checked live in the drawer before the next starts.

| # | Feature | Effort | Touches |
|---|---|---|---|
| 0 | Store migration v2 (one schema change for 3 and 4) | S | `Store.swift` |
| 1 | Link Cleaner | S | `Capture/LinkCleaner.swift` (new), `ClipboardWatcher`, card, Settings |
| 2 | Merge Clips | S | `DrawerView` menus + keys, `Store` |
| 3 | Pinboards that follow the app | S–M | `Store`, rail, `PanelController.show`, board menu |
| 4 | Self-destructing secrets (blurred until hover) | M | `Capture/SecretDetector.swift` (new), `Store`, card, preview, housekeeping, Settings |

Then: tag `v0.2.0`. The release workflow builds, notarises and publishes the DMG.

---

## 0. Store migration v2
`user_version` 1 → 2, run once at launch:
```sql
ALTER TABLE item ADD COLUMN expires_at REAL;   -- secrets: delete after this time unless pinned
ALTER TABLE item ADD COLUMN sensitive INTEGER NOT NULL DEFAULT 0;
CREATE TABLE pinboard_app (pinboard_id INTEGER NOT NULL REFERENCES pinboard(id) ON DELETE CASCADE,
                           bundle_id TEXT NOT NULL, PRIMARY KEY (pinboard_id, bundle_id));
```
Self-test: a v1 database opened by the new build keeps its clips and gains the columns.

## 1. Link Cleaner
**What you see:** copy `https://example.com/page?utm_source=x&fbclid=y&id=7` and Cubby pastes `https://example.com/page?id=7`. The link card shows a small "Cleaned 2" tag.

- `LinkCleaner.clean(URL) -> (URL, removed: Int)`, a pure function with:
  - generic tracking parameters: `utm_*`, `fbclid`, `gclid`, `dclid`, `gbraid`, `wbraid`, `msclkid`, `yclid`, `mc_cid`, `mc_eid`, `_hsenc`, `_hsmi`, `igshid`, `igsh`, `ref_src`, `spm`, `vero_*`, `oly_*`;
  - site rules: YouTube and Spotify `si`/`pp`, X/Twitter `s`/`t`, Amazon trimmed to `/dp/<ASIN>`.
- **When:** at capture, for link clips (and text clips that are exactly one URL).
  - Cubby stores the clean link and rewrites the system clipboard straight away, so a plain ⌘V elsewhere is clean too.
  - The rewrite counts as Cubby's own write (`ignoreCurrent()`), so it isn't captured twice.
- **Undo:** the original is kept in `Preview.originalURL`, and the card's menu gains **Paste Original Link**.
- **Setting:** Privacy → "Remove tracking from links" (default on).
- **Self-test:** a table of about 15 URLs (each rule, plus links that must stay untouched, like `?id=` and `?q=`).

## 2. Merge Clips
**What you see:** select several cards (⇧/⌘-click or ⇧↑↓), press **⌘M** or right-click → **Merge ▸**, and a new text clip appears at the top, selected and ready to paste.

- Formats: **Lines** (default for ⌘M), **Bullet list** (`• `), **Comma-separated**, **One paragraph** (spaces).
- Uses the full text from each clip's payload, in the order shown in the drawer.
  - Links use their URL and colours their hex.
  - Images and files are skipped, and the toast says so ("Merged 3 · skipped 1 image").
- Inserted through the normal capture path (app = Cubby), so dedupe, search and undo all work. ⌘Z deletes the merged clip.
- **Self-test:** each format, mixed kinds, order preserved.

## 3. Pinboards that follow the app
**What you see:** open the drawer in Terminal and it lands on your "Shell" board. Open it in Slack and it lands on "Replies". Anywhere else, History. A tiny app icon sits on the board's rail tile.

- Board menu (right-click a tile, or `•••`) → **Show for App ▸**:
  - the app you were just in (one click);
  - **Choose App…**, a picker of running apps plus `/Applications`;
  - the apps already bound, each with ✓ to remove.
- `PanelController.show()` reads the frontmost app before opening. If a board is bound to it, the drawer opens on that board and the title shows "for Slack". ⇥ still walks to History.
- One app maps to at most one board (binding it again moves it). A board can follow several apps.
- **Self-test:** bind, rebind moves, unbind, deleting a board drops its bindings.

## 4. Self-destructing secrets
**What you see:** copy an API key and its card shows a frosted, blurred body with "Secret · deletes in 9 min". Hover (or select and hold ⌥) to reveal it. Ten minutes later it's gone, unless you pinned it.

- `SecretDetector.check(String) -> Kind?`, a pure function with:
  - **Known key formats:** `sk-…`, `sk_live_…`/`rk_live_…` (Stripe), `ghp_`/`gho_`/`ghs_`/`github_pat_`, `xox[abpr]-` (Slack), `AKIA…` (AWS), `AIza…` (Google), `glpat-`, `npm_`, JWTs (`eyJ….….…`), `-----BEGIN … PRIVATE KEY-----`.
  - **Card numbers:** 13–19 digits that pass the Luhn check.
  - **One-time codes:** a lone 4–8 digit code, or text like "your code is 123456".
  - **High-entropy tokens:** a single word of 32+ characters with mixed classes and high Shannon entropy.
- **At capture:**
  - mark `sensitive = 1` and set `expires_at = now + lifetime`;
  - index only "secret" in search, never the value.
- **Drawer:**
  - the card body is drawn with a blur layer and a lock glyph;
  - it's revealed on hover, on ⌥ while selected, or in the preview after a click;
  - copy, paste and merge work normally.
- **Expiry:**
  - housekeeping runs every 60 s and hard-deletes expired, unpinned secrets (row and blob);
  - pinning clears the expiry, unpinning starts it again;
  - if the expiring secret is still on the system clipboard, the clipboard is cleared too (setting, default on).
- **Settings → Privacy:** "Delete secrets after: 1 / 5 / 10 / 30 min / Never" (default 10), and "Also clear them from the clipboard".
- **Self-test:** detector table (true positives for each format, plus false-positive traps: a 6-digit price, a UUID, a git SHA, an ordinary long word), and expiry deletes unpinned but keeps pinned.

---

## Not planned
Paste-as transforms, snippet templates, text search inside images, search by meaning, drop shelf, menu bar quick list, "never save" rules, scratch board, most-used sorting, export/import, and anything that ties Cubby to Glint. These were all considered and declined (2026-10-17).
