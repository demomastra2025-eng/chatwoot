# frozen_string_literal: true

require 'cgi'

class Telephony::VirtualPbx::BridgeResourceClient
  SECRET_KEY_PATTERN = Telephony::VirtualPbx::ConfigBuilder::SECRET_KEY_PATTERN
  RESOURCE_PAYLOAD_KEYS = %i[
    name ref host port transport username send_register telUrl tel_url trunkRef trunk_ref
    credentialRef credential_ref metadata route mode app_ref appRef agent_aor agentAor enabled
    domain domainRef domain_ref domainUri domain_uri maxContacts max_contacts privacy
    password credentialsRef credentials_ref outboundCredentialsRef outbound_credentials_ref
    sendRegister inboundUri inbound_uri inboundCredentialsRef inbound_credentials_ref
    accessControlListRef access_control_list_ref uris
    city country countryIsoCode country_iso_code
    numberRef number_ref providerAccountNumber provider_account_number ingressNumber ingress_number
    displayPhoneNumber display_phone_number accountId account_id inboxId inbox_id channelId channel_id
    gatewayRef gateway_ref callerId caller_id sourceId source_id
  ].freeze

  ADOPTABLE_COLLECTION_PATHS = %w[
    /telephony/agents
    /telephony/credentials
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

  def upsert_sipuni_gateway(ref, payload = {})
    idempotent_upsert(resource_path('sipuni-gateways', ref), allowlisted_payload(payload).merge(ref: ref))
  end

  def delete_sipuni_gateway(ref)
    idempotent_delete(resource_path('sipuni-gateways', ref))
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
    payload = allowlisted_payload(attrs[:payload] || attrs[:payload_preview] || {})

    return idempotent_delete(attrs.fetch(:path)) if method == :delete

    if method == :put && attrs[:key].to_s.start_with?('upsert_')
      return idempotent_upsert(attrs.fetch(:path), payload_with_path_ref(attrs.fetch(:path), payload))
    end

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
    if adoptable_collection?(collection_path)
      existing = existing_resource_for_payload(collection_path, payload)
      return update_existing_resource(collection_path, existing, payload) if existing.present?
    end

    begin
      perform(:post, collection_path, payload: payload)
    rescue Telephony::Error => create_error
      existing = existing_resource_for_already_exists(collection_path, payload, create_error)
      return update_existing_resource(collection_path, existing, payload) if adoptable_collection?(collection_path) && existing.present?
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

    existing_resource_for_payload(collection_path, payload)
  end

  def existing_resource_for_payload(collection_path, payload)
    response = perform(:get, collection_path)
    items = Array.wrap(response['items'] || response[:items])
    find_existing_resource(collection_path, items, payload.with_indifferent_access)
  end

  def find_existing_resource(collection_path, items, payload)
    case collection_path.to_s
    when '/telephony/agents'
      find_existing_agent(items, payload)
    when '/telephony/credentials'
      find_existing_credentials(items, payload)
    else
      find_existing_by_ref_or_public_key(items, payload)
    end
  end

  def find_existing_agent(items, payload)
    return if payload[:username].blank?

    candidates = owned_adoption_candidates(items, payload).select do |attrs|
      attrs[:username].to_s == payload[:username].to_s
    end
    return if candidates.blank?

    return unique_candidate(candidates.select { |attrs| matching_agent_domain?(attrs, payload) }) if expected_agent_domain?(payload)

    unique_candidate(candidates)
  end

  def find_existing_credentials(items, payload)
    return if payload[:username].blank?

    username_matches = owned_adoption_candidates(items, payload).select do |attrs|
      attrs[:username].to_s == payload[:username].to_s
    end
    return if username_matches.blank?

    exact_name_matches = username_matches.select { |attrs| attrs[:name].to_s == payload[:name].to_s }
    unique_candidate(exact_name_matches.presence || username_matches)
  end

  def find_existing_by_ref_or_public_key(items, payload)
    items.find do |item|
      attrs = item.with_indifferent_access
      attrs[:ref].to_s == payload[:ref].to_s ||
        (payload[:telUrl].present? && attrs[:telUrl].to_s == payload[:telUrl].to_s) ||
        (payload[:name].present? && attrs[:name].to_s == payload[:name].to_s)
    end
  end

  def matching_agent_domain?(attrs, payload)
    expected_ref = payload[:domainRef] || payload[:domain_ref]
    expected_uri = payload[:domainUri] || payload[:domain_uri] || payload[:domain]
    raw_domain = attrs[:domain]
    actual_domain = raw_domain.respond_to?(:with_indifferent_access) ? raw_domain.with_indifferent_access : {}
    actual_ref = attrs[:domainRef] || attrs[:domain_ref] || actual_domain[:ref]
    actual_uri = attrs[:domainUri] ||
                 attrs[:domain_uri] ||
                 actual_domain[:domainUri] ||
                 actual_domain[:domain_uri] ||
                 (raw_domain if raw_domain.is_a?(String))

    return actual_ref.to_s == expected_ref.to_s if expected_ref.present?

    actual_uri.to_s.casecmp(expected_uri.to_s).zero?
  end

  def expected_agent_domain?(payload)
    (payload[:domainRef] || payload[:domain_ref] || payload[:domainUri] || payload[:domain_uri] || payload[:domain]).present?
  end

  def update_existing_resource(collection_path, existing, payload)
    attrs = existing.with_indifferent_access
    ref = attrs[:ref].presence
    return existing if ref.blank?

    perform(:put, "#{collection_path}/#{CGI.escape(ref.to_s)}", payload: payload.merge(ref: ref))
  end

  def owned_adoption_candidates(items, payload)
    items.filter_map do |item|
      attrs = item.with_indifferent_access
      attrs if adoptable_resource_owner?(attrs, payload)
    end
  end

  def adoptable_resource_owner?(attrs, payload)
    expected_metadata = (payload[:metadata] || {}).with_indifferent_access
    actual_metadata = (attrs[:metadata] || attrs.dig(:data, :metadata) || attrs.dig('data', 'metadata') || {}).with_indifferent_access
    return true if actual_metadata.blank?

    return false if actual_metadata[:managed_by].present? && actual_metadata[:managed_by].to_s != 'onelink'

    expected_account_id = expected_metadata[:onelink_account_id]
    actual_account_id = actual_metadata[:onelink_account_id]
    return actual_account_id.to_s == expected_account_id.to_s if expected_account_id.present? && actual_account_id.present?

    true
  end

  def unique_candidate(candidates)
    Array.wrap(candidates).one? ? candidates.first : nil
  end

  def adoptable_collection?(collection_path)
    ADOPTABLE_COLLECTION_PATHS.include?(collection_path.to_s)
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

  def payload_with_path_ref(path, payload)
    ref = CGI.unescape(path.to_s.split('/').last.to_s)
    return payload if ref.blank?

    payload.merge(ref: payload[:ref].presence || ref)
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
