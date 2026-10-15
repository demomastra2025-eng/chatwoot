# frozen_string_literal: true

# Read-only numbers for the super admin «Каналы» page, both keyed by catalog key:
#
#   Channels::Stats.inbox_counts      # => { "website" => 41, "whatsapp_cloud" => 12, ... }   inboxes that exist now
#   Channels::Stats.override_counts   # => { "api" => 2 }                                        clinics with an override
class Channels::Stats
  OVERRIDES_SQL = <<~SQL.squish
    SELECT overrides.key AS channel, COUNT(*) AS clinics
    FROM accounts,
         LATERAL jsonb_each_text(
           CASE WHEN jsonb_typeof(accounts.custom_attributes -> 'channel_overrides') = 'object'
                THEN accounts.custom_attributes -> 'channel_overrides'
                ELSE '{}'::jsonb END
         ) AS overrides(key, value)
    WHERE overrides.value IN ('shown', 'hidden')
    GROUP BY overrides.key
  SQL

  class << self
    # Inboxes that are not being deleted, per catalog key. Twilio channels are split by their medium.
    def inbox_counts
      counts = Hash.new(0)
      Inbox.active.where.not(channel_type: 'Channel::TwilioSms').group(:channel_type).count.each do |channel_type, count|
        add(counts, Channels::Catalog.key_for_inbox_type(channel_type), count)
      end
      twilio_counts.each { |medium, count| add(counts, Channels::Catalog.key_for_twilio_medium(medium), count) }
      counts
    end

    # Clinics that opened or closed the channel for themselves (an override entry), per catalog key
    def override_counts
      counts = Hash.new(0)
      Account.connection.select_rows(OVERRIDES_SQL).each do |channel, clinics|
        add(counts, channel, clinics.to_i)
      end
      counts
    end

    private

    def twilio_counts
      Channel::TwilioSms.joins(:inbox).merge(Inbox.active).group(:medium).count.transform_keys do |medium|
        medium.is_a?(Integer) ? Channel::TwilioSms.mediums.key(medium) : medium
      end
    end

    # Channel types the catalog does not know (retired channels) are not counted
    def add(counts, key, count)
      counts[key] += count if key
    end
  end
end
