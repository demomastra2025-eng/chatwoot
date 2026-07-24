require 'digest'

class Whatsapp::LifecycleWebhookService
  FIELDS = %w[
    account_alerts
    account_review_update
    business_capability_update
    message_template_components_update
    message_template_quality_update
    message_template_status_update
    phone_number_name_update
    phone_number_quality_update
    security
    template_category_update
    user_preferences
  ].freeze
  TEMPLATE_FIELDS = %w[
    message_template_components_update
    message_template_quality_update
    message_template_status_update
    template_category_update
  ].freeze
  SUMMARY_FIELDS = %i[
    event message_template_id message_template_name message_template_language message_template_category
    new_quality_score previous_quality_score new_category previous_category correct_category
    category_update_timestamp max_daily_conversations_per_business max_phone_numbers_per_business
    max_phone_numbers_per_waba current_limit entity_type
  ].freeze

  STATE_KEY = 'meta_webhook_lifecycle'.freeze
  MAX_RECENT_FINGERPRINTS = 100

  def initialize(channel:, field:, params:)
    @channel = channel
    @field = field.to_s
    @params = params.with_indifferent_access
    @value = @params.dig(:entry, 0, :changes, 0, :value).to_h.with_indifferent_access
  end

  def perform
    return :unsupported unless FIELDS.include?(@field)

    result = :duplicate
    @channel.with_lock do
      config = @channel.provider_config.to_h.deep_stringify_keys
      state = config[STATE_KEY].to_h.deep_stringify_keys
      fingerprints = Array(state['recent_fingerprints'])
      next if fingerprints.include?(fingerprint)

      if update_template_cache! == :stale
        result = :stale
        next
      end
      update_marketing_preferences!(state)
      config[STATE_KEY] = updated_state(state, fingerprints)
      persist_provider_config!(config)
      result = :processed
    end

    Channels::Whatsapp::TemplatesSyncJob.perform_later(@channel) if result == :processed && TEMPLATE_FIELDS.include?(@field)
    result
  end

  private

  def fingerprint
    @fingerprint ||= Digest::SHA256.hexdigest(
      JSON.generate(canonicalize(field: @field, entry: @params[:entry]))
    )
  end

  def canonicalize(value)
    case value
    when Hash
      value.to_h.deep_stringify_keys.sort.to_h.transform_values { |item| canonicalize(item) }
    when Array
      value.map { |item| canonicalize(item) }
    else
      value
    end
  end

  def updated_state(state, fingerprints)
    counters = state['counters'].to_h.deep_stringify_keys
    counters[@field] = counters[@field].to_i + 1
    latest = state['latest'].to_h.deep_stringify_keys
    latest[@field] = lifecycle_summary

    state.merge(
      'recent_fingerprints' => (fingerprints + [fingerprint]).last(MAX_RECENT_FINGERPRINTS),
      'counters' => counters,
      'latest' => latest,
      'last_event_at' => Time.current.utc.iso8601
    )
  end

  def lifecycle_summary
    summary = @value.slice(*SUMMARY_FIELDS).deep_stringify_keys
    summary['entry_id'] = @params.dig(:entry, 0, :id).to_s.presence
    summary['triggered_at'] = @params.dig(:entry, 0, :time)
    summary['alert'] = lifecycle_alert_summary
    summary['user_preferences'] = lifecycle_preference_summaries
    summary.compact
  end

  def lifecycle_alert_summary
    @value[:alert_info].to_h.slice(:alert_severity, :alert_status, :alert_type).deep_stringify_keys.presence
  end

  def lifecycle_preference_summaries
    Array(@value[:user_preferences]).map do |preference|
      preference.to_h.with_indifferent_access.slice(:category, :value, :timestamp).deep_stringify_keys
    end
  end

  def update_template_cache!
    return :not_applicable unless TEMPLATE_FIELDS.include?(@field)

    templates = Array(@channel.message_templates).map(&:deep_dup)
    template = templates.find { |candidate| matching_template?(candidate.with_indifferent_access) }
    return :missing if template.blank?

    attributes = template.with_indifferent_access
    return :stale unless template_event_applicable?(attributes)

    update_template_attributes!(attributes)
    record_template_event_version!(attributes)
    attributes[:lifecycle_updated_at] = Time.current.utc.iso8601
    template.replace(attributes.to_h.deep_stringify_keys)
    @channel.update_message_templates_cache!(templates)
    :updated
  end

  def template_event_applicable?(attributes)
    current = attributes[:lifecycle_event_versions].to_h[@field].to_h.with_indifferent_access
    return true if current.blank?

    timestamp = template_event_timestamp
    timestamp.present? && timestamp > current[:provider_timestamp].to_i
  end

  def record_template_event_version!(attributes)
    versions = attributes[:lifecycle_event_versions].to_h.deep_stringify_keys
    versions[@field] = {
      'provider_timestamp' => template_event_timestamp,
      'fingerprint' => fingerprint
    }.compact
    attributes[:lifecycle_event_versions] = versions
  end

  def template_event_timestamp
    @template_event_timestamp ||= begin
      raw = @field == 'template_category_update' ? @value[:category_update_timestamp].presence : nil
      raw ||= @params.dig(:entry, 0, :time)
      parse_provider_timestamp(raw)
    end
  end

  def parse_provider_timestamp(value)
    return value.to_i if value.to_s.match?(/\A\d+\z/) && value.to_i.positive?

    Time.zone.parse(value.to_s)&.to_i
  rescue ArgumentError, TypeError
    nil
  end

  def update_template_attributes!(attributes)
    case @field
    when 'message_template_status_update'
      update_template_status_attributes!(attributes)
    when 'message_template_quality_update'
      attributes[:quality_score] = @value[:new_quality_score]
    when 'template_category_update'
      update_template_category_attributes!(attributes)
    end
  end

  def update_template_status_attributes!(attributes)
    attributes[:status] = @value[:event] if @value[:event].present?
    attributes[:category] = @value[:message_template_category] if @value[:message_template_category].present?
    attributes[:reason] = @value[:reason] if @value.key?(:reason)
  end

  def update_template_category_attributes!(attributes)
    attributes[:category] = @value[:new_category] if @value[:new_category].present?
    attributes[:correct_category] = @value[:correct_category] if @value[:correct_category].present?
    attributes[:category_update_timestamp] = @value[:category_update_timestamp] if @value[:category_update_timestamp].present?
  end

  def matching_template?(template)
    id_matches = @value[:message_template_id].present? && template[:id].to_s == @value[:message_template_id].to_s
    identity_matches = template[:name].to_s == @value[:message_template_name].to_s &&
                       template[:language].to_s == @value[:message_template_language].to_s
    id_matches || identity_matches
  end

  def update_marketing_preferences!(state)
    return unless @field == 'user_preferences'

    service = Whatsapp::MarketingPreferenceService.new(channel: @channel, lifecycle_state: state)
    Array(@value[:user_preferences]).each { |preference| service.apply(preference) }
  end

  def persist_provider_config!(config)
    # rubocop:disable Rails/SkipsModelValidations
    @channel.update_column(:provider_config, config)
    # rubocop:enable Rails/SkipsModelValidations
  end
end
