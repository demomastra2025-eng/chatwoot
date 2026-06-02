# == Schema Information
#
# Table name: captain_mcp_servers
#
#  id                           :bigint           not null, primary key
#  allowed_scopes               :jsonb            not null
#  description                  :text
#  enabled                      :boolean          default(TRUE), not null
#  name                         :string           not null
#  oauth_client_info_data       :text
#  oauth_last_authorized_at     :datetime
#  oauth_pkce_data              :text
#  oauth_resource_metadata_data :text
#  oauth_return_url             :text
#  oauth_server_metadata_data   :text
#  oauth_state_expires_at       :datetime
#  oauth_state_param            :string
#  oauth_token_data             :text
#  request_timeout              :integer          default(30), not null
#  server_config                :jsonb            not null
#  slug                         :string           not null
#  transport_type               :string           not null
#  created_at                   :datetime         not null
#  updated_at                   :datetime         not null
#  account_id                   :bigint           not null
#
# Indexes
#
#  index_captain_mcp_servers_on_account_id              (account_id)
#  index_captain_mcp_servers_on_account_id_and_enabled  (account_id,enabled)
#  index_captain_mcp_servers_on_account_id_and_slug     (account_id,slug) UNIQUE
#  index_captain_mcp_servers_on_oauth_state_param       (oauth_state_param) UNIQUE WHERE (oauth_state_param IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
require 'ruby_llm/mcp'
require Rails.root.join('enterprise/lib/captain/mcp/oauth_storage').to_s

class Captain::McpServer < ApplicationRecord
  self.table_name = 'captain_mcp_servers'

  TRANSPORT_TYPES = %w[stdio streamable sse].freeze
  STDIO_ENABLED_ENV = 'CAPTAIN_MCP_STDIO_ENABLED'.freeze
  STDIO_COMMAND_ALLOWLIST_ENV = 'CAPTAIN_MCP_STDIO_COMMAND_ALLOWLIST'.freeze
  DEFAULT_ALLOWED_SCOPES = Captain::ToolAccess::SCOPE_ORDER.freeze
  SENSITIVE_SERVER_CONFIG_KEYS = %w[
    authorization
    api_key
    access_token
    refresh_token
    client_secret
    token
    bearer_token
    password
    secret
    secrets
    cookie
    cookies
  ].freeze

  belongs_to :account

  if Chatwoot.encryption_configured?
    encrypts :oauth_token_data
    encrypts :oauth_client_info_data
    encrypts :oauth_pkce_data
    encrypts :oauth_resource_metadata_data
  end

  before_validation :normalize_name
  before_validation :generate_slug
  before_validation :normalize_server_config
  before_validation :normalize_allowed_scopes
  before_validation :normalize_request_timeout

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :account_id }
  validates :transport_type, presence: true, inclusion: { in: TRANSPORT_TYPES }
  validates :request_timeout, numericality: { only_integer: true, greater_than: 0 }
  validate :validate_server_config_shape
  validate :validate_stdio_transport_policy

  scope :enabled, -> { where(enabled: true) }

  def metadata_group_name
    "MCP: #{name}"
  end

  def normalized_allowed_scopes
    Array(allowed_scopes).map(&:to_s).uniq.select do |scope_name|
      Captain::ToolAccess::SCOPE_ORDER.include?(scope_name)
    end
  end

  def client_name
    "captain_#{account_id}_#{slug}"
  end

  def client_options
    config = server_config.deep_symbolize_keys
    config[:oauth] = oauth_client_config(config[:oauth]) if http_transport? && oauth_configured?

    {
      name: client_name,
      transport_type: transport_type.to_sym,
      start: false,
      request_timeout: request_timeout,
      config: config
    }
  end

  def to_tool_metadata(tool_payload)
    tool_payload = tool_payload.with_indifferent_access

    {
      id: tool_payload[:id],
      title: tool_payload[:title],
      description: tool_payload[:description],
      group_name: metadata_group_name,
      icon: 'plug',
      allowed_scopes: normalized_allowed_scopes,
      required_features: [],
      required_permissions: [],
      risk_level: tool_payload[:risk_level].presence || 'medium',
      requires_confirmation: false,
      idempotent: ActiveModel::Type::Boolean.new.cast(tool_payload[:idempotent]),
      custom: false,
      source_type: Captain::ToolCatalog::SOURCE_TYPE_MCP,
      selected_by_default: false,
      provider: 'mcp',
      mcp_server_id: id,
      mcp_tool_name: tool_payload[:mcp_tool_name],
      input_schema: tool_payload[:input_schema]
    }
  end

  def server_config_for_api(include_secrets: false)
    return server_config if include_secrets

    redact_server_config(server_config)
  end

  def server_url
    server_config['url'].presence
  end

  def http_transport?
    %w[streamable sse].include?(transport_type)
  end

  def oauth_configured?
    oauth_settings.present? || oauth_token.present?
  end

  def oauth_settings
    server_config['oauth'].is_a?(Hash) ? server_config['oauth'] : {}
  end

  def oauth_scope
    oauth_settings['scope'].presence
  end

  def oauth_status
    token = oauth_token

    {
      configured: oauth_configured?,
      connected: token.present?,
      expires_at: token&.expires_at&.iso8601,
      expires_soon: token&.expires_soon? || false,
      has_refresh_token: token&.refresh_token.present?,
      last_authorized_at: oauth_last_authorized_at&.to_i,
      scope: token&.scope || oauth_scope
    }
  end

  def oauth_token
    load_oauth_object(oauth_token_data, RubyLLM::MCP::Auth::Token)
  end

  def oauth_token=(token)
    self.oauth_token_data = dump_oauth_object(token)
    self.oauth_last_authorized_at = Time.current if token.present?
  end

  def oauth_client_info
    load_oauth_object(oauth_client_info_data, RubyLLM::MCP::Auth::ClientInfo)
  end

  def oauth_client_info=(client_info)
    self.oauth_client_info_data = dump_oauth_object(client_info)
  end

  def oauth_server_metadata
    load_oauth_object(oauth_server_metadata_data, RubyLLM::MCP::Auth::ServerMetadata)
  end

  def oauth_server_metadata=(metadata)
    self.oauth_server_metadata_data = dump_oauth_object(metadata)
  end

  def oauth_pkce
    load_oauth_object(oauth_pkce_data, RubyLLM::MCP::Auth::PKCE)
  end

  def oauth_pkce=(pkce)
    self.oauth_pkce_data = dump_oauth_object(pkce)
  end

  def oauth_resource_metadata
    load_oauth_object(oauth_resource_metadata_data, RubyLLM::MCP::Auth::ResourceMetadata)
  end

  def oauth_resource_metadata=(metadata)
    self.oauth_resource_metadata_data = dump_oauth_object(metadata)
  end

  def disconnect_oauth!
    update!(
      oauth_token_data: nil,
      oauth_client_info_data: nil,
      oauth_server_metadata_data: nil,
      oauth_pkce_data: nil,
      oauth_resource_metadata_data: nil,
      oauth_state_param: nil,
      oauth_state_expires_at: nil,
      oauth_return_url: nil,
      oauth_last_authorized_at: nil
    )
  end

  private

  def oauth_client_config(existing_config)
    oauth_config = existing_config.is_a?(Hash) ? existing_config.deep_dup : {}
    oauth_config[:storage] = Captain::Mcp::OauthStorage.new(self)
    oauth_config[:scope] ||= oauth_scope if oauth_scope.present?
    oauth_config
  end

  def normalize_name
    self.name = name.to_s.squish
  end

  def generate_slug
    return if slug.present?
    return if name.blank?

    self.slug = name.parameterize(separator: '_')
  end

  def normalize_server_config
    self.server_config = {} if server_config.blank?
    self.server_config = server_config.to_h if server_config.respond_to?(:to_h)
    self.server_config = server_config.deep_stringify_keys if server_config.respond_to?(:deep_stringify_keys)
  end

  def normalize_allowed_scopes
    scopes = normalized_allowed_scopes
    self.allowed_scopes = scopes.presence || DEFAULT_ALLOWED_SCOPES
  end

  def normalize_request_timeout
    self.request_timeout = request_timeout.to_i if request_timeout.present?
    self.request_timeout = 30 if request_timeout.blank? || request_timeout.to_i <= 0
  end

  def validate_server_config_shape
    unless server_config.is_a?(Hash)
      errors.add(:server_config, 'must be a JSON object')
      return
    end

    case transport_type
    when 'stdio'
      errors.add(:server_config, 'must include command for stdio transport') if server_config['command'].blank?
    when 'streamable', 'sse'
      errors.add(:server_config, 'must include url for HTTP transports') if server_config['url'].blank?
    end
  end

  def validate_stdio_transport_policy
    return unless transport_type == 'stdio'

    errors.add(:transport_type, 'stdio transport is disabled for this environment') unless stdio_transport_allowed?
    validate_stdio_command_allowlist
  end

  def validate_stdio_command_allowlist
    allowlist = stdio_command_allowlist
    command = server_config['command'].to_s
    return if allowlist.blank? || command.blank?
    return if allowlist.include?(command)

    errors.add(:server_config, 'command is not allowlisted for stdio transport')
  end

  def stdio_transport_allowed?
    default = !Rails.env.production?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(STDIO_ENABLED_ENV, default))
  end

  def stdio_command_allowlist
    ENV.fetch(STDIO_COMMAND_ALLOWLIST_ENV, '').split(',').map(&:strip).reject(&:blank?)
  end

  def load_oauth_object(raw_value, object_class)
    require 'ruby_llm/mcp'
    return if raw_value.blank?

    object_class.from_h(JSON.parse(raw_value))
  rescue JSON::ParserError
    nil
  end

  def dump_oauth_object(object)
    return if object.blank?

    object.respond_to?(:to_h) ? object.to_h.to_json : object.to_json
  end

  def redact_server_config(value, parent_key = nil)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested_value), memo|
        key_name = key.to_s
        memo[key_name] = if sensitive_server_config_key?(key_name, parent_key)
                           '[FILTERED]'
                         else
                           redact_server_config(nested_value, key_name)
                         end
      end
    when Array
      value.map { |item| redact_server_config(item, parent_key) }
    else
      value
    end
  end

  def sensitive_server_config_key?(key_name, parent_key)
    return true if SENSITIVE_SERVER_CONFIG_KEYS.include?(key_name.to_s.downcase)

    parent_key.to_s.casecmp('headers').zero? &&
      key_name.to_s.match?(/\A(authorization|x-api-key|api-key)\z/i)
  end
end
