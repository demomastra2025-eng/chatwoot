# frozen_string_literal: true

# Saves one setting of the settings pages (an InstallationConfig) and, when its value changed, writes one entry of the
# audit log: the NAME of the setting and its old and new value, or only that the value «changed» when the setting is a
# secret (the value of a secret is never written anywhere but the setting itself).
#
#   errors = SuperAdmin::AppConfigSaver.new(actor: current_super_admin, request: request).save('FB_APP_ID', 'new', secret: false)
#   errors # => [] when saved, the messages of the record when not
class SuperAdmin::AppConfigSaver
  AUDIT_ACTION = 'update_setting'
  # The longest old or new value that an entry keeps
  VALUE_LIMIT = 300
  # A short list of models is longer than that and the page offers to put the old list back, so it is kept whole
  LONG_VALUE_LIMITS = { Llm::Models::MODEL_ALLOWLIST_INSTALLATION_CONFIG => 1000 }.freeze

  def self.value_limit(name)
    LONG_VALUE_LIMITS.fetch(name.to_s, VALUE_LIMIT)
  end

  def initialize(actor:, request: nil)
    @actor = actor
    @request = request
  end

  def save(name, value, secret:)
    config = InstallationConfig.where(name: name).first_or_initialize(locked: false)
    previous = config.new_record? ? nil : config.value
    config.value = value
    return config.errors.full_messages unless config.save

    audit(config, previous, secret) if config.saved_change_to_serialized_value?
    []
  end

  private

  def audit(config, previous, secret)
    value = secret ? 'changed' : [text(previous, config.name), text(config.value, config.name)]
    SuperAdmin::PlatformAudit.record(
      auditable: config, action: AUDIT_ACTION, actor: @actor, request: @request, changes: { 'name' => config.name, 'value' => value }
    )
  end

  def text(value, name)
    SuperAdmin::InstallationConfigs.printable(value).truncate(self.class.value_limit(name))
  end
end
