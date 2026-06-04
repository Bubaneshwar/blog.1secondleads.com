# AGENTS.md

## What This Repo Is

- Jekyll site for `https://blog.1secondleads.com`, using the `jekyll-theme-chirpy` gem (`~> 7.2`, `>= 7.2.4`) rather than a vendored theme.
- GitHub Pages deploys from `.github/workflows/pages-deploy.yml` on pushes to `main` or `master`; CI uses Ruby 3.3, builds with `JEKYLL_ENV=production`, then runs `htmlproofer` with external links disabled.
- Ruby/Jekyll renders content. The Node toolchain is only for theme assets in `_sass/` and `_javascript/`, not for normal post authoring.

## Commands

- First Ruby setup: `bundle install`.
- Local server: `bash tools/run.sh` runs `bundle exec jekyll s -l -H 127.0.0.1`.
- Production local server: `bash tools/run.sh -H 0.0.0.0 -p`.
- CI-parity content check: `bash tools/test.sh` cleans `_site`, runs `JEKYLL_ENV=production bundle exec jekyll b`, then `bundle exec htmlproofer _site --disable-external`.
- If touching `_sass/` or `_javascript/`: run `npm install` if needed, then `npm run build`; use `npm run lint:scss` or `npx stylelint _sass/path/to/file.scss` for focused SCSS checks.
- There is intentionally no committed `Gemfile.lock` or `package-lock.json`; both are ignored.

## Generated And Ignored Assets

- Do not hand-edit `_sass/vendors/_bootstrap.scss`; `npm run build:css` regenerates `_sass/vendors/` from `node_modules/bootstrap/dist/css/bootstrap.min.css` via `purgecss.js`.
- Do not hand-edit `assets/js/dist/`; `npm run build:js` regenerates it from `_javascript/` via `rollup.config.js`.
- `_site/`, `_sass/vendors/`, and `assets/js/dist/` are ignored build outputs.

## Chirpy Overrides

- Files in `_layouts/`, `_includes/`, `_sass/`, `_data/`, `_plugins/`, `_tabs/`, and `index.html` override or extend the Chirpy gem behavior.
- Before adding an override, compare the upstream theme file with `bundle info --path jekyll-theme-chirpy` so you do not duplicate gem defaults unnecessarily.
- Site-local plugins are allowed because CI runs `bundle exec jekyll b` directly, not GitHub Pages' restricted plugin build.

## Posts

- Posts live in `_posts/YYYY-MM-DD-slug.md`; the filename date controls ordering, but `_config.yml` sets post permalinks to `/:slug/`, so changing front-matter `slug` changes the public URL.
- Required post front matter: `title` and `slug`. Current posts also use scalar `categories`, list `tags`, optional `date`, `description`, and `image` metadata.
- Do not set `layout: post`; `_config.yml` applies it through defaults.
- Do not set `last_modified_at`; `_plugins/posts-lastmod-hook.rb` derives it from git history when a post has more than one commit.
- Verify new or edited posts at `http://127.0.0.1:4000/<slug>/`; run `bash tools/test.sh` when adding links or images.

## Style And Config Gotchas

- `.editorconfig` requires 2-space indentation, LF endings, final newlines, single quotes for JS/CSS/SCSS, and double quotes for YAML.
- For design, branding, marketing, or visual UI work, always reference the 1SecondLeads brand kit at `C:\Users\kikoo\Downloads\1SecondLeads_BRAND_KIT.md` before making changes.
- `_config.yml` currently sets `theme_mode: light`, PWA/offline cache enabled, Google Analytics ID `G-PQJDQ6BN3C`, `baseurl: ""`, and comments provider empty.
- The semantic-release configuration in `package.json` targets an upstream-style `production` branch and is not the GitHub Pages deploy path for this site.
