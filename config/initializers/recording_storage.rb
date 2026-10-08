# frozen_string_literal: true

Rails.application.config.to_prepare do
  Storage::RecordingPaths.configure_root_aliases!
end
