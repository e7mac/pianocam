#!/usr/bin/env ruby
# Adds a Swift file (path relative to project root) to the Sources build phase
# of every target in the .xcodeproj. Idempotent.
require "xcodeproj"

PROJECT_PATH = ARGV[0] || "samplecamera.xcodeproj"
RELATIVE_FILE = ARGV[1]
GROUP_NAME = ARGV[2] || "Shared"
abort "usage: add_shared_file.rb <project> <relative_file> [group_name]" unless RELATIVE_FILE

project = Xcodeproj::Project.open(PROJECT_PATH)
group = project.main_group[GROUP_NAME] || project.main_group.new_group(GROUP_NAME, GROUP_NAME)

# File reference (one for the whole project)
file_ref = group.files.find { |f| f.path == File.basename(RELATIVE_FILE) }
unless file_ref
  file_ref = group.new_reference(File.basename(RELATIVE_FILE))
  file_ref.last_known_file_type = "sourcecode.swift"
end
# Set path relative to the group's directory
file_ref.path = File.basename(RELATIVE_FILE)

# Add to every native target's Sources phase if not already present
project.native_targets.each do |target|
  src = target.source_build_phase
  already = src.files.any? { |bf| bf.file_ref&.path == file_ref.path }
  unless already
    src.add_file_reference(file_ref)
    puts "added #{RELATIVE_FILE} to #{target.name}"
  end
end

project.save
puts "saved #{PROJECT_PATH}"
