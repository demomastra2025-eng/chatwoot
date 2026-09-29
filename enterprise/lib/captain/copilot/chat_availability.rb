# The employee Copilot chat (the floating launcher, the conversation side
# panel and the internal-assistant playground) is retired from the product.
# The reply-box AI writing tools, the customer-facing Captain assistants and
# their playground, MCP and the shared Captain tool classes do not depend on it
# and stay active.
#
# The chat's tables, models, services and jobs are kept on purpose so the
# feature can be revived later: flip ENABLED back to true and restore the
# frontend panel. While it is false the chat endpoints (copilot_threads,
# copilot_messages and the playground of an internal assistant) answer
# 410 Gone, Captain::Copilot::ChatService is not called over HTTP, and no
# Captain::Copilot::ResponseJob is enqueued or executed.
module Captain::Copilot::ChatAvailability
  ENABLED = false
  DISABLED_ERROR = 'copilot_chat_disabled'.freeze

  def self.enabled?
    ENABLED
  end
end
