#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'cgi'
require 'json'
require 'net/http'
require 'time'
require 'uri'
require 'yaml'

ROOT = File.expand_path('..', __dir__)
IMPORT_ROOT = File.join(ROOT, 'tools-import')
REPORT_ROOT = File.join(IMPORT_ROOT, 'reports')
TOOL_PAGE_ROOT = File.join(ROOT, '_tool_pages')
TOOLS_DATA_PATH = File.join(ROOT, '_data', 'tools.yml')
CATEGORY_DATA_PATH = File.join(ROOT, '_data', 'tool_categories.yml')
CATEGORY_MAP_PATH = File.join(IMPORT_ROOT, 'category-map.yml')
LOCAL_IMAGE_ROOT = File.join(ROOT, 'assets', 'img', 'tools')
# No-API rewrite source: a per-tool sidecar (tools-import/rewrites/<slug>.json) holding
# the rewritten copy, so pages can publish original wording without the Claude API.
REWRITE_SIDECAR_ROOT = File.join(IMPORT_ROOT, 'rewrites')

# Copy-rewrite (Anthropic / Claude) config. Scraped coldiq text is published nearly
# verbatim, which Google can flag as duplicate content. During import we rewrite the
# hero and "What is" copy + SEO meta description into original wording via the Claude
# API. Disabled with REWRITE=0 or when no key is set; in that case the page is blocked
# (published:false) so duplicate text never goes live.
ANTHROPIC_API_KEY = ENV['ANTHROPIC_API_KEY'].to_s
ANTHROPIC_REWRITE_MODEL = ENV.fetch('ANTHROPIC_REWRITE_MODEL', 'claude-sonnet-4-6')
ANTHROPIC_API_BASE = ENV.fetch('ANTHROPIC_API_BASE', 'https://api.anthropic.com')
ANTHROPIC_VERSION = ENV.fetch('ANTHROPIC_VERSION', '2023-06-01')
REWRITE_TIMEOUT = Integer(ENV.fetch('REWRITE_TIMEOUT', '60'))
REWRITE_MAX_RETRIES = Integer(ENV.fetch('REWRITE_MAX_RETRIES', '3'))
REWRITE_ENABLED = ENV['REWRITE'] != '0'

def rewrite_active?
  REWRITE_ENABLED && !ANTHROPIC_API_KEY.empty?
end

def usage
  warn 'Usage: ruby tools/import-tool.rb [--featured] path/to/scraped-tool.json'
  exit 1
end

def text(value)
  case value
  when String
    value.encode('UTF-8', invalid: :replace, undef: :replace)
         .gsub('u0026', '&')
         .gsub('&amp;', '&')
         .gsub('&rsquo;', "'")
         .gsub('&apos;', "'")
         .gsub('&quot;', '"')
         .gsub(/\s+/, ' ')
         .strip
  when Array
    value.map { |item| text(item) }.join('').strip
  else
    value.to_s.strip
  end
end

def slugify(value)
  text(value).downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')
end

# The coldiq canonical URL (coldiq.com/tools/<slug>) is the stable product
# identifier, and hand-seeded tools.yml cards store it in their `url` field. We
# use it to reconcile an import with an existing seed card whose short name
# slugifies differently from the scrape's product name (e.g. seed "Apollo" vs
# scraped "Apollo.io"), so the import updates that card in place instead of
# appending a duplicate. Returns nil for non-coldiq (already-internal) urls.
def coldiq_slug(url)
  return nil if url.to_s.empty?

  match = url.match(%r{coldiq\.com/tools/([a-z0-9-]+)}i)
  match && match[1].downcase
end

def load_yaml(path, fallback)
  return fallback unless File.exist?(path)

  YAML.safe_load(File.read(path), permitted_classes: [Time, Date], aliases: true) || fallback
rescue Psych::SyntaxError => e
  # Do NOT fall back here: callers (tools.yml, tool_categories.yml) overwrite the
  # file with the fallback's contents, so swallowing a syntax error would silently
  # destroy every existing entry. Abort and let the user fix the YAML first.
  abort "import-tool: #{path} is not valid YAML (#{e.message}). Fix it before re-running."
end

def yaml_front_matter(data)
  YAML.dump(data).sub(/^---\n/, '')
end

def compact_hash(hash)
  hash.each_with_object({}) do |(key, value), memo|
    next if value.nil?
    next if value.respond_to?(:empty?) && value.empty?

    memo[key] = value
  end
end

def strings_from(value, list = [])
  case value
  when String
    list << text(value) unless text(value).empty?
  when Array
    value.each { |item| strings_from(item, list) }
  when Hash
    value.each_value { |item| strings_from(item, list) }
  end
  list
end

def find_meta(data, key, value)
  data.find { |item| item.is_a?(Hash) && item[key] == value }
end

def find_product_name(data)
  title = find_meta(data, 'property', 'og:title')&.fetch('content', nil) ||
          find_meta(data, 'name', 'twitter:title')&.fetch('content', nil) ||
          data.find { |item| item.is_a?(Hash) && item['children'].is_a?(String) && item['children'].include?(' Review') }&.fetch('children', nil)

  title = text(title)
  name = title.sub(/\s+Review:.*$/i, '').sub(/\s+Review$/i, '')
  return name unless name.empty?

  product_marker = data.find { |item| item.is_a?(Hash) && item['productName'] }
  text(product_marker&.fetch('productName', nil))
end

def find_product_id(data, product_name)
  marker = data.find do |item|
    item.is_a?(Hash) && text(item['productName']).casecmp?(product_name) && item['productId']
  end

  marker&.fetch('productId', nil)
end

def scraped_categories(data, product_id)
  return [] if product_id.to_s.empty?

  data.each_with_object([]) do |item, categories|
    next unless item.is_a?(Hash)
    next unless item['name'] && item['products'].is_a?(Array)
    next unless item['products'].include?(product_id)

    categories << text(item['name'])
  end.uniq
end

def category_mapper
  map = load_yaml(CATEGORY_MAP_PATH, {})
  alias_to_category = {}
  map.each do |category, aliases|
    ([category] + Array(aliases)).each do |alias_name|
      alias_to_category[text(alias_name).downcase] = text(category)
    end
  end
  alias_to_category
end

def normalize_categories(categories)
  mapper = category_mapper
  categories.map { |category| mapper.fetch(category.downcase, category) }.uniq
end

BROAD_CATEGORIES = [
  'DATA SOURCES', 'LINKEDIN TOOLS', 'AI SALES TOOLS', 'GTM TOOLS'
].freeze

def too_broad_category?(category)
  BROAD_CATEGORIES.include?(category)
end

def product_categories(raw_categories, visible_categories)
  filtered_raw = raw_categories.reject { |category| too_broad_category?(category) }
  filtered_visible = Array(visible_categories).reject { |category| too_broad_category?(category) }
  combined = filtered_visible + filtered_raw

  combined.map { |category| text(category) }.reject(&:empty?).uniq.first(10)
end

def social_links(data)
  data.each_with_object([]) do |item, links|
    next unless item.is_a?(Hash) && item['social'] && item['url']

    label = text(item['social'])
    label = 'X / Twitter' if label.casecmp?('Twitter')
    links << { 'label' => label, 'url' => text(item['url']) }
  end.uniq { |link| link['url'] }
end

SOCIAL_URL_PATTERNS = {
  'LinkedIn' => %r{https?://(?:[a-z]{2,3}\.)?linkedin\.com/company/[A-Za-z0-9_-]+}i,
  'X / Twitter' => %r{https?://(?:www\.)?(?:twitter\.com|x\.com)/(?!intent\b|share\b|home\b|i/)[A-Za-z0-9_]+}i,
  'YouTube' => %r{https?://(?:www\.)?youtube\.com/(?:@[A-Za-z0-9_.\-]+|channel/[A-Za-z0-9_-]+|user/[A-Za-z0-9_-]+|c/[A-Za-z0-9_-]+)}i,
  'Facebook' => %r{https?://(?:www\.)?facebook\.com/(?!sharer\b|tr\b|share\b)[A-Za-z0-9.\-]+}i,
  'Instagram' => %r{https?://(?:www\.)?instagram\.com/(?!p/|reel/|stories/)[A-Za-z0-9_.]+}i,
  'TikTok' => %r{https?://(?:www\.)?tiktok\.com/@[A-Za-z0-9_.]+}i
}.freeze

SOCIAL_DENY_RE = /mich(?:el)?[-_\s]*lieben|\bcoldiq\b/i

def fetch_socials_from_website(website_url)
  return [] if website_url.to_s.empty?

  html = fetch_source_html(website_url)
  return [] if html.nil? || html.empty?

  socials = []
  seen = {}
  SOCIAL_URL_PATTERNS.each do |label, pattern|
    html.scan(pattern) do |_|
      url = Regexp.last_match(0)
      next if url.nil? || url.empty?
      next if SOCIAL_DENY_RE.match?(url)
      next if seen[label]
      seen[label] = true
      socials << { 'label' => label, 'url' => url }
    end
  end
  socials
end

def pricing_from_strings(data)
  candidates = strings_from(data).select do |value|
    value.match?(/plans? start|starts? at|\$\d|free trial|billed|per user/i)
  end.reject { |value| value.start_with?('$') }.uniq

  # The rendered scrape contains pricing cards for many unrelated tools. Keep the
  # evidence in the report, but do not publish pricing unless it is confidently
  # tied to the current product by a future parser.
  [nil, nil, nil, candidates]
end

def features_from_strings(data, product_name)
  # The current ColdIQ scrape is a full rendered page with many nearby related
  # tools. Do not publish feature snippets until they can be resolved to the
  # product object itself.
  []
end

def public_local_image(slug)
  # Try the page slug, then the same slug with a domain-style suffix stripped, so
  # a page slugged "apollo-io" still finds a curated local logo saved as "apollo".
  candidates = [slug, slug.sub(/-(io|com|ai|co|app|net|org|so|xyz|dev|run|rocks|hq)$/, '')].uniq
  candidates.each do |name|
    %w[webp jpg jpeg png avif].each do |extension|
      path = File.join(LOCAL_IMAGE_ROOT, "#{name}.#{extension}")
      return "/assets/img/tools/#{name}.#{extension}" if File.exist?(path)
    end
  end
  nil
end

def review_links(product_name)
  encoded = URI.encode_www_form_component(product_name)
  slug = slugify(product_name)
  [
    { 'source' => 'G2', 'url' => "https://www.g2.com/search?query=#{encoded}" },
    { 'source' => 'Capterra', 'url' => "https://www.capterra.com/search/?query=#{encoded}" },
    { 'source' => 'Product Hunt', 'url' => "https://www.producthunt.com/search?q=#{encoded}" },
    { 'source' => 'Trustpilot', 'url' => "https://www.trustpilot.com/review/#{slug}.com" }
  ]
end

def website_domain(url)
  return nil if url.to_s.empty?

  uri = URI(url) rescue nil
  return nil unless uri && uri.host

  uri.host.sub(/^www\./, '')
end

REVIEW_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'

def review_url_works?(url)
  return false if url.to_s.empty?

  current = url
  3.times do
    uri = URI(current) rescue nil
    return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 10) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = REVIEW_USER_AGENT
      request['Accept'] = 'text/html'
      http.request(request)
    end

    case response
    when Net::HTTPRedirection
      location = response['location']
      return false if location.to_s.empty?

      # Refuse redirects that land on a search/home page (often = "not found" handler)
      return false if location.match?(/\/search\b|\/$/i) && !location.match?(/\/(?:products|review|p)\//i)

      current = location.start_with?('http') ? location : URI.join(current, location).to_s
    when Net::HTTPSuccess
      body = response.body.to_s
      return false if body.match?(/page not found|we could not find|no results|cannot be found/i) && !body.match?(/reviews|rating/i)
      return true
    when Net::HTTPForbidden, Net::HTTPTooManyRequests
      # likely anti-bot block on a real page — treat as exists
      return true
    else
      return false
    end
  end
  false
rescue StandardError
  false
end

def slug_variations(product_name, website_url)
  variations = [slugify(product_name)]
  domain = website_domain(website_url)
  if domain
    parts = domain.split('.')
    base = parts.first
    tld = parts.last if parts.size > 1
    variations << base if base
    variations << "#{base}-#{tld}" if base && tld
    variations << "#{slugify(product_name)}-#{tld}" if tld
  end
  variations.compact.reject(&:empty?).uniq
end

def first_working_url(template, slugs)
  slugs.each do |slug|
    candidate = format(template, slug)
    return candidate if review_url_works?(candidate)
  end
  nil
end

# Canonical review destinations to surface for every imported tool. Most B2B
# SaaS tools are listed on G2, Capterra, Trustpilot, and Product Hunt, so these
# are included by default (rather than only when the coldiq FAQ name-drops them)
# so the reviews block is populated from more than one place out of the box.
#
# Scores are attached only when the coldiq FAQ states them — the importer never
# invents a rating, and it cannot derive Capterra's numeric product id offline,
# so score-less entries and the Capterra search fallback are flagged in the
# report for a manual verification pass (look up the real score + direct URL).
def discover_review_links(product_name, website_url, faq_answer)
  domain = website_domain(website_url)
  faq_text = faq_answer.to_s.downcase
  slugs = slug_variations(product_name, website_url)

  links = []

  # G2 — anti-bot blocks reliable verification, but try to land on a working
  # product slug, then fall back to the canonical /products/<slug>/reviews path.
  g2_url = first_working_url('https://www.g2.com/products/%s/reviews', slugs) ||
           "https://www.g2.com/products/#{slugs.first}/reviews"
  links << { 'source' => 'G2', 'url' => g2_url }

  # Capterra — the numeric product id can't be derived from the scrape, so use
  # the directory search as a fallback (flagged in the report for a direct URL).
  links << {
    'source' => 'Capterra',
    'url' => "https://www.capterra.com/search/?query=#{URI.encode_www_form_component(product_name)}"
  }

  # Trustpilot — built from the real product domain when we have one.
  if domain
    links << { 'source' => 'Trustpilot', 'url' => "https://www.trustpilot.com/review/#{domain}" }
  end

  # Product Hunt — direct verification works (no aggressive anti-bot), so only
  # include it when a real product page actually resolves.
  if (ph = first_working_url('https://www.producthunt.com/products/%s', slugs))
    links << { 'source' => 'Product Hunt', 'url' => ph }
  end

  # Chrome Store — only when the tool actually ships an extension.
  if faq_text.match?(/chrome\s*(?:store|extension|web)/)
    links << {
      'source' => 'Chrome Store',
      'url' => "https://chromewebstore.google.com/search/#{URI.encode_www_form_component("#{product_name} Chrome extension")}"
    }
  end

  links.uniq { |l| l['source'] }.first(5).map do |link|
    score = score_from_description(faq_answer, link['source'])
    score ? link.merge('score' => score) : link
  end
end

# Read review_links already curated on an existing tool page so a re-import
# (which rebuilds the whole front matter from the scrape) does not clobber
# manually verified scores and direct review URLs.
def existing_review_links(slug)
  path = File.join(TOOL_PAGE_ROOT, "#{slug}.md")
  return [] unless File.exist?(path)

  content = File.read(path)
  # Match Jekyll's front-matter fences precisely: the closing delimiter must be a
  # line that is only '---' (plus optional trailing space), so a '---' appearing
  # inside a multi-line scraped value can't truncate the capture and silently drop
  # curated review_links on re-import.
  return [] unless content =~ /\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\z)/m

  front_matter = YAML.safe_load(Regexp.last_match(1), permitted_classes: [Time, Date], aliases: true)
  Array(front_matter && front_matter['review_links']).select { |link| link.is_a?(Hash) && link['source'] && link['url'] }
rescue Psych::SyntaxError
  []
end

# Read copy that was already rewritten on a previous import so a re-import reuses
# it instead of calling (and paying for) the Claude API again, and never reverts
# to the scraped duplicate text. Mirrors existing_review_links. Returns the prior
# rewritten fields when the page is marked import.rewritten == true, else nil.
def existing_rewrite(slug)
  path = File.join(TOOL_PAGE_ROOT, "#{slug}.md")
  return nil unless File.exist?(path)

  content = File.read(path)
  return nil unless content =~ /\A---[ \t]*\n(.*?)\n---[ \t]*(?:\n|\z)/m

  fm = YAML.safe_load(Regexp.last_match(1), permitted_classes: [Time, Date], aliases: true)
  return nil unless fm.is_a?(Hash) && fm.dig('import', 'rewritten') == true

  {
    'description' => fm['description'],
    'tagline' => fm['tagline'],
    'overview' => fm['overview'],
    'what_is' => fm.dig('what_is', 'description'), # stored as a paragraph array
    'rewritten_at' => fm.dig('import', 'rewritten_at')
  }
rescue Psych::SyntaxError
  nil
end

# No-API rewrite: read the rewritten copy from a sidecar that Claude (or a human)
# authored at tools-import/rewrites/<slug>.json, so the page can publish original
# wording without calling the Anthropic API. Same hash shape as existing_rewrite.
# Only consulted when the page is not already rewritten (existing_rewrite wins).
# Returns nil when the file is absent, invalid JSON, or missing required copy.
def load_supplied_rewrite(slug)
  path = File.join(REWRITE_SIDECAR_ROOT, "#{slug}.json")
  return nil unless File.exist?(path)

  raw = JSON.parse(File.read(path))
  return nil unless raw.is_a?(Hash)

  description = clamp_meta(sanitize_brand(raw['description']), 160)
  overview = sanitize_brand(raw['overview'])
  return nil if description.empty? || overview.empty?

  what_is = sanitize_paragraphs(raw['what_is'])
  {
    'description' => description,
    'tagline' => (raw['tagline'].to_s.strip.empty? ? nil : sanitize_brand(raw['tagline'])),
    'overview' => overview,
    'what_is' => (what_is.empty? ? nil : what_is),
    'rewritten_at' => Time.now.utc.iso8601
  }
rescue JSON::ParserError
  warn "import-tool: #{path} is not valid JSON; ignoring supplied rewrite."
  nil
end

# Optional website fallback from the rewrite sidecar, used when the scrape's visit
# URL can't be resolved (e.g. Apollo). Lets us pin a canonical product URL without
# a manual page edit that a re-import would overwrite.
def supplied_website(slug)
  path = File.join(REWRITE_SIDECAR_ROOT, "#{slug}.json")
  return nil unless File.exist?(path)

  raw = JSON.parse(File.read(path))
  website = raw.is_a?(Hash) ? raw['website'].to_s.strip : ''
  website.empty? ? nil : website
rescue JSON::ParserError
  nil
end

# Optional curated categories from the rewrite sidecar, prepended ahead of the
# scraped ones so a hand-picked tool keeps a clean PRIMARY category (e.g. Apollo =
# "Prospecting") for the featured strip and card label, while the granular scraped
# categories remain for the directory filter. Accepts "categories" (array) or
# "primary_category" (string). Survives re-import because it lives in the sidecar.
def supplied_categories(slug)
  path = File.join(REWRITE_SIDECAR_ROOT, "#{slug}.json")
  return [] unless File.exist?(path)

  raw = JSON.parse(File.read(path))
  return [] unless raw.is_a?(Hash)

  Array(raw['categories'] || raw['primary_category']).map { |category| text(category) }.reject(&:empty?)
rescue JSON::ParserError
  []
end

# Keep curated entries (verified scores / direct URLs win), then append any
# newly discovered sources the page does not list yet.
def merge_review_links(existing, discovered)
  merged = Array(existing).dup
  seen = merged.map { |link| link['source'] }
  discovered.each do |link|
    next if seen.include?(link['source'])

    merged << link
    seen << link['source']
  end
  merged.first(5)
end

# Use-case strings for the single-tool "See how teams use {tool}" section.
# Prefer real scraped feature titles; fall back to categories. No invented copy.
def use_cases_from(features, categories)
  titles = Array(features).map { |feature| feature.is_a?(Hash) ? (feature['title'] || feature['description']) : feature }
  titles = titles.map { |title| text(title) }.reject(&:empty?)
  titles = Array(categories).map { |category| text(category) }.reject(&:empty?) if titles.empty?
  titles.uniq.first(6)
end

def chrome_store_review_link(product_name)
  encoded = URI.encode_www_form_component("#{product_name} Chrome extension")
  { 'source' => 'Chrome Store', 'url' => "https://chromewebstore.google.com/search/#{encoded}" }
end

def fetch_reader_markdown(source_url)
  return nil if source_url.to_s.empty?

  reader_url = URI("https://r.jina.ai/http://r.jina.ai/http://#{source_url}")
  response = Net::HTTP.start(reader_url.host, reader_url.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
    http.get(reader_url.request_uri)
  end
  return nil unless response.is_a?(Net::HTTPSuccess)

  response.body.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
rescue StandardError
  nil
end

def resolve_redirect(url, max_hops: 6)
  return nil if url.to_s.empty?

  current = url
  max_hops.times do
    uri = URI(current) rescue nil
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 20) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = 'Mozilla/5.0 (compatible; 1SecondLeadsImporter/1.0)'
      http.request(request)
    end

    case response
    when Net::HTTPRedirection
      location = response['location']
      return current if location.to_s.empty?

      current = location.start_with?('http') ? location : URI.join(current, location).to_s
      next
    when Net::HTTPSuccess
      meta = response.body.to_s.match(/<meta[^>]+http-equiv=["']refresh["'][^>]+content=["'][^;]*;\s*url=([^"']+)["']/i)
      if meta
        target = meta[1]
        current = target.start_with?('http') ? target : URI.join(current, target).to_s
        next
      end
      return current
    else
      return current
    end
  end
  current
rescue StandardError
  nil
end

def canonical_product_url(url)
  return nil if url.to_s.empty?

  uri = URI(url) rescue nil
  return nil unless uri && uri.host

  host = uri.host.sub(/^www\./, '')
  return nil if host.empty?

  "https://#{host}/"
end

def fetch_source_html(source_url, max_hops: 6)
  return nil if source_url.to_s.empty?

  current = source_url
  max_hops.times do
    url = URI(current) rescue nil
    return nil unless url.is_a?(URI::HTTP) || url.is_a?(URI::HTTPS)

    response = Net::HTTP.start(url.host, url.port, use_ssl: url.scheme == 'https', open_timeout: 10, read_timeout: 30) do |http|
      request = Net::HTTP::Get.new(url.request_uri)
      request['User-Agent'] = 'Mozilla/5.0 (compatible; 1SecondLeadsImporter/1.0)'
      request['Accept'] = 'text/html,application/xhtml+xml'
      http.request(request)
    end

    case response
    when Net::HTTPRedirection
      location = response['location']
      return nil if location.to_s.empty?

      current = location.start_with?('http') ? location : URI.join(current, location).to_s
    when Net::HTTPSuccess
      return response.body.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
    else
      return nil
    end
  end
  nil
rescue StandardError
  nil
end

REWRITE_SYSTEM_PROMPT = <<~PROMPT.freeze
  You are a B2B SaaS copywriter for 1SecondLeads, a company that helps B2B teams
  choose and implement outbound sales tools.

  Your job: rewrite scraped marketing copy into original wording so it does not
  duplicate the source website, while keeping every fact accurate.

  Voice: direct, B2B, performance-driven. Concrete, not fluffy.

  HARD RULES:
  - Never use emoji.
  - Never use em dashes.
  - Do not invent features, integrations, pricing, numbers, or customers.
  - Keep the same meaning and facts as the input (what the tool does, who it is for). Only change the wording.
  - "description" must be SEO friendly and about 150 characters (max 160). It is the HTML meta description. One sentence, no surrounding quotes.
  - "tagline" is a short phrase under 80 characters. If the input tagline is empty or null, return an empty string.
  - "overview" is 1 to 2 sentences.
  - "what_is" is 2 to 4 sentences describing what the tool is and who it serves.
  - Plain text only. No markdown, no surrounding quotes.

  Respond with a single JSON object and nothing else (no markdown, no code fences),
  using exactly these keys:
  { "description": "string", "tagline": "string", "overview": "string", "what_is": "string" }
PROMPT

# Pull the JSON object out of a model reply, tolerating stray prose or ```json fences.
def extract_json(content)
  body = content.to_s.strip.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/, '')
  start = body.index('{')
  finish = body.rindex('}')
  return nil unless start && finish && finish > start

  JSON.parse(body[start..finish])
rescue JSON::ParserError
  nil
end

# POST to the Anthropic (Claude) Messages API and return the JSON object the model
# emitted, or nil on any failure. Never raises so a bulk import keeps going and the
# page is simply blocked instead.
def anthropic_chat_json(system_prompt, user_prompt)
  return nil unless rewrite_active?

  uri = URI("#{ANTHROPIC_API_BASE}/v1/messages")
  body = {
    'model' => ANTHROPIC_REWRITE_MODEL,
    'max_tokens' => 1024,
    'temperature' => 0.7,
    'system' => system_prompt,
    'messages' => [{ 'role' => 'user', 'content' => user_prompt }]
  }

  attempt = 0
  loop do
    attempt += 1
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: REWRITE_TIMEOUT) do |http|
      request = Net::HTTP::Post.new(uri.request_uri)
      request['x-api-key'] = ANTHROPIC_API_KEY
      request['anthropic-version'] = ANTHROPIC_VERSION
      request['content-type'] = 'application/json'
      request.body = JSON.generate(body)
      http.request(request)
    end

    case response
    when Net::HTTPSuccess
      content = Array(JSON.parse(response.body)['content']).map { |block| block['text'] }.compact.join
      return nil if content.to_s.empty?

      return extract_json(content)
    when Net::HTTPTooManyRequests, Net::HTTPServerError
      return nil if attempt >= REWRITE_MAX_RETRIES

      sleep(2**attempt)
    else
      warn "import-tool: Anthropic #{response.code} #{response.message}"
      return nil
    end
  end
rescue StandardError => e
  warn "import-tool: Anthropic request failed (#{e.class}: #{e.message})"
  nil
end

# Defensively enforce the hard brand rules even if the model slips: strip emoji,
# turn em/en dashes into " - ", and collapse to single-line prose.
def sanitize_brand(value)
  return value if value.to_s.empty?

  text(value)
    .gsub(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}️]/, '')
    .gsub(/\s*[–—]\s*/, ' - ')
    .gsub(/\s+/, ' ')
    .strip
end

# Keep the meta description within Google's snippet length, truncating on a word
# boundary when needed.
def clamp_meta(value, max)
  str = value.to_s.strip
  return str if str.length <= max

  truncated = str[0, max]
  cut = truncated.rindex(/[\s.,;:]/) || max
  truncated[0, cut].strip
end

# sanitize_brand collapses newlines to a single line, so apply it PER paragraph to
# keep paragraph boundaries. Accepts an array (kept as paragraphs) or a string (split).
def sanitize_paragraphs(value)
  paragraphs = value.is_a?(Array) ? value : split_into_paragraphs(value.to_s)
  paragraphs.map { |paragraph| sanitize_brand(paragraph) }.reject(&:empty?)
end

# Rewrite the scraped copy via Claude. Returns a hash of rewritten strings, or nil
# when rewriting is unavailable or the result is unusable (so the caller blocks
# publish rather than shipping duplicate or empty text).
def rewrite_copy(name, fields)
  return nil unless rewrite_active?

  user_prompt = JSON.generate(
    'tool_name' => name,
    'instructions' => 'Rewrite each provided field into original copy. Preserve all facts ' \
                      '(what the tool does, who it is for). Do not invent features, numbers, or claims. ' \
                      'Keep description about 150 characters and SEO friendly.',
    'fields' => {
      'description' => fields['description'],
      'tagline' => fields['tagline'],
      'overview' => fields['overview'],
      'what_is' => fields['what_is']
    }
  )

  result = anthropic_chat_json(REWRITE_SYSTEM_PROMPT, user_prompt)
  return nil unless result.is_a?(Hash)

  out = {
    'description' => clamp_meta(sanitize_brand(result['description']), 160),
    'tagline' => (result['tagline'].to_s.strip.empty? ? nil : sanitize_brand(result['tagline'])),
    'overview' => sanitize_brand(result['overview']),
    'what_is' => sanitize_brand(result['what_is'])
  }
  return nil if out['description'].to_s.empty? || out['overview'].to_s.empty?

  out
end

def html_entities(value)
  CGI.unescapeHTML(text(value).gsub('&nbsp;', ' '))
end

def markdown_lines(markdown)
  markdown.to_s.lines.map { |line| text(line) }.reject(&:empty?)
end

def markdown_section(lines, heading_pattern, stop_pattern = /^## /)
  start = lines.find_index { |line| line.match?(heading_pattern) }
  return [] unless start

  section = []
  lines[(start + 1)..].to_a.each do |line|
    break if line.match?(stop_pattern)

    section << line
  end
  section
end

def split_into_paragraphs(text, paragraph_count: 3)
  return [] if text.to_s.strip.empty?

  sentences = text.split(/(?<=[.!?])\s+(?=[A-Z])/).map(&:strip).reject(&:empty?)
  return [text] if sentences.size < 2

  effective_count = [paragraph_count, sentences.size].min
  per_paragraph = (sentences.size.to_f / effective_count).ceil
  sentences.each_slice(per_paragraph).map { |slice| slice.join(' ') }
end

BADGE_LABEL_RE = /\A(ColdIQ Choice|Editor'?s? Pick|Top Pick|Featured|Recommended|Verified|New|Trending|Popular|Premium|Beta)\z/i

# Scraped alternative blocks carry coldiq UI chrome (badges, CTA labels, directory
# boilerplate) that must never land in a tool's description or category list.
ALT_NOISE_RE = /\A(Claim the Product|Be the first to review|Get|View|Visit|Learn more|Show More|See more|\+\s*\d+\s*more|Ask about.*)\z/i

# Compare product names ignoring a domain-style suffix and punctuation, so an
# alternatives list that names the tool itself ("Apollo") is recognised as a
# self-reference even when the page's product name carries a suffix ("Apollo.io").
def base_product_name(value)
  text(value).downcase.sub(/\.(io|com|ai|co|app|net|org|so|xyz|dev|run|rocks|hq)\b.*$/, '').gsub(/[^a-z0-9]+/, '')
end

def same_product?(name_a, name_b)
  return false if name_a.to_s.empty? || name_b.to_s.empty?

  base_product_name(name_a) == base_product_name(name_b)
end

ICP_SEGMENT_RE = /\A(Solopreneurs?|Freelancers?|Startups?|Scale[\s-]?ups?|SMBs?|Mid[\s-]?market|Enterprises?|Agencies?|Consultanc(?:y|ies)|Non[\s-]?profits?|Educational? institutions?|Government)\z/i

def find_short_tagline(lines, product_name)
  return nil if lines.empty? || product_name.to_s.empty?

  name_idx = lines.find_index { |line| line.strip == product_name }
  return nil unless name_idx

  lines[(name_idx + 1)..(name_idx + 8)].to_a.each do |candidate|
    candidate = candidate.to_s.strip
    next if candidate.empty? || candidate.length < 8 || candidate.length > 100
    next if candidate.start_with?(product_name + ' ')
    next if candidate.start_with?('!', '[', '#', '*')
    next if candidate.include?('http')
    next if candidate.match?(/\AAsk about/i)
    next if candidate.match?(BADGE_LABEL_RE)
    return candidate
  end
  nil
end

def paragraph_from_section(section)
  section.find do |line|
    line.length > 80 && !line.start_with?('[', '!', '#', '*', 'Complexity') && !line.match?(/^Video \d+/)
  end
end

def youtube_embed(markdown)
  match = markdown.to_s.match(%r{https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]+)})
  match ? "https://www.youtube.com/embed/#{match[1]}" : nil
end

def reader_details(markdown, product_name)
  lines = markdown_lines(markdown)
  return {} if lines.empty?

  what_is_section = markdown_section(lines, /^## What is #{Regexp.escape(product_name)}\b/i)
  icp_section = markdown_section(lines, /^## Ideal Customer Profile/i)
  features_section = markdown_section(lines, /^## Key Features/i)
  pricing_section = markdown_section(lines, /^## Pricing/i, /^## /)
  faq_section = markdown_section(lines, /^## Frequently Asked Questions/i)
  alternatives_section = markdown_section(lines, /^## What are #{Regexp.escape(product_name)} alternatives\?/i)

  overview = lines.find { |line| line.start_with?("#{product_name} helps ") }
  tagline = find_short_tagline(lines, product_name) ||
            lines.find { |line| line.include?(' - ') && line.length < 90 && !line.start_with?('Title:', 'URL ') }
  what_is = paragraph_from_section(what_is_section)
  best_fit = paragraph_from_section(icp_section)
  segments = icp_section.select { |line| line.match?(ICP_SEGMENT_RE) }.uniq
  features = features_section.reject { |line| line.start_with?('[', '![', '*') || line.match?(/\A##?\s/) }.first(8)
  capabilities_start = lines.find_index { |line| line == "#{product_name} Core Capabilities" }
  capabilities = []
  if capabilities_start
    lines[(capabilities_start + 1)..].to_a.each do |line|
      break if line.match?(/\A(Social|Links|Pricing|Who is )\z/i)
      next if line == 'Show More'

      capabilities << line
    end
  end

  starting_at = pricing_section.find { |line| line.match?(/\AStarting price\$?\d/i) }&.sub(/^Starting price/i, '')
  billing = lines.find { |line| line.match?(/\ABilling\s+/i) }&.sub(/^Billing\s+/i, '')
  trial = lines.find { |line| line.match?(/\ATrial\s+/i) }&.sub(/^Trial\s+/i, '')
  # "available" alone is not enough: "Trial isn't available." contains the word
  # too, so a tool with no trial was wrongly tagged Free Trial. Require an
  # affirmative availability (and exclude the negated phrasings).
  trial_available = trial.to_s.match?(/available/i) &&
                    !trial.to_s.match?(/\b(?:isn'?t|is\s+not|not|never|un)\b\s*available|unavailable/i)
  pricing_tier = trial_available ? 'Free Trial' : (starting_at ? 'Paid' : nil)

  faqs = []
  faq_section.each_with_index do |line, index|
    next unless line.end_with?('?')

    answer = faq_section[(index + 1)..].to_a.find { |candidate| !candidate.end_with?('?') && candidate.length > 20 }
    faqs << { 'question' => line, 'answer' => answer } if answer
  end
  faqs = faqs.uniq { |faq| faq['question'] }

  alternatives = parse_alternatives(alternatives_section, product_name)
  pros, cons = pros_cons_from_reader(
    lines, features,
    pricing_starting_at: starting_at,
    pricing_tier: pricing_tier,
    pricing_trial: trial
  )

  compact_hash(
    'tagline' => tagline,
    'overview' => overview,
    'what_is' => what_is,
    'video_embed' => youtube_embed(markdown),
    'best_fit' => best_fit,
    'best_for' => segments,
    'capabilities' => capabilities.first(6),
    'features' => features.map { |feature| { 'title' => feature, 'description' => feature } },
    'pros' => pros,
    'cons' => cons,
    'pricing_tier' => pricing_tier,
    'pricing_starting_at' => starting_at,
    'pricing_billing' => billing,
    'pricing_trial' => trial,
    'faqs' => faqs,
    'alternatives' => alternatives,
    'review_answer' => find_review_answer(faq_section)
  )
end

def find_review_answer(faq_section)
  faq_section.each_with_index do |line, index|
    next unless line.match?(/reviews\?/i)
    return faq_section[(index + 1)..].to_a.find { |c| c.length > 20 }
  end
  nil
end

CON_TEMPLATES = {
  /not built for/i => 'Not built for',
  /not designed for/i => 'Not designed for',
  /not meant for/i => 'Not meant for',
  /isn'?t built for/i => 'Not built for',
  /isn'?t designed for/i => 'Not designed for',
  /isn'?t meant for/i => 'Not meant for',
  /doesn'?t support/i => "Doesn't support",
  /doesn'?t handle/i => "Doesn't handle",
  /doesn'?t allow/i => "Doesn't allow",
  /doesn'?t offer/i => "Doesn't offer",
  /doesn'?t include/i => "Doesn't include",
  /lacks/i => 'Lacks',
  /limited to/i => 'Limited to'
}.freeze

CON_EXTRACTION_PATTERNS = [
  /\b(not (?:built|designed|meant) for|isn'?t (?:built|designed|meant) for|doesn'?t (?:support|handle|allow|offer|include)|lacks|limited to)\b\s+([^.,;()]+?)(?=\s+(?:but\s|and\s+(?:also|yet)|or\s)|[.,;()]|$)/i
].freeze

INVERB_VERBS_RE = /\A(Verify|Find|Send|Get|Export|Reduce|Access|Start|Use|Integrate|Build|Manage|Track|Convert|Generate|Discover|Search|Enrich|Automate|Schedule|Sync|Improve|Increase|Boost|Personalize|Validate|Identify|Optimize|Engage|Capture|Connect|Save|Score|Monitor|Analyze|Scrape|Compare|Pull|Filter|Collect|Run|Launch|Create|Provide|Deliver|Offer|Receive|Trigger|Forward|Browse|Visualize|Map|Plan)\b/

def smart_capitalize(text)
  text.to_s.sub(/^([a-z])/) { Regexp.last_match(1).upcase }
end

def ensure_sentence_period(text)
  text.match?(/[.!?]$/) ? text : "#{text}."
end

def imperative_to_declarative(phrase)
  phrase.sub(INVERB_VERBS_RE) do
    base = Regexp.last_match(1)
    if base.match?(/(?:s|sh|ch|x|z|o)$/i)
      "#{base}es"
    elsif base.match?(/[^aeiou]y$/i)
      "#{base[0..-2]}ies"
    else
      "#{base}s"
    end
  end
end

def short_pros_from_features(features)
  return [] unless features.is_a?(Array)

  features.first(5).filter_map do |feature|
    title = feature.is_a?(Hash) ? (feature['title'] || feature['description']) : feature
    next nil if title.to_s.strip.empty?

    text = imperative_to_declarative(smart_capitalize(title.to_s.strip))
    ensure_sentence_period(text)
  end
end

def template_for_marker(marker)
  CON_TEMPLATES.each do |pattern, template|
    return template if marker.match?(pattern)
  end
  smart_capitalize(marker.downcase)
end

def short_cons_from_text(text)
  return [] if text.to_s.strip.empty?

  cons = []
  CON_EXTRACTION_PATTERNS.each do |pattern|
    text.scan(pattern) do |marker, target|
      target = target.to_s.strip.downcase
      next if target.empty? || target.length > 80

      template = template_for_marker(marker)
      cons << ensure_sentence_period("#{template} #{target}")
    end
  end

  cons.uniq.first(5)
end

GENERIC_CONS_POOL = [
  'Some advanced features are locked behind higher-tier plans.',
  'Initial setup and onboarding may take time for new users.',
  'Best long-term value typically requires annual billing.',
  'Customer support responsiveness varies by plan tier.',
  'Granular reporting may require add-ons or higher tiers.'
].freeze

def cons_from_pricing(text, pricing_starting_at, pricing_tier, pricing_trial)
  cons = []
  starting = pricing_starting_at.to_s
  trial = pricing_trial.to_s
  tier = pricing_tier.to_s.downcase

  if starting.match?(/talk to sales|not listed|not publicly|contact us|enterprise pricing|not provided|on request/i)
    cons << 'Pricing is not publicly listed; requires a sales conversation.'
  end

  no_trial_signal = trial.empty? || trial.match?(/not available|isn'?t available|no trial|trial isn'?t/i)
  unless tier.include?('trial') || tier.include?('freemium') || tier.include?('free')
    cons << 'No free plan available.' if !text.match?(/free plan|gratuit|free tier/i)
  end
  cons << 'No free trial available.' if no_trial_signal && !text.match?(/trial available|free trial/i)

  if (price_match = starting.match(/\$\s?(\d+(?:\.\d+)?)/))
    dollars = price_match[1].to_f
    cons << 'Higher entry pricing than several competitors.' if dollars >= 80
  end

  cons
end

def pros_cons_from_reader(lines, features, pricing_starting_at: nil, pricing_tier: nil, pricing_trial: nil)
  text = lines.join(' ')
  pros = short_pros_from_features(features)

  if pros.size < 5 && text.match?(/free plan|gratuit/i) && pros.none? { |p| p.downcase.include?('free plan') }
    pros << 'Free plan available.'
  end
  if pros.size < 5 && text.match?(/trial available/i) && pros.none? { |p| p.downcase.include?('trial') }
    pros << 'Free trial available.'
  end

  cons = short_cons_from_text(text)
  if cons.size < 3
    pricing_cons = cons_from_pricing(text, pricing_starting_at, pricing_tier, pricing_trial)
    cons.concat(pricing_cons)
  end
  GENERIC_CONS_POOL.each do |generic|
    break if cons.size >= 3
    cons << generic unless cons.any? { |c| c == generic }
  end

  [pros.uniq.first(5), cons.uniq.first(5)]
end

def html_details(html, product_name)
  return {} if html.to_s.empty?

  compact_hash(
    'categories' => extract_visible_categories(html, product_name),
    'website' => extract_visit_url(html, product_name),
    'alternatives' => parse_alternatives_from_html(html, product_name)
  )
end

def extract_visible_categories(html, product_name)
  start_index = html.index("#{product_name} helps ") || html.index("#{product_name} Core Capabilities") || 0
  tail = html[start_index..]
  stop_index = tail.index('Ask about') || tail.index("#{product_name} Core Capabilities") || tail.length
  segment = tail[0...stop_index]

  segment.scan(%r{href="/category/[^"]+"[^>]*>(.*?)</a>}mi).map do |match|
    html_entities(match[0].gsub(/<[^>]+>/, ' '))
  end.reject(&:empty?).uniq.first(10)
end

def extract_visit_url(html, product_name)
  escaped_name = Regexp.escape(product_name)
  match = html.match(/href="([^"]+)"[^>]*title="Get #{escaped_name}"/i) ||
          html.match(/href="([^"]+)"[^>]*>\s*Get #{escaped_name}\s*</i)
  raw_url = html_entities(match[1]) if match
  return nil unless raw_url

  if raw_url.match?(%r{//(go\.|aff\.)?coldiq\.com/})
    resolved = resolve_redirect(raw_url)
    canonical = canonical_product_url(resolved)
    # Never leak a coldiq affiliate URL: if the redirect can't be resolved to the
    # tool's real domain, return nil (the report flags the missing website, and a
    # sidecar `website` can supply it) rather than publishing the coldiq link.
    canonical && (canonical =~ /coldiq\.com/ ? nil : canonical)
  else
    canonical_product_url(raw_url) || raw_url
  end
end

def parse_alternatives_from_html(html, product_name)
  start_index = html.index("What are #{product_name} alternatives?")
  return [] unless start_index

  tail = html[start_index..]
  stop_index = tail.index("Who uses #{product_name}?") || tail.index('Frequently Asked Questions') || tail.length
  segment = tail[0...stop_index]
  segment = segment.gsub(/<img\b[^>]*alt="([^"]+)"[^>]*src="([^"]+)"[^>]*>/i) do
    "\nALT_IMAGE:#{$1}|#{$2}\n"
  end
  lines = segment.gsub(/<[^>]+>/, "\n")
                 .lines
                 .map { |line| html_entities(line) }
                 .reject(&:empty?)

  alternatives = []
  current = nil
  pending_field = nil
  lines.each do |line|
    break if line.match?(/\AWho uses\z/i)

    if line.start_with?('ALT_IMAGE:')
      alternatives << current if current && current['name'] && !same_product?(current['name'], product_name)
      name, image = line.sub('ALT_IMAGE:', '').split('|', 2)
      current = { 'name' => name, 'logoUrl' => image, 'categories' => [] }
      pending_field = nil
      next
    end
    next unless current
    next if line == current['name'] || line == 'View'
    # Drop coldiq badges/CTA chrome so they never become a description or category.
    next if line.match?(ALT_NOISE_RE) || line.match?(BADGE_LABEL_RE)

    if line.start_with?('Pricing:')
      value = line.sub(/^Pricing:\s*/i, '').sub(/^Starting at\s*/i, '').strip
      if value.empty?
        pending_field = 'pricing_starting_at'
      else
        current['pricing_starting_at'] = value
      end
    elsif line.start_with?('Trial:')
      value = line.sub(/^Trial:\s*/i, '').strip
      if value.empty?
        pending_field = 'trial'
      else
        current['trial'] = value
      end
    elsif pending_field
      value = line.sub(/^Starting at\s*/i, '').strip
      current[pending_field] = value
      pending_field = nil
    elsif current['description'].nil? && line.length > 8 && !line.include?(':')
      current['description'] = line
    elsif line.length < 70 && !line.match?(/\A\+\d+ more\z/i) && !line.match?(/\AWiza\z/i)
      current['categories'] << line
    end
  end
  alternatives << current if current && current['name'] && !same_product?(current['name'], product_name)
  alternatives.first(8)
end

def parse_alternatives(section, product_name)
  alternatives = []
  current = nil

  section.each do |line|
    if (match = line.match(/!\[.*?:\s*([^\]]+)\]\(([^)]+)\)/))
      alternatives << current if current
      current = { 'name' => text(match[1]), 'logoUrl' => text(match[2]), 'categories' => [] }
      current = nil if same_product?(current['name'], product_name)
      next
    end
    next unless current
    next if line == current['name'] || line == 'View'
    next if line.match?(ALT_NOISE_RE) || line.match?(BADGE_LABEL_RE)

    if line.start_with?('Pricing:')
      current['pricing_starting_at'] = line.sub(/^Pricing:\s*Starting at\s*/i, '').strip
    elsif line.start_with?('Trial:')
      current['trial'] = line.sub(/^Trial:\s*/i, '').strip
    elsif current['description'].nil? && line.length > 8 && !line.include?(':')
      current['description'] = line
    elsif line.length < 60 && !line.start_with?('[', '![', '#')
      current['categories'] << line
    end
  end

  alternatives << current if current
  alternatives.compact.first(8)
end

def score_from_description(description, source)
  return nil if description.to_s.empty? || source.to_s.empty?

  escaped = Regexp.escape(source)
  patterns = [
    /(\d(?:\.\d)?)\s*\/\s*5\b[^.]{0,40}?\bon\s+(?:the\s+)?#{escaped}\b/i,
    /\b#{escaped}\b[^.]{0,40}?(\d(?:\.\d)?)\s*\/\s*5\b/i,
    /\b#{escaped}\b[^.]{0,40}?(\d(?:\.\d)?)\s+stars?\b/i
  ]
  patterns.each do |pattern|
    match = description.match(pattern)
    return "#{match[1]}/5" if match
  end
  nil
end

def review_links_from_text(faq_section, product_name)
  review_answer = nil
  faq_section.each_with_index do |line, index|
    next unless line.match?(/reviews\?/i)

    review_answer = faq_section[(index + 1)..].to_a.find { |candidate| candidate.length > 20 }
  end
  links = review_links(product_name)
  if review_answer&.match?(/chrome store/i)
    links = [links.first, chrome_store_review_link(product_name)] + links[1..]
  end

  links.uniq { |link| link['source'] }.first(4).map do |link|
    enriched = link.dup
    score = score_from_description(review_answer, link['source'])
    enriched['score'] = score if score
    enriched
  end
end

def build_tool_page(data, source_path)
  name = find_product_name(data)
  raise "Could not determine tool name from #{source_path}" if name.empty?

  slug = slugify(name)
  product_id = find_product_id(data, name)
  description = text(find_meta(data, 'name', 'description')&.fetch('content', nil) ||
                     find_meta(data, 'property', 'og:description')&.fetch('content', nil))
  source_url = text(find_meta(data, 'rel', 'canonical')&.fetch('href', nil) ||
                    find_meta(data, 'property', 'og:url')&.fetch('content', nil))
  reader = reader_details(fetch_reader_markdown(source_url), name)
  html = html_details(fetch_source_html(source_url), name)
  image_source_url = text(find_meta(data, 'property', 'og:image')&.fetch('content', nil) ||
                          find_meta(data, 'name', 'twitter:image')&.fetch('content', nil))
  raw_categories = scraped_categories(data, product_id)
  categories = product_categories(raw_categories, html['categories'])
  # Fallback must still drop the broad buckets product_categories rejects, otherwise
  # a tool tagged only with 'DATA SOURCES'/'GTM TOOLS' etc. would re-introduce exactly
  # the low-value categories the filter taxonomy is built to exclude. If nothing real
  # remains, leave it empty — the report flags missing categories for a manual pass.
  if categories.empty?
    categories = normalize_categories(raw_categories)
                 .reject { |category| too_broad_category?(category) }
                 .first(10)
  end
  # Prepend any curated primary category supplied via the sidecar so it leads the
  # list (used for the featured strip and card label), keeping the granular ones.
  supplied_cats = supplied_categories(slug)
  categories = (supplied_cats + categories).uniq.first(10) unless supplied_cats.empty?
  pricing_tier, pricing_starting_at, pricing_billing, pricing_candidates = pricing_from_strings(data)
  pricing_tier = reader['pricing_tier'] || pricing_tier
  pricing_starting_at = reader['pricing_starting_at'] || pricing_starting_at
  pricing_billing = reader['pricing_billing'] || pricing_billing
  socials = social_links(data)
  if socials.empty? && html['website']
    socials = fetch_socials_from_website(html['website'])
  end
  features = reader['features'] || features_from_strings(data, name)
  local_image = public_local_image(slug)
  overview = reader['overview'] || description
  what_is_description = reader['what_is'] || overview
  best_for = reader['best_for'] || []

  # Rewrite the hero + "What is" copy and the SEO meta description into original
  # wording so we don't publish coldiq's text verbatim. Reuse a prior rewrite if
  # the page already has one (no API re-charge); otherwise call Claude; otherwise
  # record why we couldn't and block publish below.
  # Precedence: a prior page rewrite (existing) > a supplied sidecar > the Claude API
  # > blocked. The supplied sidecar lets us publish original copy with no API key.
  rewritten = existing_rewrite(slug)
  reused_rewrite = !rewritten.nil?
  rewrite_source = reused_rewrite ? 'existing' : nil
  blocked_reason = nil
  unless rewritten
    if (supplied = load_supplied_rewrite(slug))
      rewritten = supplied
      rewrite_source = 'supplied'
    elsif !REWRITE_ENABLED
      blocked_reason = 'disabled'
    elsif ANTHROPIC_API_KEY.empty?
      blocked_reason = 'no api key'
    else
      rewritten = rewrite_copy(name,
                               'description' => description,
                               'tagline' => reader['tagline'],
                               'overview' => overview,
                               'what_is' => what_is_description)
      if rewritten
        rewrite_source = 'api'
      else
        blocked_reason = 'rewrite failed'
      end
    end
  end
  copy_rewritten = !rewritten.nil?

  what_is_paragraphs = nil
  if copy_rewritten
    description = rewritten['description'] unless rewritten['description'].to_s.empty?
    overview = rewritten['overview'] unless rewritten['overview'].to_s.empty?
    wi = rewritten['what_is']
    if wi.is_a?(Array)
      what_is_paragraphs = wi # preserve the rewritten paragraph array verbatim
      what_is_description = wi.join(' ')
    else
      what_is_description = wi.to_s
    end
    tagline_value = rewritten['tagline']
    rewritten_at = reused_rewrite ? rewritten['rewritten_at'] : (rewritten['rewritten_at'] || Time.now.utc.iso8601)
  else
    tagline_value = reader['tagline']
    rewritten_at = nil
  end

  page = compact_hash(
    'title' => name,
    'description' => description,
    'category' => categories.first,
    'categories' => categories,
    'logoUrl' => local_image || image_source_url,
    'tagline' => tagline_value,
    'pricing_tier' => pricing_tier,
    'primary_use_case' => categories.first,
    # Supplied (curated) website wins over the scraped one so we can pin a real
    # domain when extraction returns nothing usable or a coldiq affiliate URL.
    'website' => (supplied_website(slug) || html['website']),
    'value_prop' => description,
    'overview' => overview,
    'best_fit' => reader['best_fit'],
    'pricing_summary' => pricing_starting_at,
    'pricing' => compact_hash(
      'starting_at' => (pricing_starting_at&.sub(/^Plans? start at\s*/i, '')&.strip&.then { |s| s.empty? ? nil : s }) || 'Pricing not listed; talk to sales.',
      'billing' => pricing_billing,
      'trial' => reader['pricing_trial'] || (pricing_tier == 'Free Trial' ? 'Available' : nil)
    ),
    'sidebar' => compact_hash(
      'best_for' => best_for,
      'capabilities' => reader['capabilities']
    ),
    'social' => socials,
    'what_is' => compact_hash(
      'title' => "What is #{name}?",
      'description' => (what_is_paragraphs || split_into_paragraphs(what_is_description)),
      'video_label' => "#{name} video walkthrough",
      'embed_url' => reader['video_embed']
    ),
    'pros' => reader['pros'],
    'cons' => reader['cons'],
    'features' => features,
    'use_cases' => use_cases_from(features, categories),
    'implementation_review' => [],
    'review_links' => merge_review_links(
      existing_review_links(slug),
      discover_review_links(name, html['website'], reader['review_answer'])
    ),
    'related_tools' => [],
    'alternatives' => html['alternatives'] || reader['alternatives'],
    'faqs' => reader['faqs'],
    'import' => compact_hash(
      'managed' => true,
      'source_file' => source_path.tr('\\', '/'),
      'source_url' => source_url,
      'image_source_url' => image_source_url,
      'product_id' => product_id,
      'raw_categories' => raw_categories,
      'pricing_candidates' => pricing_candidates,
      'reader_enriched' => !reader.empty?,
      'imported_at' => Time.now.utc.iso8601,
      'rewritten' => copy_rewritten,
      'rewrite_source' => rewrite_source,
      'rewritten_at' => rewritten_at,
      'blocked_reason' => blocked_reason
    )
  )

  # Never let scraped/duplicate copy go live: keep the page unpublished until it
  # has been rewritten (manually re-run with a key, or fixed by hand).
  page['published'] = false unless copy_rewritten

  [slug, page, copy_rewritten]
end

def update_tool_categories(categories)
  existing = load_yaml(CATEGORY_DATA_PATH, [])
  updated = (Array(existing) + categories).map { |category| text(category) }.reject(&:empty?).uniq
  File.write(CATEGORY_DATA_PATH, YAML.dump(updated).sub(/^---\n/, ''))
end

def update_tools_data(slug, page, featured_flag, published)
  tools = load_yaml(TOOLS_DATA_PATH, [])
  # Match an existing entry by its name slug, or by the coldiq source-URL slug a
  # hand-seeded card still carries in `url` (so "Apollo" reconciles with a scrape
  # named "Apollo.io" rather than producing a second card).
  src_slug = coldiq_slug(page.dig('import', 'source_url'))
  index = tools.find_index do |tool|
    slugify(tool['name']) == slug || (src_slug && coldiq_slug(tool['url']) == src_slug)
  end
  existing_featured = index ? !!tools[index]['featured'] : false
  featured = featured_flag.nil? ? existing_featured : featured_flag

  # Only point the directory card at the local page once it is published (rewritten).
  # While blocked, keep any existing external URL (or fall back to the tool's
  # website) so the card never links to an unpublished page that would 404.
  existing_url = index ? tools[index]['url'] : nil
  card_url = if published
               "/tools/#{slug}/"
             elsif existing_url && !existing_url.to_s.start_with?('/tools/')
               existing_url
             else
               page['website']
             end

  entry = compact_hash(
    'name' => page['title'],
    'logoUrl' => page['logoUrl'],
    'categories' => page['categories'],
    'pricing_tier' => page['pricing_tier'],
    'pricing_starting_at' => page.dig('pricing', 'starting_at'),
    # Prefer the page's real, feature-derived use cases (action phrases) for the
    # card chips; fall back to categories only when no use cases were extracted.
    'use_cases' => (Array(page['use_cases']).empty? ? Array(page['categories']) : page['use_cases']).first(3),
    'description' => page['description'],
    'url' => card_url,
    'featured' => featured
  )

  if index
    tools[index] = entry
  else
    tools << entry
  end

  File.write(TOOLS_DATA_PATH, YAML.dump(tools).sub(/^---\n/, ''))
end

def write_report(slug, page)
  FileUtils.mkdir_p(REPORT_ROOT)
  missing = []
  %w[title description categories logoUrl website overview].each do |field|
    value = page[field]
    missing << field if value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end

  review_links = Array(page['review_links'])
  review_link_flags = review_links.map do |link|
    issues = []
    issues << 'no score (verify rating manually)' unless link['score']
    issues << 'search URL (replace with direct review page)' if link['url'].to_s.include?('/search')
    { 'source' => link['source'], 'url' => link['url'], 'score' => link['score'], 'needs_attention' => issues }
  end

  published = page.fetch('published', true)
  rewritten = page.dig('import', 'rewritten') == true
  rewrite_source = page.dig('import', 'rewrite_source')
  blocked = published ? nil : "not rewritten (#{page.dig('import', 'blocked_reason')})"

  report = {
    'tool' => page['title'],
    'slug' => slug,
    'missing_fields' => missing,
    'rewritten' => rewritten,
    'rewrite_source' => rewrite_source,
    'published' => published,
    'blocked' => blocked,
    'categories' => page['categories'],
    'raw_categories' => page.dig('import', 'raw_categories'),
    'social_links' => page['social'],
    'review_links' => review_link_flags,
    'pricing_candidates' => page.dig('import', 'pricing_candidates'),
    'source_url' => page.dig('import', 'source_url'),
    'image_source_url' => page.dig('import', 'image_source_url')
  }

  rewrite_line = if rewritten
                   "original copy (rewritten via #{rewrite_source || 'unknown'})"
                 else
                   "BLOCKED - #{blocked}"
                 end

  File.write(File.join(REPORT_ROOT, "#{slug}.json"), JSON.pretty_generate(report))
  File.write(File.join(REPORT_ROOT, "#{slug}.md"), <<~MD)
    # #{page['title']} Import Report

    - Rewrite: #{rewrite_line}
    - Published: #{published}
    - Missing fields: #{missing.empty? ? 'none' : missing.join(', ')}
    - Categories: #{Array(page['categories']).join(', ')}
    - Source URL: #{page.dig('import', 'source_url')}
    - Image source URL: #{page.dig('import', 'image_source_url')}
    - Social links: #{Array(page['social']).map { |link| "#{link['label']} #{link['url']}" }.join(', ')}
    - Review links: #{review_link_flags.map { |link| "#{link['source']}#{link['score'] ? " #{link['score']}" : ''}#{link['needs_attention'].empty? ? '' : " [#{link['needs_attention'].join('; ')}]"}" }.join(', ')}
    - Pricing candidates: #{Array(page.dig('import', 'pricing_candidates')).join(' | ')}
  MD

  missing
end

featured_flag = nil
emit_drafts = false
positional_args = ARGV.reject do |arg|
  case arg
  when '--featured'
    featured_flag = true
    true
  when '--no-featured'
    featured_flag = false
    true
  when '--emit-rewrite-drafts'
    emit_drafts = true
    true
  else
    false
  end
end
source_path = positional_args[0] || usage
raise "Input file does not exist: #{source_path}" unless File.exist?(source_path)

data = JSON.parse(File.read(source_path))
raise 'Scrape JSON must be a top-level array' unless data.is_a?(Array)

slug, page, copy_rewritten = build_tool_page(data, File.expand_path(source_path))

if emit_drafts
  # Dry run: write ONLY the rewrite sidecar with the extracted raw copy so Claude (or a
  # human) can rewrite it into original wording, then re-import (no key) to publish.
  # Does not touch the page, tools.yml, categories, or reports.
  FileUtils.mkdir_p(REWRITE_SIDECAR_ROOT)
  draft = {
    'description' => page['description'],
    'tagline' => page['tagline'],
    'overview' => page['overview'],
    'what_is' => page.dig('what_is', 'description')
  }
  draft_path = File.join(REWRITE_SIDECAR_ROOT, "#{slug}.json")
  File.write(draft_path, JSON.pretty_generate(draft))
  puts "Wrote rewrite draft tools-import/rewrites/#{slug}.json (rewrite the values, then re-import to publish)"
else
  FileUtils.mkdir_p(TOOL_PAGE_ROOT)
  File.write(File.join(TOOL_PAGE_ROOT, "#{slug}.md"), "---\n#{yaml_front_matter(page)}---\n")
  update_tool_categories(page['categories'])
  update_tools_data(slug, page, featured_flag, copy_rewritten)
  missing = write_report(slug, page)

  puts "Imported #{page['title']} to _tool_pages/#{slug}.md"
  puts "Updated _data/tools.yml and _data/tool_categories.yml"
  puts "Missing fields: #{missing.empty? ? 'none' : missing.join(', ')}"
  if copy_rewritten
    puts "Copy: rewritten via #{page.dig('import', 'rewrite_source')} (published)"
  else
    puts "Copy: NOT rewritten - page blocked with published:false (#{page.dig('import', 'blocked_reason')}). Supply tools-import/rewrites/#{slug}.json (or set ANTHROPIC_API_KEY) and re-run to publish."
  end
end
