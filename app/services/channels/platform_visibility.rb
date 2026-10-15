# frozen_string_literal: true

# The platform-level switch of every channel: InstallationConfig CHANNEL_VISIBILITY, a JSON object of
# channel key => "shown" | "hidden". A missing row, a missing key or an unusable value means the catalog default,
# so the platform needs no row at all until someone changes a switch.
#
#   Channels::PlatformVisibility.settings                  # => { "api" => "shown" }   (only what differs from the default)
#   Channels::PlatformVisibility.state('api')               # => "shown"
#   Channels::PlatformVisibility.update!({ 'api' => 'shown' }, actor: super_admin, request: request)
#
# Only the deviations from the catalog default are stored, so a channel that goes back to its default leaves no trace
# in the row. Every change leaves one entry in the audit log (action update_channel_visibility).
class Channels::PlatformVisibility
  CONFIG_NAME = 'CHANNEL_VISIBILITY'
  AUDIT_ACTION = 'update_channel_visibility'

  class InvalidSettings < ArgumentError; end

  class << self
    # The stored deviations from the catalog defaults. Unknown channels and unusable states are ignored.
    def settings
      normalize(InstallationConfig.find_by(name: CONFIG_NAME)&.value)
    end

    # 'shown' or 'hidden' for one channel, given the settings (read once by the caller when it asks about many channels)
    def state(key, settings: self.settings)
      settings.fetch(key.to_s) { Channels::Catalog.default_state(key) }
    end

    def shown?(key, settings: self.settings)
      state(key, settings: settings) == Channels::Catalog::SHOWN
    end

    # The moment the settings were last saved (a Time in UTC), nil while nobody has saved them
    def updated_at
      InstallationConfig.find_by(name: CONFIG_NAME)&.updated_at
    end

    # Saves the requested states ({ 'api' => 'shown' }, channels that are not named stay as they are) and audits what
    # changed. Returns { 'api' => { 'from' => 'hidden', 'to' => 'shown' } }; nothing is written when nothing changes.
    # Raises InvalidSettings, before writing anything, for an unknown channel or a state other than shown / hidden.
    def update!(requested, actor: nil, request: nil)
      desired = validate!(requested)
      config = InstallationConfig.find_or_initialize_by(name: CONFIG_NAME)
      changes = {}
      InstallationConfig.transaction do
        config.lock! if config.persisted?
        changes = write(config, normalize(config.value), desired)
      end
      # After the commit: a failing audit insert must not poison the transaction that saved the setting
      record_audit(config, changes, actor, request) if changes.any?
      changes
    end

    private

    def write(config, before, desired)
      after = before.merge(desired).reject { |key, state| state == Channels::Catalog.default_state(key) }
      changes = effective_changes(before, after, desired.keys)
      return {} if changes.empty?

      config.value = after
      config.locked = false
      config.save!
      changes
    end

    def effective_changes(before, after, keys)
      keys.each_with_object({}) do |key, changes|
        from = state(key, settings: before)
        to = state(key, settings: after)
        changes[key] = { 'from' => from, 'to' => to } unless from == to
      end
    end

    def validate!(requested)
      raise InvalidSettings, 'channel settings must be a map of channel => shown | hidden' unless requested.respond_to?(:to_h)

      requested.to_h.each_with_object({}) do |(key, state), desired|
        raise InvalidSettings, "unknown channel: #{key}" unless Channels::Catalog.key?(key)
        raise InvalidSettings, "unknown state for #{key}: #{state.inspect}" unless Channels::Catalog::STATES.include?(state.to_s)

        desired[key.to_s] = state.to_s
      end
    end

    def normalize(raw)
      raw = parse_json(raw) if raw.is_a?(String)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, state), settings|
        settings[key.to_s] = state.to_s if Channels::Catalog.key?(key) && Channels::Catalog::STATES.include?(state.to_s)
      end
    end

    def parse_json(raw)
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def record_audit(config, changes, actor, request)
      SuperAdmin::PlatformAudit.record(auditable: config, action: AUDIT_ACTION, actor: actor, changes: { 'channels' => changes }, request: request)
    end
  end
end
