require 'administrate/field/base'

class AccountUsageField < Administrate::Field::Base
  LABELS = {
    agents: 'Agents',
    inboxes: 'Inboxes',
    conversations: 'Conversations',
    non_web_inboxes: 'Connected channels',
    emails: 'Emails today',
    storage: 'Storage',
    captain_documents: 'Captain documents',
    captain_responses: 'Captain responses',
    captain_tokens: 'Captain tokens'
  }.freeze

  def rows
    payload = (data.presence || {}).deep_symbolize_keys

    [
      build_row(:agents, payload[:agents]),
      build_row(:inboxes, payload[:inboxes]),
      build_row(:conversations, payload[:conversations]),
      build_row(:non_web_inboxes, payload[:non_web_inboxes]),
      build_row(:emails, payload[:emails]),
      build_row(:storage, payload[:storage], bytes: true),
      build_row(:captain_documents, payload.dig(:captain, :documents)),
      build_row(:captain_responses, payload.dig(:captain, :responses)),
      build_row(:captain_tokens, payload.dig(:captain, :tokens))
    ].compact
  end

  private

  def build_row(key, value, bytes: false)
    return if value.blank?

    {
      label: LABELS.fetch(key),
      consumed: value[:consumed].to_i,
      total_count: value[:total_count].to_i,
      current_available: value[:current_available].to_i,
      bytes: bytes,
      unlimited: value[:unlimited]
    }
  end
end
