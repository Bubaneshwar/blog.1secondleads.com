# frozen_string_literal: true

source "https://rubygems.org" # Only one source line needed at the top

gemspec # This tells Bundler to look at your jekyll-theme-chirpy.gemspec for dependencies

# Add gems that are NOT runtime dependencies in the .gemspec but you still need for your project
gem "jekyll-feed", "~> 0.17.0" # Adding jekyll-feed as discussed. Using a common recent version.
# gem "jekyll-archives", "~> 2.2.1" # If you need jekyll-archives and it's NOT in the gemspec.
                                   # Your .gemspec *does* list jekyll-archives, so you likely DON'T need this line here.

# Gems for development/testing or specific platforms
gem "html-proofer", "~> 5.0", group: :test

platforms :mingw, :x64_mingw, :mswin, :jruby do
  gem "tzinfo", ">= 1", "< 3"
  gem "tzinfo-data"
end

gem "wdm", "~> 0.2.0", :platforms => [:mingw, :x64_mingw, :mswin] # For better file watching on Windows