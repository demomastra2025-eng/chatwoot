class Captain::Tools::Copilot::UpdateWebhookService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_webhook'
  end

  description 'Update an existing account webhook'
  param :webhook_id, type: :integer, desc: 'Webhook ID', required: true
  param :url, type: :string, desc: 'Updated destination URL', required: false
  param :subscriptions, type: :array, desc: 'Updated webhook subscriptions', required: false
  param :name, type: :string, desc: 'Updated webhook name', required: false
  param :inbox_id, type: :integer, desc: 'Updated inbox ID', required: false

  def execute(webhook_id:, url: nil, subscriptions: nil, name: nil, inbox_id: nil)
    ensure_account_administrator!

    webhook = account.webhooks.find(webhook_id)
    attrs = {}
    attrs[:url] = url.to_s.strip unless url.nil?
    attrs[:name] = name.to_s.strip.presence unless name.nil?
    attrs[:inbox_id] = inbox_id unless inbox_id.nil?
    attrs[:subscriptions] = normalized_subscriptions(subscriptions) unless subscriptions.nil?
    webhook.update!(attrs)

    formatted_payload(action: 'update_webhook', webhook: webhook_payload(webhook.reload))
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
