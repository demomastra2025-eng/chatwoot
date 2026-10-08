# frozen_string_literal: true

module Onelink; end

class Onelink::DevRuntime
  # The DEV endpoint checks this version before permitting rollback in built mode.
  BUILT_ASSETS_CONTRACT = 1

  def initialize(env = ENV)
    @env = env
  end

  def fast?
    @env['ONELINK_DEV_FAST'] == '1'
  end

  def built_assets?
    @env['ONELINK_DEV_BUILT_ASSETS'] == '1'
  end

  def vite_options
    return {} unless built_assets?

    { mode: 'production', public_output_dir: 'vite', auto_build: false, skip_proxy: true, asset_host: nil, base: '/' }
  end

  def log_level
    if fast?
      @env.fetch('ONELINK_DEV_LOG_LEVEL', 'info').to_sym
    else
      @env.fetch('LOG_LEVEL', 'info').to_sym
    end
  end
end
