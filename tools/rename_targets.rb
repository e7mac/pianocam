#!/usr/bin/env ruby
# Renames the project's targets and groups to PianoCam / PianoCamExtension,
# pointing them at renamed folders. File-level renames are done by the shell
# wrapper before this runs.
require "xcodeproj"

PROJECT_PATH = ARGV[0] || "samplecamera.xcodeproj"
project = Xcodeproj::Project.open(PROJECT_PATH)

target_renames = {
  "samplecamera"     => "PianoCam",
  "cameraextension"  => "PianoCamExtension"
}
group_renames = {
  "samplecamera"     => "PianoCam",
  "cameraextension"  => "PianoCamExtension"
}
folder_path_renames = {
  "samplecamera"     => "PianoCam",
  "cameraextension"  => "PianoCamExtension"
}

project.native_targets.each do |t|
  if target_renames.key?(t.name)
    new_name = target_renames[t.name]
    puts "renaming target #{t.name} -> #{new_name}"
    t.name = new_name
    # Bump product name for the host app only (extension keeps cameraextension product
    # name to avoid changing the on-disk .systemextension wrapper that's already
    # working, but adjust as needed).
  end
end

# Rename groups + their child paths
project.main_group.children.each do |g|
  next unless g.respond_to?(:name) && g.respond_to?(:path)
  if group_renames.key?(g.name)
    new_name = group_renames[g.name]
    puts "renaming group #{g.name} -> #{new_name}"
    g.name = new_name
  end
  if g.respond_to?(:path) && g.path && folder_path_renames.key?(g.path)
    new_path = folder_path_renames[g.path]
    puts "renaming group path #{g.path} -> #{new_path}"
    g.path = new_path
  end
end

# Update INFOPLIST_FILE / CODE_SIGN_ENTITLEMENTS paths inside build configurations
project.targets.each do |t|
  t.build_configurations.each do |bc|
    %w[INFOPLIST_FILE CODE_SIGN_ENTITLEMENTS].each do |k|
      v = bc.build_settings[k]
      next unless v.is_a?(String)
      folder_path_renames.each do |old, new_|
        if v.start_with?("#{old}/")
          bc.build_settings[k] = v.sub("#{old}/", "#{new_}/")
          puts "  #{t.name}.#{bc.name}.#{k}: #{v} -> #{bc.build_settings[k]}"
        end
      end
    end
  end
end

project.save
puts "saved #{PROJECT_PATH}"
