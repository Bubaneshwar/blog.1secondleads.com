#!/usr/bin/env node
// Scrapes coldiq.com/tools/<slug> pages with Playwright and writes a JSON file
// in the shape the Ruby importer (tools/import-tool.rb) expects.
//
// Usage:
//   npm run scrape                    # process every pending row in scrape-queue.csv
//   node tools/scrape-coldiq.js --url https://coldiq.com/tools/hunter
//
// Reads:  tools-import/scrape-queue.csv  (columns: name,slug,source_url,status)
// Writes: tools-import/scraped/<slug>.json
// Updates: tools-import/scrape-queue.csv status column per row

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '..');
const QUEUE_PATH = path.join(ROOT, 'tools-import', 'scrape-queue.csv');
const OUTPUT_DIR = path.join(ROOT, 'tools-import', 'scraped');

const SOCIAL_PATTERNS = [
  { label: 'LinkedIn', match: /linkedin\.com\/(company|in)\// },
  { label: 'X / Twitter', match: /(?:twitter\.com|x\.com)\/(?!intent|share|home)/ },
  { label: 'YouTube', match: /youtube\.com\/(@|channel\/|user\/|c\/)/ },
  { label: 'Instagram', match: /instagram\.com\/(?!p\/|reel\/)/ },
  { label: 'Facebook', match: /facebook\.com\/(?!sharer|tr)/ },
  { label: 'TikTok', match: /tiktok\.com\/@/ }
];

// URLs that aren't the tool's own — coldiq footer, founder, etc.
const SOCIAL_DENY_PATTERNS = [
  /mich(?:el)?[-_\s]*lieben/i,
  /\bcoldiq\b/i
];

// RFC4180-ish CSV: handle quoted fields that contain commas, quotes, or newlines
// so a tool name like "Findymail, Inc" can't shift every subsequent column.
function parseCsvMatrix(text) {
  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQuotes = false;
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ',') {
      row.push(field); field = '';
    } else if (c === '\r') {
      // swallow; the paired \n ends the record
    } else if (c === '\n') {
      row.push(field); field = ''; rows.push(row); row = [];
    } else {
      field += c;
    }
  }
  if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row); }
  return rows;
}

function parseCsv(text) {
  const matrix = parseCsvMatrix(text)
    .filter(cells => cells.length > 1 || (cells.length === 1 && cells[0].trim() !== ''));
  if (matrix.length === 0) return { header: [], rows: [] };
  const header = matrix[0].map(c => c.trim());
  const rows = matrix.slice(1).map(cells =>
    Object.fromEntries(header.map((col, i) => [col, (cells[i] ?? '').trim()]))
  );
  return { header, rows };
}

function csvEscape(value) {
  const s = value == null ? '' : String(value);
  return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

function writeCsv(filePath, header, rows) {
  const out = [header.map(csvEscape).join(',')];
  for (const row of rows) {
    out.push(header.map(col => csvEscape(row[col])).join(','));
  }
  fs.writeFileSync(filePath, out.join('\n') + '\n');
}

function detectSocial(url) {
  if (SOCIAL_DENY_PATTERNS.some(p => p.test(url))) return null;
  for (const { label, match } of SOCIAL_PATTERNS) {
    if (match.test(url)) return label;
  }
  return null;
}

async function scrapeOne(browser, url, slug) {
  const page = await browser.newPage({
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
  });
  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });
    try {
      await page.waitForSelector('a[href*="/category/"]', { timeout: 25000 });
    } catch {
      // continue even if no category links appear — meta tags may still be useful
    }
    await page.waitForTimeout(800);

    // click any element whose visible text is "+N" or "+N more" (coldiq's category reveal is a <div>)
    const clicked = await page.evaluate(() => {
      const pattern = /^\+\s*\d+(?:\s*more)?$/i;
      const candidates = [...document.querySelectorAll('button, [role="button"], div, span, a')];
      const seen = new Set();
      const labels = [];
      for (const el of candidates) {
        const text = (el.textContent || '').trim();
        if (!text || !pattern.test(text)) continue;
        if (text.includes('→') || /user|stack/i.test(text)) continue;
        // skip ancestors of an already-clicked match
        if ([...seen].some(s => s.contains(el) || el.contains(s))) continue;
        seen.add(el);
        labels.push(`${el.tagName}:"${text}"`);
        try { el.click(); } catch {}
      }
      return labels;
    });
    await page.waitForTimeout(600);
    if (clicked.length) console.log(`     clicked expand: ${JSON.stringify(clicked)}`);

    const extracted = await page.evaluate(() => {
      const meta = Array.from(document.querySelectorAll('meta'))
        .map(m => {
          const property = m.getAttribute('property');
          const name = m.getAttribute('name');
          const content = m.getAttribute('content');
          if (!content) return null;
          if (property) return { property, content };
          if (name) return { name, content };
          return null;
        })
        .filter(Boolean);

      const canonical = document.querySelector('link[rel="canonical"]')?.href || null;
      const ogTitleNode = document.querySelector('meta[property="og:title"]');
      const productName = (ogTitleNode?.getAttribute('content') || document.title || '')
        .replace(/\s+Review.*$/i, '')
        .replace(/\s+-\s+.*$/, '')
        .trim();

      // Match coldiq's category URLs: /category/<slug>, /categories/<slug>,
      // /tag/<slug>, /ai-categories/<slug>, /ai-use-cases/<slug>, etc.
      const categoryHrefPattern = /\/(?:category|categories|tag|tags|topic|topics|ai-categor(?:y|ies)|ai-use-cases?|use-cases?)\//i;
      const categoryAnchors = Array.from(document.querySelectorAll('a[href]'))
        .filter(a => categoryHrefPattern.test(a.getAttribute('href') || ''));
      const categoryDebug = categoryAnchors.map(a => ({
        href: a.getAttribute('href'),
        text: (a.textContent || '').trim()
      }));
      const categories = categoryDebug
        .map(c => c.text)
        .filter(text => text && text.length > 0 && text.length < 80);

      const socialAnchors = Array.from(document.querySelectorAll('a[href]'))
        .map(a => a.href)
        .filter(href => /^https?:\/\//.test(href));

      return { meta, canonical, productName, categories, socialAnchors, categoryDebug };
    });

    const productName = extracted.productName || slug;
    const productId = `${slug}-pid`;

    const uniqueCategories = Array.from(new Set(extracted.categories));
    const socials = [];
    const seenSocialUrls = new Set();
    for (const href of extracted.socialAnchors) {
      const label = detectSocial(href);
      if (!label) continue;
      if (seenSocialUrls.has(href)) continue;
      seenSocialUrls.add(href);
      socials.push({ social: label, url: href });
    }

    const out = [
      ...extracted.meta,
      { productName, productId },
      ...uniqueCategories.map(name => ({ name, products: [productId] })),
      ...socials
    ];
    if (extracted.canonical) {
      out.unshift({ rel: 'canonical', href: extracted.canonical });
    }

    return { ok: true, productName, categoryCount: uniqueCategories.length, socialCount: socials.length, data: out, categoryDebug: extracted.categoryDebug };
  } finally {
    await page.close();
  }
}

function parseArgs(argv) {
  const args = { url: null, slug: null, headed: false, concurrency: 5 };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--url') args.url = argv[++i];
    else if (arg === '--slug') args.slug = argv[++i];
    else if (arg === '--headed') args.headed = true;
    else if (arg === '--concurrency') args.concurrency = parseInt(argv[++i], 10) || 5;
  }
  return args;
}

function deriveSlug(url) {
  const match = url.match(/coldiq\.com\/tools\/([a-z0-9-]+)/i);
  return match ? match[1].toLowerCase() : null;
}

(async function main() {
  if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

  const args = parseArgs(process.argv.slice(2));

  let header;
  let rows;
  let queueMode;

  if (args.url) {
    queueMode = false;
    const slug = args.slug || deriveSlug(args.url) || 'tool';
    rows = [{ name: slug, slug, source_url: args.url, status: 'pending' }];
    header = ['name', 'slug', 'source_url', 'status'];
  } else {
    queueMode = true;
    if (!fs.existsSync(QUEUE_PATH)) {
      console.error(`Queue file not found: ${QUEUE_PATH}`);
      process.exit(1);
    }
    const parsed = parseCsv(fs.readFileSync(QUEUE_PATH, 'utf8'));
    header = parsed.header;
    rows = parsed.rows;
  }

  const pending = rows.filter(r => {
    const s = (r.status || '').toLowerCase();
    return r.source_url && (s === 'pending' || s === 'failed' || s === '');
  });
  if (pending.length === 0) {
    console.log('No pending rows to scrape.');
    return;
  }

  const CHECKPOINT_EVERY = 10;
  const concurrency = Math.max(1, args.concurrency);

  console.log(`[${new Date().toISOString()}] Launching Chromium for ${pending.length} tool(s) (${args.headed ? 'headed' : 'headless'}). Concurrency=${concurrency}.`);

  let browser = await chromium.launch({ headless: !args.headed });
  let scraped = 0;
  let failed = 0;
  let cursor = 0;
  let completedTotal = 0;
  const startTime = Date.now();

  async function worker(id) {
    while (true) {
      const i = cursor++;
      if (i >= pending.length) return;
      const row = pending[i];
      const slug = row.slug || deriveSlug(row.source_url);
      if (!slug) {
        console.error(`[w${id}] ${i + 1}/${pending.length} ! cannot derive slug for ${row.source_url}`);
        row.status = 'failed';
        failed++;
        completedTotal++;
        continue;
      }
      const idx = `${i + 1}/${pending.length}`;
      const ts = new Date().toISOString();
      try {
        const result = await scrapeOne(browser, row.source_url, slug);
        // A page that loads but yields nothing useful (soft-404, placeholder) must
        // not be recorded as a successful scrape — otherwise an effectively-empty
        // JSON is written and the row is never retried. Require at least one real
        // signal: a category, a social link, or a description/title meta tag.
        const hasContent = result.categoryCount > 0 || result.socialCount > 0 ||
          result.data.some(item => item && (
            item.property === 'og:description' ||
            item.property === 'og:title' ||
            item.name === 'description'
          ));
        if (!hasContent) {
          console.error(`[${ts}] [w${id}] ${idx} EMPTY ${slug}: no categories, socials, or description — marking failed (not written)`);
          row.status = 'failed';
          failed++;
        } else {
          const outPath = path.join(OUTPUT_DIR, `${slug}.json`);
          fs.writeFileSync(outPath, JSON.stringify(result.data, null, 2));
          console.log(`[${ts}] [w${id}] ${idx} ok ${slug} (cat=${result.categoryCount}, soc=${result.socialCount})`);
          row.status = 'scraped';
          scraped++;
        }
      } catch (err) {
        console.error(`[${ts}] [w${id}] ${idx} FAIL ${slug}: ${err.message.split('\n')[0]}`);
        row.status = 'failed';
        failed++;
      }
      completedTotal++;

      if (queueMode && completedTotal % CHECKPOINT_EVERY === 0) {
        writeCsv(QUEUE_PATH, header, rows);
      }
    }
  }

  try {
    const workers = [];
    for (let id = 0; id < concurrency; id++) workers.push(worker(id));
    await Promise.all(workers);
  } finally {
    try { await browser.close(); } catch {}
    if (queueMode) writeCsv(QUEUE_PATH, header, rows);
  }

  const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
  const rate = scraped / Math.max(elapsed, 1);
  console.log(`[${new Date().toISOString()}] Done in ${elapsed}s (${rate.toFixed(2)} tools/sec). Scraped: ${scraped}. Failed: ${failed}.`);
  process.exit(failed > 0 ? 1 : 0);
})().catch(err => {
  console.error('Unexpected error:', err);
  process.exit(2);
});
