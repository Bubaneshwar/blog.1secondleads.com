# Tool Import Workflow

Use this importer for scraped tool JSON files. The first version uses scraped data only and reports missing fields instead of generating fallback copy.

## Single Tool

```powershell
& "C:\Ruby32-x64\bin\ruby.exe" tools/import-tool.rb "C:\Users\kikoo\Downloads\https___coldiq_com_tools_wiza.json"
```

Pass `--featured` to mark the tool as featured in `_data/tools.yml` (it will then appear in the "Best SaaS Sales Tools Everyone Uses" strip on `/tools/`). Pass `--no-featured` to explicitly unset it. Without either flag, re-imports preserve the entry's existing `featured` value.

```powershell
& "C:\Ruby32-x64\bin\ruby.exe" tools/import-tool.rb --featured "C:\Users\kikoo\Downloads\https___coldiq_com_tools_wiza.json"
```

Outputs:

- `_tool_pages/<slug>.md`
- `_data/tools.yml`
- `_data/tool_categories.yml`
- `tools-import/reports/<slug>.json`
- `tools-import/reports/<slug>.md`

## Batch Import

```powershell
& "C:\Ruby32-x64\bin\ruby.exe" tools/import-batch.rb "C:\Users\kikoo\Downloads\scraped-tools"
```

`--featured` / `--no-featured` are passed through to each tool, e.g. `import-batch.rb --featured path\to\folder`.

## Review links

Every imported tool gets a multi-source `review_links` block by default — **G2, Capterra, Trustpilot** (when the product domain is known), and **Product Hunt** (only when a real product page resolves). A Chrome Store entry is added when the coldiq FAQ indicates the tool ships an extension. This is intentional: most B2B SaaS tools are listed on each, so the reviews section is populated from more than one place out of the box rather than only when the FAQ name-drops a platform.

Two things the importer **cannot** do offline, both surfaced under "Review links" in the per-tool report so you can do a quick manual pass:

- **Scores** are only attached when the coldiq FAQ explicitly states a rating. The importer never invents a score. Entries without one are flagged `no score`. Look up the current G2/Capterra/Trustpilot rating and add a `score:` field (e.g. `score: 4.6/5`).
- **Capterra** uses a directory `search` URL because the numeric product id isn't in the scrape. Flagged `search URL`. Replace it with the direct review page (`https://www.capterra.com/p/<id>/<Name>/reviews/`).

Re-imports **preserve** curated `review_links`: existing entries (with verified scores and direct URLs) are kept as-is, and only newly discovered sources are appended. So once you've done the manual verification pass, it survives the next import.

## Copy rewriting (Claude)

Scraped coldiq copy is near-verbatim, which Google can flag as duplicate content. On
import the hero copy (`overview`, `tagline`), the "What is {tool}" paragraphs
(`what_is.description`), and the SEO meta `description` (which also keeps `value_prop`
in sync) are rewritten into original wording via the **Anthropic (Claude) API**.

Setup:

```powershell
$env:ANTHROPIC_API_KEY = "sk-ant-..."          # required to rewrite
$env:ANTHROPIC_REWRITE_MODEL = "claude-sonnet-4-6"  # optional, this is the default
& "C:\Ruby32-x64\bin\ruby.exe" tools/import-tool.rb path\to\scraped.json
```

Behavior:

- **No key / `REWRITE=0` / API failure → the page is blocked**: it is written with
  `published: false` so duplicate text never goes live, the directory card in
  `_data/tools.yml` keeps an external URL (so it never links to an unpublished page),
  and the per-tool report shows `BLOCKED - not rewritten (<reason>)`. Set the key and
  re-run to rewrite and publish.
- **Re-imports preserve a rewrite** (like `review_links`): a page marked
  `import.rewritten: true` reuses its existing copy and the API is never called again.
- One Claude call per fresh tool (all four fields in a single request). Tune with
  `ANTHROPIC_REWRITE_MODEL`, `REWRITE_TIMEOUT`, `REWRITE_MAX_RETRIES`.

## Supplied rewrite (no API key)

You can publish original copy **without any API key** by supplying the rewrite yourself
in a sidecar file. The importer reads `tools-import/rewrites/<slug>.json` and uses it as
the rewrite (so the page publishes with `import.rewritten: true` and
`import.rewrite_source: supplied`). Precedence is **existing > supplied > api > blocked**:
a page already marked `import.rewritten: true` keeps its own copy, so a stale sidecar
never overrides a published page.

Sidecar schema (`tools-import/rewrites/<slug>.json`):

```json
{ "description": "SEO meta, one sentence, <=160 chars",
  "tagline": "short phrase < 80 chars, or empty",
  "overview": "1-2 sentences",
  "what_is": ["paragraph 1", "paragraph 2"] }
```

`what_is` may be an array (kept as paragraphs verbatim) or a string (auto-split). Required
to publish: non-empty `description` and `overview`. All four fields are run through the
same brand sanitizer/clamp as the API path (plain prose, no emoji, no em-dashes).

Bootstrap the raw copy to rewrite with the dry-run flag — it writes only the sidecar
(the extracted raw copy), touching no page/tools.yml/categories/report:

```powershell
& "C:\Ruby32-x64\bin\ruby.exe" tools/import-batch.rb --emit-rewrite-drafts path\to\folder
```

Then rewrite the values in each `tools-import/rewrites/<slug>.json` into original wording
and re-import normally (no key needed) to publish:

```powershell
& "C:\Ruby32-x64\bin\ruby.exe" tools/import-batch.rb path\to\folder
```

After publish, the page's own `import.rewritten: true` is the source of truth (re-imports
reuse it), so the sidecar is only needed for the initial publish.

### Refreshing copy on an already-published page

Because a published page is marked `import.rewritten: true`, a normal re-import reuses its
existing copy and ignores the sidecar. To push updated copy onto an existing page (e.g. to
replace a weak earlier rewrite), edit `tools-import/rewrites/<slug>.json` and run:

```powershell
& "C:\Ruby32-x64\bin\ruby.exe" tools/apply-rewrites.rb <slug> [<slug> ...]
```

`apply-rewrites.rb` is surgical: it rewrites only `description`/`value_prop`/`tagline`/
`overview`/`what_is.description` from the sidecar (and sets `import.rewrite_source: supplied`),
with no network calls and no change to features/categories/review_links. With no args it
defaults to the original 8 pages.

## Rules

- The importer is idempotent. Running it again updates the same tool by slug.
- It uses scraped fields only (no fallback copy); the hero/what-is/meta copy is then
  rewritten by Claude (see above), and canonical review-link URLs are added.
- Missing fields — and review links needing a score or a direct URL — are listed in the report.
- Category aliases are controlled in `tools-import/category-map.yml`.
