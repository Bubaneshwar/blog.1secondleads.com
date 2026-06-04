#!/usr/bin/env ruby
# frozen_string_literal: true
# One-off: apply a supplied rewrite sidecar onto an ALREADY-published tool page,
# overriding the previous (light) rewrite. Surgical — only the copy fields change;
# no network, no re-derivation of features/categories/review_links. yaml_front_matter
# in the importer is just YAML.dump, so a round-trip keeps formatting/key-order and
# the diff is limited to the edited fields.
require 'yaml'
require 'json'
require 'time'

ROOT = File.expand_path('..', __dir__)
PAGES = File.join(ROOT, '_tool_pages')
REWRITES = File.join(ROOT, 'tools-import', 'rewrites')

slugs = ARGV.empty? ? %w[cognism gong hunter instantly lusha salesloft snov wiza] : ARGV

slugs.each do |slug|
  page = File.join(PAGES, "#{slug}.md")
  side_path = File.join(REWRITES, "#{slug}.json")
  raise "missing page #{page}" unless File.exist?(page)
  raise "missing sidecar #{side_path}" unless File.exist?(side_path)

  content = File.read(page)
  raise "no front matter in #{slug}" unless content =~ /\A---[ \t]*\n(.*?)\n---[ \t]*\n?(.*)\z/m

  fm = YAML.safe_load(Regexp.last_match(1), permitted_classes: [Time, Date], aliases: true)
  body = Regexp.last_match(2)
  side = JSON.parse(File.read(side_path))

  fm['description'] = side['description']
  fm['value_prop'] = side['description']
  fm['tagline'] = side['tagline'] unless side['tagline'].to_s.strip.empty?
  fm['overview'] = side['overview']
  fm['what_is'] ||= {}
  fm['what_is']['description'] = side['what_is']
  fm['import'] ||= {}
  fm['import']['rewritten'] = true
  fm['import']['rewrite_source'] = 'supplied'
  fm['import']['rewritten_at'] = Time.now.utc.iso8601

  dumped = YAML.dump(fm).sub(/\A---\n/, '')
  File.write(page, "---\n#{dumped}---\n#{body}")
  puts "rewrote #{slug}"
end
