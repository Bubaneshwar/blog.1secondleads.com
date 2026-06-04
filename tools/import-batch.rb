#!/usr/bin/env ruby
# frozen_string_literal: true

flags = ARGV.select { |arg| arg.start_with?('--') }
positional = ARGV.reject { |arg| arg.start_with?('--') }
input_dir = positional[0]

unless input_dir && Dir.exist?(input_dir)
  warn 'Usage: ruby tools/import-batch.rb [--featured] path/to/scraped-json-folder'
  exit 1
end

root = File.expand_path('..', __dir__)
importer = File.join(root, 'tools', 'import-tool.rb')
files = Dir.glob(File.join(input_dir, '*.json')).sort
failures = []

files.each do |file|
  puts "\n== Importing #{file} =="
  success = system(RbConfig.ruby, importer, *flags, file)
  failures << file unless success
end

puts "\nImported: #{files.size - failures.size}"
puts "Failed: #{failures.size}"
failures.each { |file| puts "- #{file}" }
exit(failures.empty? ? 0 : 1)
