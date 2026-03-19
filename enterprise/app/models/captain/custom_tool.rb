# == Schema Information
#
# Table name: captain_custom_tools
#
#  id                :bigint           not null, primary key
#  auth_config       :jsonb
#  auth_type         :string           default("none")
#  description       :text
#  enabled           :boolean          default(TRUE), not null
#  endpoint_url      :text             not null
#  group_name        :string
#  http_method       :string           default("GET"), not null
#  param_schema      :jsonb
#  request_template  :text
#  response_template :text
#  slug              :string           not null
#  title             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#
# Indexes
#
#  index_captain_custom_tools_on_account_id           (account_id)
#  index_captain_custom_tools_on_account_id_and_slug  (account_id,slug) UNIQUE
#
class Captain::CustomTool < ApplicationRecord
  include Concerns::Toolable
  include Concerns::SafeEndpointValidatable

  self.table_name = 'captain_custom_tools'

  NAME_PREFIX = 'custom'.freeze
  NAME_SEPARATOR = '_'.freeze
  DEFAULT_SLUG_BODY = 'tool'.freeze
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
        'required': { 'type': 'boolean' }
      },
      'required': %w[name type description],
      'additionalProperties': false
    }
  }.to_json.freeze

  belongs_to :account

  enum :http_method, %w[GET POST].index_by(&:itself), validate: true
  enum :auth_type, %w[none bearer basic api_key].index_by(&:itself), default: :none, validate: true, prefix: :auth

  before_validation :normalize_group_name
  before_validation :generate_slug

  validates :slug, presence: true, uniqueness: { scope: :account_id }
  validates :title, presence: true
  validates :endpoint_url, presence: true
  validates :group_name, length: { maximum: 100 }, allow_blank: true
  validates_with JsonSchemaValidator,
                 schema: PARAM_SCHEMA_VALIDATION,
                 attribute_resolver: ->(record) { record.param_schema }

  scope :enabled, -> { where(enabled: true) }

  def to_tool_metadata
    {
      id: slug,
      title: title,
      description: description,
      group_name: group_name,
      custom: true
    }
  end

  private

  def normalize_group_name
    self.group_name = group_name.to_s.squish.presence
  end

  def generate_slug
    return if slug.present?
    return if title.blank?

    base_slug = "#{NAME_PREFIX}#{NAME_SEPARATOR}#{normalized_title_slug}"
    self.slug = find_unique_slug(base_slug)
  end

  def normalized_title_slug
    transliterated_title = transliterate_slug_source(title.to_s)

    slug_body = transliterated_title
                .downcase
                .gsub(/[^a-z0-9]+/, NAME_SEPARATOR)
                .gsub(/#{Regexp.escape(NAME_SEPARATOR)}{2,}/, NAME_SEPARATOR)
                .gsub(/\A#{Regexp.escape(NAME_SEPARATOR)}+|#{Regexp.escape(NAME_SEPARATOR)}+\z/, '')

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

    5.times do
      slug_candidate = "#{base_slug}#{NAME_SEPARATOR}#{SecureRandom.alphanumeric(6).downcase}"
      return slug_candidate unless slug_exists?(slug_candidate)
    end

    raise ActiveRecord::RecordNotUnique, I18n.t('captain.custom_tool.slug_generation_failed')
  end

  def slug_exists?(candidate)
    self.class.exists?(account_id: account_id, slug: candidate)
  end
end
