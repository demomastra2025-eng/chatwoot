# frozen_string_literal: true

module Onelink; end

class Onelink::DevRuntime
  def initialize(env = ENV)
    @env = env
  end

  def fast?
    @env['ONELINK_DEV_FAST'] == '1'
  end

  def built_assets?
    @env['ONELINK_DEV_BUILT_ASSETS'] == '1'
  end

  def log_level
    if fast?
      @env.fetch('ONELINK_DEV_LOG_LEVEL', 'info').to_sym
    else
      @env.fetch('LOG_LEVEL', 'info').to_sym
    end
  end
end
