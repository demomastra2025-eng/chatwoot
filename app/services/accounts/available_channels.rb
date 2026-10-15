# frozen_string_literal: true

# The channels one clinic may connect: visible AND allowed by the account's feature flag.
#
# Visible is decided in this order: the clinic's own override (account.custom_attributes['channel_overrides'],
# 'shown' | 'hidden'), else the platform switch (Channels::PlatformVisibility), else the catalog default.
# A channel that has a feature flag (Channels::Catalog) is only available while the clinic has that flag on, so a
# shown channel never appears for a clinic that cannot use it.
#
#   Accounts::AvailableChannels.for(account)                   # => ["website", "facebook", ...]  (operator app payload)
#   Accounts::AvailableChannels.available?(account, 'api')
#   Accounts::AvailableChannels.ensure_available!(account, 'api') # raises Channels::NotAvailable
#
# Only creating a new inbox is guarded with this. Updating, reauthorizing or reconnecting an inbox that exists, the
# Platform API, the super admin and internal jobs never ask: an existing channel keeps working whatever the switches say.
class Accounts::AvailableChannels
  OVERRIDES_KEY = 'channel_overrides'

  class << self
    # Catalog keys, in catalog order
    def for(account)
      new(account).keys
    end

    def available?(account, key)
      new(account).available?(key)
    end

    def ensure_available!(account, key)
      raise Channels::NotAvailable, key unless available?(account, key)

      true
    end

    # The clinic's overrides as { 'api' => 'shown' }; entries of unknown channels or with another state are dropped
    def overrides(account)
      attributes = account&.custom_attributes
      raw = attributes[OVERRIDES_KEY] if attributes.is_a?(Hash)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, state), result|
        result[key.to_s] = state.to_s if Channels::Catalog.key?(key) && Channels::Catalog::STATES.include?(state.to_s)
      end
    end
  end

  def initialize(account, platform_settings: Channels::PlatformVisibility.settings)
    @account = account
    @platform_settings = platform_settings
    @overrides = self.class.overrides(account)
  end

  def keys
    Channels::Catalog.keys.select { |key| available?(key) }
  end

  def available?(key)
    return false unless Channels::Catalog.key?(key)

    visible?(key) && feature_allowed?(key)
  end

  # The clinic's override ('shown' | 'hidden'), nil when it follows the platform
  def override(key)
    @overrides[key.to_s]
  end

  # What the platform alone says about the channel: 'shown' | 'hidden'
  def platform_state(key)
    Channels::PlatformVisibility.state(key, settings: @platform_settings)
  end

  # Override, else platform, else catalog default
  def visible?(key)
    (override(key) || platform_state(key)) == Channels::Catalog::SHOWN
  end

  # True when the channel has no feature flag, or the clinic has the flag on
  def feature_allowed?(key)
    flag = Channels::Catalog.feature_flag(key)
    flag.blank? || @account.feature_enabled?(flag)
  end
end
