# Switches of the shared-number ("пациенты с общим номером") capabilities that ship switched off (owner decision
# 2026-09-30: release the core now, finish and enable these later without another rollout).
#
# One installation config per capability, editable by a super admin (Super Admin -> Installation configs); a change
# applies on the next check, without a deploy or a restart. The default is off: only an explicit true (true/1/on/yes)
# enables a capability, and a missing, blank or unreadable value keeps it off. No environment variable and no account
# setting overrides them.
#
#   ONELINK_SHARED_PHONE_AUTO_PROMOTION  M5(a): a MedElement sync makes a card's доп. номер its primary.
#   ONELINK_SHARED_PHONE_MANUAL_PROMOTION  M5(b): the hint, button and dialog in the card and the promote API.
#   ONELINK_SHARED_PHONE_HISTORY_TRANSFER  M6: every move of a number's chats, ContactInboxes, messages, telephony
#     endpoints and touches between contacts: the transfer on promotion, the WhatsApp Web LID amendments and proven-LID
#     moves, the follow-up sweep jobs and the manual revert. A promotion that would have to move chats is blocked while
#     it is off.
#
# With all three off the core still works: family numbers are kept as доп. номер (M1, M2), reminders are routed at send
# time (M3), the card shows where its notifications go (M4) and no automatic merge touches a patient card (M7).
module Contacts::SharedPhoneSwitches
  AUTO_PROMOTION = 'ONELINK_SHARED_PHONE_AUTO_PROMOTION'.freeze
  MANUAL_PROMOTION = 'ONELINK_SHARED_PHONE_MANUAL_PROMOTION'.freeze
  HISTORY_TRANSFER = 'ONELINK_SHARED_PHONE_HISTORY_TRANSFER'.freeze
  KEYS = [AUTO_PROMOTION, MANUAL_PROMOTION, HISTORY_TRANSFER].freeze
  ENABLED_VALUES = %w[true 1 on yes].freeze

  module_function

  def auto_promotion? = enabled?(AUTO_PROMOTION)

  def manual_promotion? = enabled?(MANUAL_PROMOTION)

  def history_transfer? = enabled?(HISTORY_TRANSFER)

  # Reads the installation config through the GlobalConfig cache (cleared when a super admin saves a config). Unlike
  # GlobalConfigService.load it never falls back to ENV and never writes a row.
  def enabled?(key)
    raise ArgumentError, "Unknown shared-number switch #{key}" unless KEYS.include?(key)

    ENABLED_VALUES.include?(GlobalConfig.get_value(key).to_s.strip.downcase)
  rescue Redis::BaseError => e
    Rails.logger.warn({ event: 'shared_phone_switch_unreadable', switch: key, error: e.class.name }.to_json)
    false
  end

  def states = KEYS.index_with { |key| enabled?(key) }
end
