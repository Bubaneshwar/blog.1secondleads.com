# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Jekyll site for `blog.1secondleads.com`, built on the [Chirpy](https://github.com/cotes2020/jekyll-theme-chirpy) starter theme (`jekyll-theme-chirpy ~> 7.2`). Hosted on GitHub Pages, deployed via the workflow at [.github/workflows/pages-deploy.yml](.github/workflows/pages-deploy.yml) on push to `main`. Custom domain pinned in [CNAME](CNAME).

The Ruby/Jekyll layer renders the site. The Node toolchain only exists to build the theme's CSS/JS assets — it is not needed to author posts.

## Common commands

Authoring/serving content (Ruby side). CI builds on Ruby 3.3 ([pages-deploy.yml:45](.github/workflows/pages-deploy.yml#L45)); match that locally via `rbenv`/`asdf` if you hit native-gem resolution issues.

```bash
bundle install                   # first-time setup
bash tools/run.sh                # jekyll serve --livereload on 127.0.0.1:4000
bash tools/run.sh -H 0.0.0.0 -p  # bind all interfaces, JEKYLL_ENV=production
bash tools/test.sh               # production build + html-proofer (mirrors CI)
```

Theme asset toolchain (Node side — only needed when touching `_sass/` or `_javascript/`):

```bash
npm install
npm run build       # build:css (regen purged-Bootstrap partial) + build:js (rollup) in parallel
npm run watch:js    # rollup watch mode
npm run lint:scss   # stylelint _sass/**/*.scss   (also: npm test)
npm run lint:fix:scss
```

Single-file SCSS lint: `npx stylelint _sass/path/to/file.scss`.

## Repo layout that matters

- [_posts/](_posts/) — blog posts. Filenames are `YYYY-MM-DD-slug.md`. Permalinks are `/:slug/` (configured in [_config.yml](_config.yml) under `defaults`), so the URL comes from the `slug` front-matter field, not the filename date. Currently contains only a `.placeholder` — see "Conventions when adding a post" below for the front-matter shape.
- [_tabs/](_tabs/) — top-level navigation pages (About, Archives, Categories, Tags). They render through the `page` layout and live at `/:title/`.
- [_data/](_data/) — site data (contact links, locales, etc.) consumed by includes/layouts.
- [_layouts/](_layouts/), [_includes/](_includes/) — Liquid templates copied from the Chirpy gem. Editing these overrides the gem's versions.
- [_sass/](_sass/) — SCSS sources; compiled by Jekyll (`sass.style: compressed`) into the site's CSS at build time. The `_sass/vendors/_bootstrap.scss` partial is *generated* by [purgecss.js](purgecss.js) (see Architectural notes) — don't edit it by hand.
- [_javascript/](_javascript/) — ES module sources bundled by [rollup.config.js](rollup.config.js) into `assets/js/dist/`.
- [_plugins/](_plugins/) — site-local Jekyll plugins (allowed because we run `jekyll build` directly, not via GitHub Pages' restricted plugin set).
- [tools/](tools/) — `run.sh` (dev server) and `test.sh` (CI parity build + html-proofer). Excluded from the built site by [_config.yml](_config.yml).

## Architectural notes

- **Theme is a gem, not vendored.** Layouts/includes/sass in this repo *override* the same-named files inside the `jekyll-theme-chirpy` gem. To find the original of any template, run `bundle info --path jekyll-theme-chirpy`. Don't add a file here unless you intend to override.
- **Two build pipelines, one of them a pre-step.** Jekyll renders Markdown → HTML and compiles SCSS → site CSS at build time. The Node pipeline has two halves that run *before* Jekyll: rollup bundles `_javascript/` into `assets/js/dist/*.min.js`, and [purgecss.js](purgecss.js) reads `node_modules/bootstrap/dist/css/bootstrap.min.css`, strips unused selectors, and writes the result as an SCSS partial at `_sass/vendors/_bootstrap.scss`. Jekyll's Sass compiler then imports that partial when it compiles the site CSS. purgecss does **not** touch `assets/css/` — it only regenerates the Bootstrap partial. Posts and most edits don't need the Node pipeline; re-run `npm run build` only when you modify `_javascript/` or want to refresh the purged-Bootstrap partial (e.g. after bumping the Bootstrap version).
- **CI is the source of truth for "does it build."** [.github/workflows/pages-deploy.yml](.github/workflows/pages-deploy.yml) runs `JEKYLL_ENV=production bundle exec jekyll b` followed by `htmlproofer` with external link checks disabled. `bash tools/test.sh` reproduces this locally — run it before pushing anything non-trivial.
- **`permalink: /:slug/` for posts** means renaming a post's `slug` is a breaking URL change. The date in the filename only governs ordering/required-format, not the URL.
- **`last_modified_at` is auto-derived from git.** [_plugins/posts-lastmod-hook.rb](_plugins/posts-lastmod-hook.rb) hooks into Jekyll's post init and sets `post.data['last_modified_at']` from the most recent git commit touching that post. Don't set that field by hand in front matter. This plugin runs because we build with `jekyll build` directly, not via GitHub Pages' restricted-plugin mode.
- **`paginate: 10`**, dark theme by default (`theme_mode: dark`), GA id `G-PQJDQ6BN3C`, PWA + offline cache enabled, Google Analytics is the only configured analytics provider. Comments are disabled (no provider set).
- **Releases / semantic-release config in [package.json](package.json) is upstream theme machinery** targeting a `production` branch — it is not used by this site's deploy. The site ships from `main` via the GitHub Pages workflow.

## Conventions when adding a post

1. Create `_posts/YYYY-MM-DD-slug.md`. The filename date controls ordering; the `slug` front-matter field drives the URL.
2. Required front matter: `title` and `slug`. Conventional but optional: `categories` (a single string, e.g. `case-study` — historical posts use scalars, not lists), `tags` (a list), and `date` (Jekyll derives it from the filename if omitted). `layout: post` is applied automatically by the `_config.yml` `defaults` block — don't set it manually. Do not set `last_modified_at`; the git-history plugin fills it in.
3. `_posts/` currently holds only a `.placeholder`. For a canonical example of the historical front-matter shape, read `git show 37451e7:_posts/2024-10-18-neurogum-europe-case-study.md`.
4. Run `bash tools/run.sh` and verify the post renders at `http://127.0.0.1:4000/<slug>/`.
5. Run `bash tools/test.sh` before pushing if you added links or images (html-proofer catches broken refs).
