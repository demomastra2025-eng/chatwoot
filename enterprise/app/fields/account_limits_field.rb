require 'administrate/field/base'
require 'bigdecimal'

class AccountLimitsField < Administrate::Field::Base
  STORAGE_GB_IN_BYTES = 1.gigabyte

  LIMIT_DEFINITIONS = {
    agents: {
      label: 'Users',
      hint: 'Maximum users in this workspace.',
      group: :workspace
    },
    inboxes: {
      label: 'Channels',
      hint: 'Maximum messaging channels. Call channels are counted separately.',
      group: :workspace
    },
    conversations: {
      label: 'Conversations',
      hint: 'Maximum new conversations allowed during the current monthly window.',
      group: :workspace
    },
    call_inboxes: {
      label: 'Call channels',
      hint: 'Maximum telephony channels (Voice inboxes) in this workspace.',
      group: :workspace
    },
    non_web_inboxes: {
      label: 'Legacy main channels',
      hint: 'Legacy quota for WhatsApp Cloud, WhatsApp Web, Telegram Personal, and API channels.',
      group: :workspace
    },
    storage_bytes: {
      label: 'Storage quota (GB)',
      hint: 'Workspace file storage quota. Decimals are allowed, for example 1.5.',
      group: :workspace,
      bytes: true,
      step: '0.1'
    },
    captain_responses: {
      label: 'AI Agent responses',
      hint: 'Allowed AI Agent response count in the current quota window.',
      group: :ai_and_messaging
    },
    captain_documents: {
      label: 'AI Agent documents',
      hint: 'Maximum knowledge-base documents available to AI Agents.',
      group: :ai_and_messaging
    },
    captain_tokens: {
      label: 'AI Agent tokens',
      hint: 'Allowed AI Agent token usage in the current quota window.',
      group: :ai_and_messaging
    },
    emails: {
      label: 'Outbound emails per day',
      hint: 'Daily outbound email quota for transcripts, notifications, and automation emails.',
      group: :ai_and_messaging
    }
  }.freeze

  GROUPS = {
    workspace: {
      label: 'Workspace capacity',
      hint: 'People, channels, conversations, and storage.'
    },
    ai_and_messaging: {
      label: 'AI and messaging',
      hint: 'AI Agent and outbound email usage quotas.'
    }
  }.freeze

  def rows
    overrides = normalized_overrides

    LIMIT_DEFINITIONS.map do |key, meta|
      meta.merge(
        key: key,
        input_id: "account_limits_#{key}",
        value: normalize_value(key, overrides[key]),
        status: status_for(overrides[key])
      )
    end
  end

  def groups
    GROUPS.map do |key, meta|
      meta.merge(key: key, rows: rows.select { |row| row[:group] == key })
    end
  end

  def to_s
    configured_rows.map do |row|
      value = row[:value]
      next "#{row[:key]}: default" if value.nil?

      "#{row[:key]}: #{formatted_value(row)}"
    end.join(', ')
  end

  private

  def configured_rows
    rows.reject { |row| row[:value].nil? }
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

  def status_for(value)
    return :default if value.blank?
    return :blocked if value.to_s.match?(/\A0(?:\.0+)?\z/)

    :custom
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
