# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateCaptainInboxAutoReplyModeService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_captain_inbox_auto_reply_mode'
  end

  description 'Update the Captain auto-reply mode for an account inbox already connected to an AI assistant'
  param :inbox_id, type: :number, desc: 'Account inbox ID', required: true
  param :auto_reply_mode,
        type: :string,
        desc: "Auto-reply mode: #{CaptainInbox::AUTO_REPLY_MODES.join(', ')}",
        required: true

  def execute(inbox_id:, auto_reply_mode:)
    inbox = account.inboxes.active.find(inbox_id)
    captain_inbox = captain_inbox_for!(inbox)

    captain_inbox.update!(auto_reply_mode: normalized_auto_reply_mode(auto_reply_mode))

    formatted_payload(update_payload(inbox, captain_inbox))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def captain_inbox_for!(inbox)
    inbox.captain_inbox || raise(ArgumentError, 'Inbox is not connected to a Captain assistant')
  end

  def normalized_auto_reply_mode(value)
    normalized = value.to_s.strip
    return normalized if CaptainInbox::AUTO_REPLY_MODES.include?(normalized)

    raise ArgumentError, "auto_reply_mode must be one of: #{CaptainInbox::AUTO_REPLY_MODES.join(', ')}"
  end

  def update_payload(inbox, captain_inbox)
    {
      action: 'update_captain_inbox_auto_reply_mode',
      inbox: {
        id: inbox.id,
        name: inbox.name,
        channel_type: inbox.display_channel_type
      },
      captain: {
        assistant_id: captain_inbox.captain_assistant_id,
        assistant_name: captain_inbox.captain_assistant&.name,
        auto_reply_mode: captain_inbox.auto_reply_mode,
        auto_reply_allowed_now: captain_inbox.auto_reply_allowed_now?
      }
    }
  end
end
