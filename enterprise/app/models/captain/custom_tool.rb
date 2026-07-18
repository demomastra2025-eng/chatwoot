# == Schema Information
#
# Table name: captain_custom_tools
#
#  id                   :bigint           not null, primary key
#  allow_file_artifacts :boolean          default(TRUE), not null
#  auth_config          :jsonb
#  auth_type            :string           default("none")
#  description          :text
#  enabled              :boolean          default(TRUE), not null
#  endpoint_url         :text             not null
#  group_name           :string
#  http_method          :string           default("GET"), not null
#  param_schema         :jsonb
#  request_template     :text
#  response_template    :text
#  slug                 :string           not null
#  title                :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#
# Indexes
#
#  index_captain_custom_tools_on_account_id                 (account_id)
#  index_captain_custom_tools_on_account_id_and_group_name  (account_id,group_name)
#  index_captain_custom_tools_on_account_id_and_slug        (account_id,slug) UNIQUE
#
class Captain::CustomTool < ApplicationRecord
  include Concerns::Toolable
  include Concerns::SafeEndpointValidatable

  self.table_name = 'captain_custom_tools'

  NAME_PREFIX = 'custom'.freeze
  NAME_SEPARATOR = '_'.freeze
  DEFAULT_SLUG_BODY = 'tool'.freeze
  # LLM function/tool names are constrained to 64 characters.
  MAX_SLUG_LENGTH = 64
  COLLISION_SUFFIX_LENGTH = 7 # "_" + 6 random alphanumeric chars
  NAME_SEPARATOR_RUN_REGEX = /#{Regexp.escape(NAME_SEPARATOR)}{2,}/o
  NAME_SEPARATOR_BOUNDARY_REGEX = /\A#{Regexp.escape(NAME_SEPARATOR)}+|#{Regexp.escape(NAME_SEPARATOR)}+\z/o
  PARAM_SOURCE_AGENT = 'agent'.freeze
  PARAM_SOURCE_CONTEXT = 'context'.freeze
  PARAM_SOURCE_FIXED = 'fixed'.freeze
  PARAM_SOURCES = [
    PARAM_SOURCE_AGENT,
    PARAM_SOURCE_CONTEXT,
    PARAM_SOURCE_FIXED
  ].freeze
  PARAM_REQUEST_LOCATION_TEMPLATE = 'template'.freeze
  PARAM_REQUEST_LOCATION_QUERY = 'query'.freeze
  PARAM_REQUEST_LOCATION_HEADER = 'header'.freeze
  PARAM_REQUEST_LOCATIONS = [
    PARAM_REQUEST_LOCATION_TEMPLATE,
    PARAM_REQUEST_LOCATION_QUERY,
    PARAM_REQUEST_LOCATION_HEADER
  ].freeze
  HTTP_HEADER_NAME_FORMAT = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  FORBIDDEN_REQUEST_HEADER_NAMES = %w[
    connection
    content-length
    host
    keep-alive
    proxy-authenticate
    proxy-authorization
    te
    trailer
    transfer-encoding
    upgrade
  ].freeze
  HTTP_METHODS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS].freeze
  REQUEST_BODY_HTTP_METHODS = %w[POST PUT PATCH DELETE OPTIONS].freeze
  SAFE_READ_ONLY_HTTP_METHODS = %w[GET HEAD OPTIONS].freeze
  READ_ONLY_ACTION_TOKENS = %w[
    get list search find lookup fetch query retrieve read show check calculate estimate recommend suggest preview
  ].freeze
  MUTATING_ACTION_TOKENS = %w[
    create update delete remove send submit cancel reserve book assign unassign approve reject close reopen resolve change
    add set apply attach detach upload import sync notify charge pay purchase schedule reschedule publish
  ].freeze
  PARAM_TYPES = %w[string number boolean array object].freeze
  PARAM_NAME_FORMAT = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/
  RESERVED_TEMPLATE_PARAM_NAMES = %w[
    contact
    conversation
    deal
    task
    appointment
    assistant
    account
    params
    p
    visible_fields
  ].freeze
  CYRILLIC_TRANSLITERATION_MAP = {
    'а' => 'a', 'б' => 'b', 'в' => 'v', 'г' => 'g', 'д' => 'd', 'е' => 'e',
    'ё' => 'yo', 'ж' => 'zh', 'з' => 'z', 'и' => 'i', 'й' => 'y', 'к' => 'k',
    'л' => 'l', 'м' => 'm', 'н' => 'n', 'о' => 'o', 'п' => 'p', 'р' => 'r',
    'с' => 's', 'т' => 't', 'у' => 'u', 'ф' => 'f', 'х' => 'h', 'ц' => 'ts',
    'ч' => 'ch', 'ш' => 'sh', 'щ' => 'shch', 'ъ' => '', 'ы' => 'y',
    'ь' => '', 'э' => 'e', 'ю' => 'yu', 'я' => 'ya', 'і' => 'i', 'ї' => 'yi',
    'є' => 'ye', 'ґ' => 'g', 'ә' => 'a', 'ғ' => 'g', 'қ' => 'q', 'ң' => 'ng',
    'ө' => 'o', 'ұ' => 'u', 'ү' => 'u', 'һ' => 'h'
  }.freeze
  PARAM_SCHEMA_VALIDATION = {
    'type': 'array',
    'items': {
      'type': 'object',
      'properties': {
        'name': { 'type': 'string' },
        'type': { 'type': 'string' },
        'description': { 'type': 'string' },
        'required': { 'type': 'boolean' },
        'source': { 'type': 'string' },
        'context_path': { 'type': 'string' },
        'fixed_value': {},
        'request_location': { 'type': 'string' },
        'request_key': { 'type': 'string' }
      },
      'required': %w[name type],
      'additionalProperties': false
    }
  }.to_json.freeze

  belongs_to :account

  enum :http_method, HTTP_METHODS.index_by(&:itself), validate: true
  enum :auth_type, %w[none bearer basic api_key].index_by(&:itself), default: :none, validate: true, prefix: :auth

  before_validation :normalize_group_name
  before_validation :generate_slug
  before_validation :normalize_auth_config
  before_validation :normalize_param_schema

  validates :slug, presence: true, uniqueness: { scope: :account_id }, length: { maximum: MAX_SLUG_LENGTH }
  validates :title, presence: true
  validates :endpoint_url, presence: true
  validates :group_name, length: { maximum: 100 }, allow_blank: true
  validates_with JsonSchemaValidator,
                 schema: PARAM_SCHEMA_VALIDATION,
                 attribute_resolver: ->(record) { record.param_schema }
  validate :validate_auth_configuration
  validate :validate_param_schema_sources
  validate :validate_template_syntax

  scope :enabled, -> { where(enabled: true) }

  class << self
    def cast_param_value(type, value)
      return nil if value.nil?

      case type
      when 'string'
        value.is_a?(String) ? value : stringify_param_value(value)
      when 'number'
        cast_number_param_value(value)
      when 'boolean'
        ActiveModel::Type::Boolean.new.cast(value)
      when 'array'
        cast_json_param_value(value, Array, 'array')
      when 'object'
        cast_json_param_value(value, Hash, 'object')
      else
        value
      end
    end

    private

    def cast_number_param_value(value)
      return value if value.is_a?(Numeric)

      numeric_value = Float(value)
      numeric_value.to_i == numeric_value ? numeric_value.to_i : numeric_value
    rescue ArgumentError, TypeError
      raise ArgumentError, 'must be a valid number'
    end

    def cast_json_param_value(value, expected_class, type_name)
      return value if value.is_a?(expected_class)

      parsed_value = JSON.parse(value.to_s)
      return parsed_value if parsed_value.is_a?(expected_class)

      raise ArgumentError, "must be valid JSON #{type_name}"
    rescue JSON::ParserError
      raise ArgumentError, "must be valid JSON #{type_name}"
    end

    def stringify_param_value(value)
      case value
      when Hash, Array
        JSON.generate(Captain::EncodingNormalizer.utf8(value))
      when String
        Captain::EncodingNormalizer.string(value)
      else
        value.to_s
      end
    rescue JSON::GeneratorError
      Captain::EncodingNormalizer.string(value.to_s)
    end
  end

  def to_tool_metadata
    {
      id: slug,
      title: title,
      description: description,
      group_name: group_name.presence || 'Custom tools',
      icon: 'plug',
      custom: true,
      source_type: Captain::ToolCatalog::SOURCE_TYPE_CUSTOM,
      allowed_scopes: Captain::ToolAccess::SCOPE_ORDER,
      required_features: [],
      required_permissions: []
    }.merge(custom_tool_risk_metadata)
  end

  def runtime_parameter_definitions(scope_name = Captain::ToolAccess::SCOPE_AGENT)
    case scope_name.to_s
    when Captain::ToolAccess::SCOPE_AGENT, Captain::ToolAccess::SCOPE_ASSISTANT
      agent_parameter_definitions
    else
      []
    end
  end

  def runtime_parameters(scope_name = Captain::ToolAccess::SCOPE_AGENT)
    runtime_parameter_definitions(scope_name).each_with_object({}) do |param_definition, memo|
      memo[param_definition['name'].to_sym] = RubyLLM::Parameter.new(
        param_definition['name'].to_sym,
        type: param_definition['type'],
        desc: param_definition['description'],
        required: param_definition.fetch('required', false)
      )
    end
  end

  def parameter_definitions
    Array(param_schema).map { |param_definition| normalize_param_definition(param_definition) }
  end

  def custom_tool_risk_metadata
    if read_only_custom_tool?
      {
        risk_level: 'read_only',
        read_only: true,
        requires_confirmation: false,
        idempotent: true
      }
    else
      {
        risk_level: 'custom',
        read_only: false,
        requires_confirmation: false,
        idempotent: false
      }
    end
  end

  def read_only_custom_tool?
    return false unless SAFE_READ_ONLY_HTTP_METHODS.include?(http_method.to_s.upcase)
    return false if custom_tool_action_tokens_match?(MUTATING_ACTION_TOKENS)

    custom_tool_action_tokens_match?(READ_ONLY_ACTION_TOKENS)
  end

  def custom_tool_action_tokens_match?(tokens)
    words = custom_tool_action_words
    tokens.any? do |token|
      words.any? { |word| word == token || word.start_with?(token) }
    end
  end

  def custom_tool_action_words
    [slug, title].compact_blank.flat_map do |value|
      value.to_s.downcase.scan(/[a-z0-9]+/)
    end.uniq
  end

  def agent_parameter_definitions
    parameter_definitions.select { |param_definition| param_definition['source'] == PARAM_SOURCE_AGENT }
  end

  def normalize_param_definition(param_definition)
    raw_definition = (param_definition || {}).to_h.deep_stringify_keys
    normalized_definition = raw_definition.slice(
      'name', 'type', 'description', 'required', 'source', 'context_path', 'fixed_value', 'request_location', 'request_key'
    )
    normalized_definition['description'] = raw_definition['description'].to_s
    normalized_definition['required'] = if raw_definition.key?('required')
                                          ActiveModel::Type::Boolean.new.cast(raw_definition['required'])
                                        else
                                          false
                                        end
    normalized_definition['source'] = normalize_param_source(raw_definition['source'])
    normalized_definition['context_path'] = normalize_context_path(raw_definition['context_path'])
    normalized_definition['request_location'] = normalize_request_location(raw_definition['request_location'])
    normalized_definition['request_key'] = raw_definition['request_key'].to_s.strip.presence

    normalized_definition.delete('context_path') if normalized_definition['source'] != PARAM_SOURCE_CONTEXT

    normalized_definition.delete('fixed_value') if normalized_definition['source'] != PARAM_SOURCE_FIXED

    if normalized_definition['request_location'] == PARAM_REQUEST_LOCATION_TEMPLATE
      normalized_definition.delete('request_location')
      normalized_definition.delete('request_key')
    else
      normalized_definition['request_key'] ||= normalized_definition['name']
    end

    normalized_definition
  end

  private

  def normalize_group_name
    self.group_name = group_name.to_s.squish.presence
  end

  def normalize_auth_config
    raw_auth_config = auth_config.respond_to?(:to_h) ? auth_config.to_h : {}
    normalized_auth_config = raw_auth_config.deep_stringify_keys

    self.auth_config = case auth_type.to_s
                       when 'bearer'
                         normalized_auth_config.slice('token')
                       when 'basic'
                         normalized_auth_config.slice('username', 'password')
                       when 'api_key'
                         normalized_auth_config.slice('name', 'key', 'location').tap do |config|
                           config['location'] = config['location'].presence || 'header'
                         end
                       else
                         {}
                       end
  end

  def generate_slug
    return if slug.present?
    return if title.blank?

    base_slug = "#{NAME_PREFIX}#{NAME_SEPARATOR}#{normalized_title_slug}".truncate(MAX_SLUG_LENGTH, omission: '')
    self.slug = find_unique_slug(base_slug)
  end

  def normalized_title_slug
    transliterated_title = transliterate_slug_source(title.to_s)

    slug_body = transliterated_title
                .downcase
                .gsub(/[^a-z0-9]+/, NAME_SEPARATOR)
                .gsub(NAME_SEPARATOR_RUN_REGEX, NAME_SEPARATOR)
                .gsub(NAME_SEPARATOR_BOUNDARY_REGEX, '')

    slug_body.presence || DEFAULT_SLUG_BODY
  end

  def transliterate_slug_source(value)
    cyrillic_normalized = value.to_s.downcase.each_char.map do |char|
      CYRILLIC_TRANSLITERATION_MAP.fetch(char, char)
    end.join

    ActiveSupport::Inflector.transliterate(cyrillic_normalized)
  end

  def find_unique_slug(base_slug)
    return base_slug unless slug_exists?(base_slug)

    truncated = base_slug.truncate(MAX_SLUG_LENGTH - COLLISION_SUFFIX_LENGTH, omission: '')
    5.times do
      slug_candidate = "#{truncated}#{NAME_SEPARATOR}#{SecureRandom.alphanumeric(6).downcase}"
      return slug_candidate unless slug_exists?(slug_candidate)
    end

    raise ActiveRecord::RecordNotUnique, I18n.t('captain.custom_tool.slug_generation_failed')
  end

  def slug_exists?(candidate)
    self.class.exists?(account_id: account_id, slug: candidate)
  end

  def normalize_param_schema
    self.param_schema = parameter_definitions
  end

  def validate_param_schema_sources
    available_field_ids = account.present? ? Captain::ContextFields.field_ids_for(account) : []
    parameter_names = []

    parameter_definitions.each do |param_definition|
      validate_param_definition_shape(param_definition, parameter_names)
      validate_param_source(param_definition, available_field_ids)
      validate_fixed_param_value(param_definition)
      validate_param_request_location(param_definition)
    end
  end

  def validate_auth_configuration
    case auth_type.to_s
    when 'bearer'
      errors.add(:auth_config, 'bearer token is required') if auth_config['token'].to_s.strip.blank?
    when 'basic'
      errors.add(:auth_config, 'username is required') if auth_config['username'].to_s.strip.blank?
      errors.add(:auth_config, 'password is required') if auth_config['password'].to_s.strip.blank?
    when 'api_key'
      errors.add(:auth_config, 'API key name is required') if auth_config['name'].to_s.strip.blank?
      errors.add(:auth_config, 'API key value is required') if auth_config['key'].to_s.strip.blank?
      return if %w[header query].include?(auth_config['location'])

      errors.add(:auth_config, 'API key location must be header or query')
    end
  end

  def validate_template_syntax
    validate_template_attribute(:endpoint_url)
    validate_template_attribute(:request_template)
    validate_template_attribute(:response_template)
  end

  def validate_template_attribute(attribute_name)
    template = public_send(attribute_name)
    return if template.blank?

    Liquid::Template.parse(template, error_mode: :strict)
  rescue Liquid::SyntaxError => e
    errors.add(attribute_name, "contains invalid Liquid syntax: #{e.message}")
  end

  def validate_param_definition_shape(param_definition, parameter_names)
    name = param_definition['name'].to_s
    type = param_definition['type'].to_s
    description = param_definition['description'].to_s

    if name.blank?
      errors.add(:param_schema, 'parameter names cannot be blank')
      return
    end

    errors.add(:param_schema, "parameter #{name} must use only letters, numbers, and underscores") unless name.match?(PARAM_NAME_FORMAT)

    errors.add(:param_schema, "parameter #{name} uses a reserved name") if RESERVED_TEMPLATE_PARAM_NAMES.include?(name)

    if parameter_names.include?(name)
      errors.add(:param_schema, "parameter #{name} is duplicated")
    else
      parameter_names << name
    end

    errors.add(:param_schema, "parameter #{name} has an invalid type") unless PARAM_TYPES.include?(type)
    if param_definition['source'] == PARAM_SOURCE_AGENT && description.blank?
      errors.add(:param_schema, "agent parameter #{name} must define a description")
    end
  end

  def validate_param_source(param_definition, available_field_ids)
    source = param_definition['source']

    unless PARAM_SOURCES.include?(source)
      errors.add(:param_schema, "parameter #{param_definition['name']} has an invalid source")
      return
    end

    return unless source == PARAM_SOURCE_CONTEXT

    context_path = param_definition['context_path']
    if context_path.blank?
      errors.add(:param_schema, "parameter #{param_definition['name']} must define a context field")
      return
    end

    return if available_field_ids.include?(context_path)

    errors.add(:param_schema, "parameter #{param_definition['name']} references an unknown context field")
  end

  def validate_fixed_param_value(param_definition)
    return unless param_definition['source'] == PARAM_SOURCE_FIXED

    if fixed_param_value_blank?(param_definition['fixed_value'])
      errors.add(:param_schema, "parameter #{param_definition['name']} must define a fixed value")
      return
    end

    self.class.cast_param_value(param_definition['type'], param_definition['fixed_value'])
  rescue ArgumentError => e
    errors.add(:param_schema, "parameter #{param_definition['name']} #{e.message}")
  end

  def validate_param_request_location(param_definition)
    request_location = normalize_request_location(param_definition['request_location'])
    name = param_definition['name']

    unless PARAM_REQUEST_LOCATIONS.include?(request_location)
      errors.add(:param_schema, "parameter #{name} has an invalid request location")
      return
    end

    return if request_location == PARAM_REQUEST_LOCATION_TEMPLATE

    request_key = param_definition['request_key'].to_s
    if request_key.blank?
      errors.add(:param_schema, "parameter #{name} must define a request key")
      return
    end

    return unless request_location == PARAM_REQUEST_LOCATION_HEADER

    errors.add(:param_schema, "parameter #{name} has an invalid header name") unless request_key.match?(HTTP_HEADER_NAME_FORMAT)
    if FORBIDDEN_REQUEST_HEADER_NAMES.include?(request_key.downcase)
      errors.add(:param_schema, "parameter #{name} uses a forbidden header name")
    end
  end

  def fixed_param_value_blank?(value)
    return true if value.nil?
    return value.empty? if value.respond_to?(:empty?)

    false
  end

  def normalize_param_source(source)
    normalized_source = source.to_s.strip.presence
    normalized_source || PARAM_SOURCE_AGENT
  end

  def normalize_context_path(context_path)
    context_path.to_s.gsub(/\\(.)/, '\1').presence
  end

  def normalize_request_location(request_location)
    request_location.to_s.strip.presence || PARAM_REQUEST_LOCATION_TEMPLATE
  end
end
