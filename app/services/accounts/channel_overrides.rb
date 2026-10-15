# frozen_string_literal: true

# Opens or closes channels for ONE clinic, on top of the platform switches. Stored in the account itself
# (custom_attributes['channel_overrides'] = { 'api' => 'shown' }), so it needs no schema change; a channel that
# follows the platform has no entry at all.
#
#   Accounts::ChannelOverrides.new(account: account, actor: super_admin, request: request).apply('api' => 'shown')
#   # => { 'api' => { 'from' => nil, 'to' => 'shown' } }
#
# A state is 'default' (follow the platform: the entry is removed), 'shown' or 'hidden'. Channels that are not named
# keep their entry. Nothing is written, and nothing audited, when nothing changes. Every change leaves one entry in the
# audit log (action update_channel_override) with what changed per channel.
class Accounts::ChannelOverrides
  DEFAULT_STATE = 'default'
  STATES = [DEFAULT_STATE, *Channels::Catalog::STATES].freeze
  AUDIT_ACTION = 'update_channel_override'

  class InvalidOverrides < ArgumentError; end

  def initialize(account:, actor: nil, request: nil)
    @account = account
    @actor = actor
    @request = request
  end

  # requested: { 'api' => 'shown' | 'hidden' | 'default' }. Raises InvalidOverrides, before writing anything, for an
  # unknown channel or state.
  def apply(requested)
    desired = validate!(requested)
    changes = {}
    @account.with_lock do
      current = Accounts::AvailableChannels.overrides(@account)
      changes = diff(current, desired)
      write(merge(current, desired)) if changes.any?
    end
    record_audit(changes) if changes.any?
    changes
  end

  private

  def diff(current, desired)
    desired.each_with_object({}) do |(key, state), changes|
      from = current[key]
      to = state == DEFAULT_STATE ? nil : state
      changes[key] = { 'from' => from, 'to' => to } unless from == to
    end
  end

  def merge(current, desired)
    desired.each_with_object(current.dup) do |(key, state), merged|
      state == DEFAULT_STATE ? merged.delete(key) : merged[key] = state
    end
  end

  def record_audit(changes)
    SuperAdmin::AccountAudit.record(
      account: @account, actor: @actor, action: AUDIT_ACTION, changes: { 'channels' => changes }, request: @request
    )
  end

  def write(overrides)
    attributes = @account.custom_attributes.to_h.deep_dup
    if overrides.empty?
      attributes.delete(Accounts::AvailableChannels::OVERRIDES_KEY)
    else
      attributes[Accounts::AvailableChannels::OVERRIDES_KEY] = overrides
    end
    @account.custom_attributes = attributes
    @account.save!
  end

  def validate!(requested)
    raise InvalidOverrides, 'overrides must be a map of channel => default | shown | hidden' unless requested.respond_to?(:to_h)

    requested.to_h.each_with_object({}) do |(key, state), desired|
      raise InvalidOverrides, "unknown channel: #{key}" unless Channels::Catalog.key?(key)
      raise InvalidOverrides, "unknown state for #{key}: #{state.inspect}" unless STATES.include?(state.to_s)

      desired[key.to_s] = state.to_s
    end
  end
end
