# frozen_string_literal: true

class Llm::Evals::Scenario::CachedClient
  attr_reader :client, :cache

  def initialize(client:, cache:)
    @client = client
    @cache = cache
  end

  def call(request)
    return client.call(request) unless cache.enabled?
    return cache.fetch(request) { |cached_request| client.call(cached_request) } if client

    cache.fetch(request)
  end

  def callable?
    client.present? || cache.read_enabled?
  end
end
