# frozen_string_literal: true

require 'faraday'

module Llm; end

module Llm::EgressGuard
  KEY = :llm_egress_validation

  # A control-flow abort, deliberately outside StandardError: provider fallbacks,
  # SDK retries, schema repair and best-effort observers must never swallow it.
  Blocked = Class.new(Exception) # rubocop:disable Lint/InheritException

  class Middleware < Faraday::Middleware
    def call(env)
      Llm::EgressGuard.check!
      @app.call(env)
    end
  end

  # The callable raises when permission cannot be established; it is never part of request data.
  def self.with(validation:)
    previous = Thread.current[KEY]
    Thread.current[KEY] = validation
    yield
  ensure
    Thread.current[KEY] = previous
  end

  def self.check!
    Thread.current[KEY]&.call
  rescue StandardError
    # Do not retain a source error/cause that might contain DB or provider data.
    raise Blocked, 'LLM egress permission revoked', cause: nil
  end
end
