class WebhookJob < ApplicationJob
  queue_as :medium
  retry_on Webhooks::Trigger::RetryableError, wait: :polynomially_longer, attempts: 5 do |job, error|
    url, payload, webhook_type = job.arguments
    kwargs = job.arguments.last.is_a?(Hash) ? job.arguments.last : {}
    Webhooks::Trigger.new(
      url,
      payload,
      webhook_type || :account_webhook,
      secret: kwargs[:secret],
      delivery_id: kwargs[:delivery_id]
    ).handle_failure(error)
  end

  # There are account, inbox, and API inbox webhooks.
  def perform(url, payload, webhook_type = :account_webhook, secret: nil, delivery_id: nil)
    Webhooks::Trigger.execute(url, payload, webhook_type, secret: secret, delivery_id: delivery_id)
  end
end
