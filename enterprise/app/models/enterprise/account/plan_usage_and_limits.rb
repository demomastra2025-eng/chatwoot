module Enterprise::Account::PlanUsageAndLimits # rubocop:disable Metrics/ModuleLength
  CAPTAIN_RESPONSES = 'captain_responses'.freeze
  CAPTAIN_DOCUMENTS = 'captain_documents'.freeze
  CAPTAIN_TOKENS = 'captain_tokens'.freeze
  CAPTAIN_RESPONSES_USAGE = 'captain_responses_usage'.freeze
  CAPTAIN_DOCUMENTS_USAGE = 'captain_documents_usage'.freeze
  CAPTAIN_TOKENS_USAGE = 'captain_tokens_usage'.freeze
  MAIN_CHANNEL_TYPES = %w[
    Channel::Api
    Channel::TelegramPersonal
    Channel::Whatsapp
    Channel::WhatsappWeb
  ].freeze

  def usage_limits
    {
      agents: agent_limit_metadata[:value].to_i,
      inboxes: usage_limit_metadata(:inboxes)[:value].to_i,
      conversations: usage_limit_metadata(:conversations)[:value].to_i,
      non_web_inboxes: usage_limit_metadata(:non_web_inboxes)[:value].to_i,
      storage: AccountLimits::StorageUsageService.new(account: self).summary,
      captain: {
        documents: get_captain_limits(:documents),
        responses: get_captain_limits(:responses),
        tokens: get_captain_limits(:tokens)
      }
    }
  end

  def usage_limit_summary(limit_name, consumed:)
    metadata = usage_limit_metadata(limit_name)
    get_usage_summary(total_count: metadata[:value], consumed: consumed, unlimited: metadata[:unlimited])
  end

  def agent_usage_summary(consumed:)
    get_usage_summary(total_count: agent_limit_metadata[:value], consumed: consumed, unlimited: agent_limit_metadata[:unlimited])
  end

  def email_usage_summary(consumed:)
    get_usage_summary(total_count: email_limit_metadata[:value], consumed: consumed, unlimited: email_limit_metadata[:unlimited])
  end

  def usage_limit_metadata(limit_name)
    config_name = "ACCOUNT_#{limit_name.to_s.upcase}_LIMIT"
    account_value = self[:limits]&.[](limit_name.to_s)
    global_value = GlobalConfig.get(config_name)[config_name]

    if account_value.present?
      { value: account_value, unlimited: false }.with_indifferent_access
    elsif global_value.present?
      { value: global_value, unlimited: false }.with_indifferent_access
    else
      { value: ChatwootApp.max_limit, unlimited: true }.with_indifferent_access
    end
  end

  def agent_limit_metadata
    subscribed_quantity = custom_attributes['subscribed_quantity']
    return { value: subscribed_quantity, unlimited: false }.with_indifferent_access if subscribed_quantity.present?

    usage_limit_metadata(:agents)
  end

  def increment_response_usage
    increment_custom_attribute(CAPTAIN_RESPONSES_USAGE)
  end

  def reset_response_usage
    update_custom_attribute(CAPTAIN_RESPONSES_USAGE, 0)
  end

  def update_document_usage
    update_custom_attribute(CAPTAIN_DOCUMENTS_USAGE, captain_documents.count)
  end

  def increment_token_usage(token_count)
    token_count = token_count.to_i
    return if token_count <= 0

    custom_attributes[CAPTAIN_TOKENS_USAGE] = captain_tokens_usage + token_count
    save
  end

  def reset_token_usage
    custom_attributes[CAPTAIN_TOKENS_USAGE] = 0
    save
  end

  def captain_tokens_usage
    consumed_usage(CAPTAIN_TOKENS_USAGE)
  end

  def conversations_this_month_count
    conversations.where('created_at > ?', 30.days.ago).count
  end

  def main_channels_count
    inboxes.where(channel_type: MAIN_CHANNEL_TYPES).count
  end

  def storage_usage_bytes
    AccountLimits::StorageUsageService.new(account: self).usage_bytes
  end

  def captain_quota_available?
    response_available = usage_limits.dig(:captain, :responses, :current_available)
    token_available = usage_limits.dig(:captain, :tokens, :current_available)

    [response_available, token_available].compact.all?(&:positive?)
  end

  def email_transcript_enabled?
    default_plan = InstallationConfig.find_by(name: 'CHATWOOT_CLOUD_PLANS')&.value&.first
    return true if default_plan.blank?

    plan_name.present? && plan_name != default_plan['name']
  end

  def email_rate_limit
    account_limit || plan_email_limit || global_limit || default_limit
  end

  def subscribed_features
    plan_features = InstallationConfig.find_by(name: 'CHATWOOT_CLOUD_PLAN_FEATURES')&.value
    return [] if plan_features.blank?

    plan_features[plan_name]
  end

  def captain_monthly_limit
    {
      documents: captain_limit_metadata(:documents)[:value],
      responses: captain_limit_metadata(:responses)[:value],
      tokens: captain_limit_metadata(:tokens)[:value]
    }.with_indifferent_access
  end

  private

  def get_captain_limits(type)
    consumed = case type
               when :documents
                 consumed_usage(CAPTAIN_DOCUMENTS_USAGE)
               when :tokens
                 consumed_usage(CAPTAIN_TOKENS_USAGE)
               else
                 consumed_usage(CAPTAIN_RESPONSES_USAGE)
               end

    metadata = captain_limit_metadata(type)
    get_usage_summary(total_count: metadata[:value], consumed: consumed, unlimited: metadata[:unlimited])
  end

  def plan_email_limit
    config = InstallationConfig.find_by(name: 'ACCOUNT_EMAILS_PLAN_LIMITS')&.value
    return nil if config.blank? || plan_name.blank?

    parsed = config.is_a?(String) ? JSON.parse(config) : config
    parsed[plan_name.downcase]&.to_i
  rescue StandardError
    nil
  end

  def captain_limit_metadata(type)
    account_limit = self[:limits]&.[](captain_limit_key(type))
    return { value: account_limit, unlimited: false }.with_indifferent_access if account_limit.present?

    plan_quota = InstallationConfig.find_by(name: 'CAPTAIN_CLOUD_PLAN_LIMITS')&.value

    return default_captain_limit_metadata(type) if plan_quota.blank?
    return { value: 0, unlimited: false }.with_indifferent_access if plan_name.blank?

    begin
      parsed_plan_quota = plan_quota.is_a?(String) ? JSON.parse(plan_quota) : plan_quota
      plan_limits = (parsed_plan_quota || plan_quota)[plan_name.downcase]
      return { value: 0, unlimited: false }.with_indifferent_access if plan_limits.blank?

      planned_value = plan_limits[type.to_s]
      return { value: planned_value, unlimited: false }.with_indifferent_access if planned_value.present?

      type.to_sym == :tokens ? usage_limit_metadata(:captain_tokens) : { value: 0, unlimited: false }.with_indifferent_access
    rescue StandardError
      default_captain_limit_metadata(type)
    end
  end

  def default_captain_limit_metadata(type)
    return usage_limit_metadata(:captain_tokens) if type.to_sym == :tokens

    { value: ChatwootApp.max_limit, unlimited: true }.with_indifferent_access
  end

  def plan_name
    custom_attributes['plan_name']
  end

  def captain_limit_key(type)
    "captain_#{type}"
  end

  def get_limits(limit_name)
    usage_limit_metadata(limit_name)[:value]
  end

  # Atomic jsonb_set to avoid clobbering concurrent writes to other custom_attributes keys.
  # Goes through Account relation (rather than raw connection) so shard routing is respected.
  # rubocop:disable Rails/SkipsModelValidations
  def update_custom_attribute(key, value)
    Account.where(id: id).update_all([
                                       "custom_attributes = jsonb_set(COALESCE(custom_attributes, '{}'), ARRAY[:key], :value::jsonb)",
                                       { key: key, value: value.to_json }
                                     ])
    custom_attributes[key] = value
  end

  def increment_custom_attribute(key)
    Account.where(id: id).update_all([
                                       "custom_attributes = jsonb_set(COALESCE(custom_attributes, '{}'), ARRAY[:key], " \
                                       '(COALESCE((custom_attributes ->> :key)::int, 0) + 1)::text::jsonb)',
                                       { key: key }
                                     ])
    custom_attributes[key] = custom_attributes[key].to_i + 1
  end
  # rubocop:enable Rails/SkipsModelValidations

  def validate_limit_keys
    errors.add(:limits, ': Invalid data') unless self[:limits].is_a? Hash
    self[:limits] = {} if self[:limits].blank?

    limit_schema = {
      'type' => 'object',
      'properties' => {
        'inboxes' => { 'type': 'number', 'minimum': 0 },
        'agents' => { 'type': 'number', 'minimum': 0 },
        'conversations' => { 'type': 'number', 'minimum': 0 },
        'non_web_inboxes' => { 'type': 'number', 'minimum': 0 },
        'storage_bytes' => { 'type': 'number', 'minimum': 0 },
        'captain_responses' => { 'type': 'number', 'minimum': 0 },
        'captain_documents' => { 'type': 'number', 'minimum': 0 },
        'captain_tokens' => { 'type': 'number', 'minimum': 0 },
        'emails' => { 'type': 'number', 'minimum': 0 }
      },
      'required' => [],
      'additionalProperties' => false
    }

    schema = JSONSchemer.schema(limit_schema)
    errors.add(:limits, ': Invalid data') unless schema.valid?(self[:limits])
    errors.add(:limits, ': Invalid data') if contains_negative_limit?
  end

  def consumed_usage(attribute_key)
    value = custom_attributes[attribute_key].to_i
    value.negative? ? 0 : value
  end

  def email_limit_metadata
    if account_limit.present?
      { value: account_limit, unlimited: false }.with_indifferent_access
    elsif plan_email_limit.present?
      { value: plan_email_limit, unlimited: false }.with_indifferent_access
    elsif global_limit.present?
      { value: global_limit, unlimited: false }.with_indifferent_access
    else
      { value: default_limit, unlimited: true }.with_indifferent_access
    end
  end

  def get_usage_summary(total_count:, consumed:, unlimited: false)
    total_count = total_count.to_i
    consumed = consumed.to_i

    {
      total_count: total_count,
      current_available: unlimited ? ChatwootApp.max_limit.to_i : (total_count - consumed).clamp(0, total_count),
      consumed: consumed,
      unlimited: unlimited
    }
  end

  def contains_negative_limit?
    self[:limits].to_h.values.any? do |value|
      next false if value.blank?

      value.to_f.negative?
    end
  end
end
