class Integrations::Macrocrm::SyncJob < ApplicationJob
  queue_as :medium

  retry_on StandardError, wait: 10.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id, event_name, message_id)
    hook = Integrations::Hook.find(hook_id)
    message = Message.find(message_id)

    Integrations::Macrocrm::ProcessorService.new(hook: hook, event_name: event_name, message: message).perform
  end
end
