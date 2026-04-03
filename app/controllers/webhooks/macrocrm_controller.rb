class Webhooks::MacrocrmController < ActionController::API
  def manager_changed
    hook = Integrations::Hook.find_by(app_id: 'macrocrm', reference_id: params[:webhook_key])
    return head :ok if hook.blank?

    enqueue_manager_changed_processing(hook)
    head :ok
  rescue StandardError => e
    Rails.logger.error("[MACROCRM][MANAGER_CHANGED] Controller error: #{e.class} #{e.message}")
    head :ok
  end

  private

  def enqueue_manager_changed_processing(hook)
    Integrations::Macrocrm::ManagerChangedJob.perform_later(hook.id, request_payload)
  rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error => e
    Rails.logger.warn("[MACROCRM][MANAGER_CHANGED] Async enqueue failed, processing inline: #{e.class} #{e.message}")
    Integrations::Macrocrm::ManagerChangedProcessorService.new(hook: hook, payload: request_payload).perform
  end

  def request_payload
    @request_payload ||= params.to_unsafe_h
      .except('controller', 'action', 'webhook_key')
      .deep_stringify_keys
  end
end
