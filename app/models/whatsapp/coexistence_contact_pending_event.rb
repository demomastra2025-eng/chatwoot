class Whatsapp::CoexistenceContactPendingEvent < ApplicationRecord
  LEGACY_RAW_PHONE_SQL = <<~SQL.squish.freeze
    regexp_replace(COALESCE(entry #>> '{contact,phone_number}', ''), '[^0-9]', '', 'g')
  SQL
  LEGACY_PHONE_IDENTITY_SQL = <<~SQL.squish.freeze
    CASE
      WHEN #{LEGACY_RAW_PHONE_SQL} LIKE '55%' AND char_length(#{LEGACY_RAW_PHONE_SQL}) <> 13
        THEN substring(#{LEGACY_RAW_PHONE_SQL} FROM 1 FOR 4) || '9' || substring(#{LEGACY_RAW_PHONE_SQL} FROM 5)
      WHEN #{LEGACY_RAW_PHONE_SQL} LIKE '54%'
        THEN regexp_replace(#{LEGACY_RAW_PHONE_SQL}, '^549', '54')
      ELSE NULLIF(#{LEGACY_RAW_PHONE_SQL}, '')
    END
  SQL

  self.table_name = 'whatsapp_coexistence_contact_pending_events'

  belongs_to :account
  belongs_to :channel, class_name: 'Channel::Whatsapp'

  validates :event_key, :reason, presence: true
  validates :event_key, uniqueness: { scope: :channel_id }
  validate :channel_belongs_to_account

  def ledger_payload
    { 'key' => event_key, 'reason' => reason, 'phone_identity' => phone_identity, 'entry' => entry.to_h }.compact
  end

  def self.matching_phone_identities(phone_identities)
    identities = Array(phone_identities).compact_blank.uniq
    return none if identities.empty?

    where(phone_identity: identities).or(
      where(phone_identity: nil).where("#{LEGACY_PHONE_IDENTITY_SQL} IN (?)", identities)
    )
  end

  private

  def channel_belongs_to_account
    return if channel.blank? || account_id == channel.account_id

    errors.add(:channel, 'must belong to the same account')
  end
end
