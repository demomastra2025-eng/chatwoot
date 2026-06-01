class LinkedinPersonal::Config
  KEYS = {
    gateway_url: 'LINKEDIN_PERSONAL_GATEWAY_URL',
    gateway_token: 'LINKEDIN_PERSONAL_GATEWAY_TOKEN',
    graph_query_conversations: 'LINKEDIN_PERSONAL_GRAPHQL_CONVERSATIONS_QUERY_ID',
    graph_query_messages: 'LINKEDIN_PERSONAL_GRAPHQL_MESSAGES_QUERY_ID',
    sync_thread_limit: 'LINKEDIN_PERSONAL_SYNC_THREAD_LIMIT',
    sync_message_limit: 'LINKEDIN_PERSONAL_SYNC_MESSAGE_LIMIT',
    poll_interval_seconds: 'LINKEDIN_PERSONAL_POLL_INTERVAL_SECONDS',
    poll_thread_limit: 'LINKEDIN_PERSONAL_POLL_THREAD_LIMIT',
    poll_message_limit: 'LINKEDIN_PERSONAL_POLL_MESSAGE_LIMIT',
    request_timeout_seconds: 'LINKEDIN_PERSONAL_REQUEST_TIMEOUT_SECONDS',
    min_send_interval_seconds: 'LINKEDIN_PERSONAL_MIN_SEND_INTERVAL_SECONDS'
  }.freeze

  DEFAULTS = {
    gateway_url: 'http://linkedin_personal_gateway:8010',
    gateway_token: nil,
    graph_query_conversations: 'messengerConversations.0d5e6781bbee71c3e51c8843c6519f48',
    graph_query_messages: 'messengerMessages.21eabeb3ee872254060ef21b793ea7d0',
    sync_thread_limit: 20,
    sync_message_limit: 50,
    poll_interval_seconds: 30,
    poll_thread_limit: 20,
    poll_message_limit: 10,
    request_timeout_seconds: 30,
    min_send_interval_seconds: 2
  }.freeze

  class << self
    def gateway_url
      value(:gateway_url).to_s.chomp('/')
    end

    def gateway_token
      value(:gateway_token).to_s
    end

    def configured?
      gateway_url.present? && gateway_token.present?
    end

    def runtime_settings
      {
        graph_query_conversations: value(:graph_query_conversations),
        graph_query_messages: value(:graph_query_messages),
        sync_thread_limit: integer_value(:sync_thread_limit),
        sync_message_limit: integer_value(:sync_message_limit),
        poll_interval_seconds: integer_value(:poll_interval_seconds),
        poll_thread_limit: integer_value(:poll_thread_limit),
        poll_message_limit: integer_value(:poll_message_limit),
        request_timeout_seconds: numeric_value(:request_timeout_seconds),
        min_send_interval_seconds: numeric_value(:min_send_interval_seconds)
      }.compact
    end

    private

    def integer_value(key)
      raw_value = value(key)
      return DEFAULTS[key] if raw_value.blank?

      raw_value.to_i
    end

    def numeric_value(key)
      raw_value = value(key)
      return DEFAULTS[key] if raw_value.blank?

      raw_value.to_f
    end

    def value(key)
      config_key = KEYS.fetch(key)
      GlobalConfigService.load(config_key, ENV.fetch(config_key, DEFAULTS[key]))
    end
  end
end
