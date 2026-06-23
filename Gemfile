# frozen_string_literal: true

source "https://rubygems.org"

# Pinned to 7.5.0: chirpy 7.6.0's root stylesheet trips the Dart Sass rule that
# a variable configured via `@use ... with (...)` must be declared `!default`,
# which fails the SCSS build. CI has no committed Gemfile.lock, so without an
# exact pin it resolves the broken latest and the Pages build fails. This is the
# theme version the site shipped on; revisit when 7.6.x fixes the SCSS upstream.
gem "jekyll-theme-chirpy", "7.5.0"

gem "html-proofer", "~> 5.0", group: :test

platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem "wdm", "~> 0.2.0", :platforms => [:mingw, :x64_mingw, :mswin]
