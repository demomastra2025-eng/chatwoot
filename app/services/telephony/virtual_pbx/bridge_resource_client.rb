# frozen_string_literal: true

require 'cgi'

class Telephony::VirtualPbx::BridgeResourceClient
  SECRET_KEY_PATTERN = Telephony::VirtualPbx::ConfigBuilder::SECRET_KEY_PATTERN
  RESOURCE_PAYLOAD_KEYS = %i[
    name ref host port transport username send_register telUrl tel_url trunkRef trunk_ref
    credentialRef credential_ref metadata route mode app_ref appRef agent_aor agentAor enabled
    city country countryIsoCode country_iso_code
  ].freeze

  ERROR_CODE_BY_STATUS = {
    not_found: 'REMOTE_RESOURCE_NOT_FOUND',
    conflict: 'REMOTE_RESOURCE_CONFLICT',
    unprocessable_content: 'REMOTE_MUTATION_FAILED',
    bad_gateway: 'BRIDGE_UNAVAILABLE',
    service_unavailable: 'BRIDGE_UNAVAILABLE'
  }.freeze

  def self.sanitize_payload(payload)
    new(bridge_client: nil).sanitize(payload)
  end

  def initialize(bridge_client:, idempotency_key: nil)
    @bridge_client = bridge_client
    @idempotency_key = idempotency_key
  end

  def applications
    perform(:get, '/telephony/applications')
  end

  def number(ref)
    perform(:get, resource_path('numbers', ref))
  end

  def trunk(ref)
    perform(:get, resource_path('trunks', ref))
  end

  def credential(ref)
    perform(:get, resource_path('credentials', ref))
  end

  def secret(ref)
    perform(:get, resource_path('secrets', ref))
  end

  def domain(ref)
    perform(:get, resource_path('domains', ref))
  end

  def agent(ref)
    perform(:get, resource_path('agents', ref))
  end

  def upsert_credentials(ref, payload = {})
    perform(:put, resource_path('credentials', ref), payload: allowlisted_payload(payload))
  end

  def upsert_secret(ref, payload = {})
    perform(:put, resource_path('secrets', ref), payload: allowlisted_payload(payload))
  end

  def upsert_trunk(ref, payload = {})
    idempotent_upsert(resource_path('trunks', ref), allowlisted_payload(payload).merge(ref: ref))
  end

  def upsert_number(ref, payload = {})
    idempotent_upsert(resource_path('numbers', ref), allowlisted_payload(payload).merge(ref: ref))
  end

  def upsert_domain(ref, payload = {})
    perform(:put, resource_path('domains', ref), payload: allowlisted_payload(payload))
  end

  def upsert_agent(ref, payload = {})
    idempotent_upsert(resource_path('agents', ref), allowlisted_payload(payload).merge(ref: ref))
  end

  def update_number_route(ref, payload = {})
    perform(:post, "#{resource_path('numbers', ref)}/route", payload: allowlisted_payload(payload))
  end

  def delete_number(ref)
    idempotent_delete(resource_path('numbers', ref))
  end

  def delete_trunk(ref)
    idempotent_delete(resource_path('trunks', ref))
  end

  def delete_credentials(ref)
    idempotent_delete(resource_path('credentials', ref))
  end

  def delete_agent(ref)
    idempotent_delete(resource_path('agents', ref))
  end

  def dispatch(operation)
    attrs = operation.with_indifferent_access
    method = attrs[:method].to_s.downcase.to_sym
    payload = attrs[:payload] || attrs[:payload_preview] || {}

    return idempotent_delete(attrs.fetch(:path)) if method == :delete
    return idempotent_upsert(attrs.fetch(:path), allowlisted_payload(payload)) if method == :put && attrs[:key].to_s.start_with?('upsert_')

    perform(method, attrs.fetch(:path), payload: payload)
  end

  def sanitize(value, parent_key = nil)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), sanitized|
        sanitized[key] = secret_key?(key) ? redacted_value(child) : sanitize(child, key)
      end
    when Array
      value.map { |child| sanitize(child, parent_key) }
    else
      secret_key?(parent_key) ? redacted_value(value) : value
    end
  end

  private

  attr_reader :bridge_client, :idempotency_key

  def perform(method, path, payload: nil)
    case method.to_sym
    when :get
      bridge_client.get(path, idempotency_key: idempotency_key)
    when :post
      bridge_client.post(path, payload || {}, idempotency_key: idempotency_key)
    when :put
      bridge_client.put(path, payload || {}, idempotency_key: idempotency_key)
    when :patch
      bridge_client.patch(path, payload || {}, idempotency_key: idempotency_key)
    when :delete
      bridge_client.delete(path, payload, idempotency_key: idempotency_key)
    else
      raise Telephony::Error.new(code: 'REMOTE_MUTATION_FAILED', message: "Unsupported bridge method #{method}", status: :unprocessable_content)
    end
  rescue Telephony::Error => e
    raise mapped_error(e, path: path)
  end

  def idempotent_delete(path)
    perform(:delete, path)
  rescue Telephony::Error => e
    raise unless missing_remote_resource?(e)

    { 'ok' => true, 'not_found' => true, 'path' => path }
  end

  def idempotent_upsert(path, payload)
    perform(:put, path, payload: payload)
  rescue Telephony::Error => e
    raise unless missing_remote_resource?(e)

    collection_path = collection_path_for(path)
    begin
      perform(:post, collection_path, payload: payload)
    rescue Telephony::Error => create_error
      existing = existing_resource_for_already_exists(collection_path, payload, create_error)
      return existing if existing.present?

      raise
    end
  end

  def mapped_error(error, path:)
    mapped_code = ERROR_CODE_BY_STATUS.fetch(error.status, nil)
    mapped_code ||= case error.code
                    when 'BRIDGE_NOT_CONFIGURED' then 'BRIDGE_NOT_CONFIGURED'
                    when 'BRIDGE_UNAVAILABLE' then 'BRIDGE_UNAVAILABLE'
                    else 'REMOTE_MUTATION_FAILED'
                    end

    Telephony::Error.new(
      code: mapped_code,
      message: "#{mapped_code}: #{path} #{error.message}",
      status: error.status,
      details: error.details
    )
  end

  def missing_remote_resource?(error)
    return true if error.code == 'REMOTE_RESOURCE_NOT_FOUND'

    message = error.message.to_s
    message.include?('NOT_FOUND') && message.include?('requested resource was not found')
  end

  def already_exists?(error)
    error.message.to_s.include?('ALREADY_EXISTS')
  end

  def existing_resource_for_already_exists(collection_path, payload, error)
    return unless already_exists?(error)

    response = perform(:get, collection_path)
    items = Array.wrap(response['items'] || response[:items])
    items.find do |item|
      attrs = item.with_indifferent_access
      attrs[:ref].to_s == payload[:ref].to_s ||
        (payload[:telUrl].present? && attrs[:telUrl].to_s == payload[:telUrl].to_s) ||
        (payload[:name].present? && attrs[:name].to_s == payload[:name].to_s)
    end
  end

  def collection_path_for(path)
    path.to_s.sub(%r{/[^/]+\z}, '')
  end

  def resource_path(resource, ref)
    "/telephony/#{resource}/#{CGI.escape(ref.to_s)}"
  end

  def allowlisted_payload(payload)
    attrs = (payload || {}).to_h.deep_symbolize_keys.slice(*RESOURCE_PAYLOAD_KEYS)
    attrs[:metadata] = sanitize(attrs[:metadata].to_h.deep_symbolize_keys) if attrs[:metadata].present?
    attrs.compact
  end

  def secret_key?(key)
    normalized = key.to_s
    return false if normalized.match?(/(_ref|ref)\z/i)
    return false if normalized.match?(/configured\z/i)

    normalized.match?(SECRET_KEY_PATTERN)
  end

  def redacted_value(value)
    value.present? ? '[REDACTED]' : nil
  end
end
