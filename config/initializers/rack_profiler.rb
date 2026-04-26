# frozen_string_literal: true

if Rails.env.development? && ENV['DISABLE_MINI_PROFILER'].blank?
  require 'rack'

  # rack-mini-profiler 3.2.x still serves its assets through Rack::File.
  # Rack 3 renamed that constant to Rack::Files, so keep a development-only
  # compatibility alias for the profiler asset endpoint.
  Rack.const_set(:File, Rack::Files) if Rack.const_defined?(:Files, false) && !Rack.const_defined?(:File, false)

  require 'rack-mini-profiler'

  # initialization is skipped so trigger it
  Rack::MiniProfilerRails.initialize!(Rails.application)
end
