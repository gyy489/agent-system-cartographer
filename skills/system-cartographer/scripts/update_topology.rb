#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "pathname"
require "rbconfig"

options = { root: Dir.pwd, strict: false }
OptionParser.new do |opts|
  opts.banner = "Usage: update_topology.rb [options]"
  opts.on("--root PATH", "Project root") { |value| options[:root] = value }
  opts.on("--strict", "Fail when either scanner reports errors") { options[:strict] = true }
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

script_dir = Pathname.new(__dir__)
root = Pathname.new(options.fetch(:root)).expand_path.cleanpath
strict = options[:strict] ? ["--strict"] : []

commands = [
  [RbConfig.ruby, script_dir.join("scan_topology.rb").to_s, "--root", root.to_s, *strict]
]
if root.join("registries/cartography_registry.yaml").file?
  commands << [
    RbConfig.ruby,
    script_dir.join("scan_local_assets.rb").to_s,
    "--root",
    root.to_s,
    *strict
  ]
end

commands.each do |command|
  success = system(*command)
  exit($?.exitstatus || 1) unless success
end
