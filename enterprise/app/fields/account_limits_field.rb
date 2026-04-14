require 'administrate/field/base'
require 'bigdecimal'

class AccountLimitsField < Administrate::Field::Base
  STORAGE_GB_IN_BYTES = 1.gigabyte

  LIMIT_DEFINITIONS = {
    agents: {
      label: 'Users',
      hint: 'Maximum users in this account.'
    },
    inboxes: {
      label: 'Channels',
      hint: 'Maximum total channels in this account.'
    },
    conversations: {
      label: 'Conversations',
      hint: 'Maximum new conversations allowed during the current monthly window.'
    },
    non_web_inboxes: {
      label: 'Main channels',
      hint: 'Maximum main channels in this account. Counts WhatsApp Cloud, WhatsApp Web, Telegram Personal, and API channels.'
    },
    storage_bytes: {
      label: 'Storage quota (GB)',
      hint: 'Account-wide file storage quota in gigabytes. Decimals are allowed, for example 1.5.',
      bytes: true,
      step: '0.1'
    },
    captain_responses: {
      label: 'Captain responses',
      hint: 'Allowed Captain response count in the current quota window.'
    },
    captain_documents: {
      label: 'Captain documents',
      hint: 'Maximum Captain documents allowed for this account.'
    },
    captain_tokens: {
      label: 'Captain tokens',
      hint: 'Allowed Captain token usage in the current quota window.'
    },
    emails: {
      label: 'Outbound emails per day',
      hint: 'Daily outbound email quota for account emails such as transcripts, notifications, and automation emails.'
    }
  }.freeze

  def rows
    overrides = normalized_overrides

    LIMIT_DEFINITIONS.map do |key, meta|
      meta.merge(
        key: key,
        input_id: "account_limits_#{key}",
        value: normalize_value(key, overrides[key])
      )
    end
  end

  def to_s
    configured_rows.map do |row|
      value = row[:value]
      next "#{row[:key]}: inherited" if value.nil?

      "#{row[:key]}: #{formatted_value(row)}"
    end.join(', ')
  end

  private

  def configured_rows
    rows.select { |row| row[:value].present? || row[:value] == 0 }
  end

  def normalized_overrides
    (data.presence || {}).to_h.deep_symbolize_keys
  end

  def normalize_value(key, value)
    return if value.blank?
    return bytes_to_gb(value) if key == :storage_bytes
    return Integer(value, 10) if value.is_a?(String) && value.match?(/\A\d+\z/)

    value
  end

  def formatted_value(row)
    return format('%.2f GB', row[:value].to_f).sub(/\.00 GB\z/, ' GB') if row[:bytes]

    row[:value]
  end

  def bytes_to_gb(value)
    (BigDecimal(value.to_s) / STORAGE_GB_IN_BYTES).to_f
  rescue ArgumentError
    value
  end
end
