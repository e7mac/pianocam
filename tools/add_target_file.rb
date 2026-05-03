#!/usr/bin/env ruby
# Adds a Swift file to one specific target's Sources phase.
# Usage: add_target_file.rb <project> <target_name> <relative_file> <group_name>
require "xcodeproj"

PROJECT_PATH, TARGET_NAME, RELATIVE_FILE, GROUP_NAME = ARGV
abort "usage: add_target_file.rb <project> <target> <file> <group>" unless GROUP_NAME

project = Xcodeproj::Project.open(PROJECT_PATH)
group = project.main_group[GROUP_NAME] || project.main_group.new_group(GROUP_NAME, GROUP_NAME)

basename = File.basename(RELATIVE_FILE)
file_ref = group.files.find { |f| f.path == basename }
unless file_ref
  file_ref = group.new_reference(basename)
  file_ref.last_known_file_type = "sourcecode.swift"
end
file_ref.path = basename

target = project.native_targets.find { |t| t.name == TARGET_NAME }
abort "target #{TARGET_NAME} not found" unless target

src = target.source_build_phase
unless src.files.any? { |bf| bf.file_ref&.path == basename }
  src.add_file_reference(file_ref)
  puts "added #{RELATIVE_FILE} to #{target.name}"
end

project.save
puts "saved #{PROJECT_PATH}"
