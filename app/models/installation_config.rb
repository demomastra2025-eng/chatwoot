# == Schema Information
#
# Table name: installation_configs
#
#  id               :bigint           not null, primary key
#  locked           :boolean          default(TRUE), not null
#  name             :string           not null
#  serialized_value :jsonb            not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_installation_configs_on_name                 (name) UNIQUE
#  index_installation_configs_on_name_and_created_at  (name,created_at) UNIQUE
#
class InstallationConfig < ApplicationRecord
  # Legacy rows store YAML blobs inside a jsonb string value. A custom type keeps
  # those readable while letting new writes use native jsonb objects.
  SerializedValueType = Class.new(ActiveRecord::Type::Json) do
    def cast(value)
      normalize(value)
    end

    def deserialize(value)
      normalize(super)
    rescue JSON::ParserError, TypeError
      normalize(value)
    end

    def serialize(value)
      super(normalize(value).to_h)
    end

    private

    def normalize(value)
      case value
      when ActiveSupport::HashWithIndifferentAccess
        value
      when Hash
        value.with_indifferent_access
      when String
        load_legacy_yaml(value)
      else
        {}.with_indifferent_access
      end
    end

    def load_legacy_yaml(value)
      parsed = YAML.safe_load(
        value,
        permitted_classes: Rails.application.config.active_record.yaml_column_permitted_classes,
        aliases: true
      )

      case parsed
      when ActiveSupport::HashWithIndifferentAccess
        parsed
      when Hash
        parsed.with_indifferent_access
      else
        {}.with_indifferent_access
      end
    rescue Psych::Exception, TypeError
      {}.with_indifferent_access
    end
  end

  attribute :serialized_value, SerializedValueType.new, default: -> { {}.with_indifferent_access }

  before_validation :set_lock
  validates :name, presence: true

  # TODO: Get rid of default scope
  # https://stackoverflow.com/a/1834250/939299
  default_scope { order(created_at: :desc) }
  scope :editable, -> { where(locked: false) }

  after_commit :clear_cache

  def value
    serialized_value[:value]
  end

  def value=(value_to_assigned)
    self.serialized_value = {
      value: value_to_assigned
    }.with_indifferent_access
  end

  private

  def set_lock
    self.locked = true if locked.nil?
  end

  def clear_cache
    GlobalConfig.clear_cache
  end
end
