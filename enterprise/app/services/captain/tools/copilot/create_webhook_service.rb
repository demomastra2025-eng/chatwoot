class Captain::Tools::Copilot::CreateWebhookService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_webhook'
  end

  description 'Create an account webhook'
  param :url, type: :string, desc: 'Destination webhook URL', required: true
  param :subscriptions, type: :array, desc: 'Webhook event names to subscribe to', required: true
  param :name, type: :string, desc: 'Optional webhook name', required: false
  param :inbox_id, type: :integer, desc: 'Optional inbox ID for inbox-scoped webhooks', required: false

  def execute(url:, subscriptions:, name: nil, inbox_id: nil)
    webhook = account.webhooks.create!(
      url: url.to_s.strip,
      name: name.to_s.strip.presence,
      inbox_id: inbox_id,
      subscriptions: normalized_subscriptions(subscriptions)
    )

    formatted_payload(action: 'create_webhook', webhook: webhook_payload(webhook))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def normalized_subscriptions(subscriptions)
    Array(subscriptions).flatten.filter_map { |item| item.to_s.strip.presence }.uniq
  end

  def webhook_payload(webhook)
    {
      id: webhook.id,
      name: webhook.name,
      url_configured: webhook.url.present?,
      account_id: webhook.account_id,
      subscriptions: webhook.subscriptions,
      secret_configured: webhook.secret.present?,
      inbox: webhook.inbox.present? ? { id: webhook.inbox.id, name: webhook.inbox.name } : nil,
      created_at: webhook.created_at&.iso8601,
      updated_at: webhook.updated_at&.iso8601
    }
  end
end
