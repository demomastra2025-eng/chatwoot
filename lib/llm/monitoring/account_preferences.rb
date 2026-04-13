# frozen_string_literal: true

class Llm::Monitoring::AccountPreferences
  DEFAULT_LOOKBACK_DAYS = 30
  DEFAULT_RETENTION_DAYS = 90
  MAX_SAVED_VIEWS = 20
  VALID_TABS = %w[overview events traces evaluations].freeze
  VALID_ALERT_SEVERITIES = %w[warning critical].freeze
  VALID_ALERT_CHECKS = %w[
    operational_release_gate
    deterministic_evals
    live_evals
  ].freeze

  DEFAULTS = {
    'default_lookback_days' => DEFAULT_LOOKBACK_DAYS,
    'retention_days' => DEFAULT_RETENTION_DAYS,
    'saved_views' => [],
    'alert_channels' => {
      'enabled' => false,
      'minimum_severity' => 'warning',
      'email_recipients' => [],
      'webhook_url' => nil,
      'notify_on' => ['operational_release_gate']
    }
  }.freeze

  FILTER_KEYS = %w[
    feature
    runtime_mode
    status
    flag
    model
    event_name
    tool_name
    schema_name
    trace_id
    session_id
    conversation_display_id
    copilot_thread_id
    assistant_id
    since
    until
  ].freeze

  class << self
    def for_account(account)
      normalize(account&.captain_observability)
    end
    alias_method :for, :for_account

    def merge(account:, attributes:)
      normalize(for_account(account).deep_merge(attributes.to_h.deep_stringify_keys))
    end

    def default_date_range(account:, now: Time.current)
      preferences = for_account(account)
      days = normalize_integer(
        preferences['default_lookback_days'],
        default: DEFAULT_LOOKBACK_DAYS,
        minimum: 1,
        maximum: 365
      )

      (now - days.days)..now
    end

    private

    def normalize(raw_preferences)
      raw = raw_preferences.to_h.deep_stringify_keys
      preferences = DEFAULTS.deep_dup.deep_merge(raw)

      preferences['default_lookback_days'] = normalize_integer(
        preferences['default_lookback_days'],
        default: DEFAULT_LOOKBACK_DAYS,
        minimum: 1,
        maximum: 365
      )
      preferences['retention_days'] = normalize_integer(
        preferences['retention_days'],
        default: DEFAULT_RETENTION_DAYS,
        minimum: 7,
        maximum: 3650
      )
      preferences['saved_views'] = normalize_saved_views(preferences['saved_views'])
      preferences['alert_channels'] = normalize_alert_channels(preferences['alert_channels'])
      preferences
    end

    def normalize_saved_views(value)
      Array(value).first(MAX_SAVED_VIEWS).filter_map do |saved_view|
        payload = saved_view.to_h.deep_stringify_keys
        name = payload['name'].to_s.strip
        next if name.blank?

        {
          'id' => payload['id'].presence || SecureRandom.uuid,
          'name' => name.first(80),
          'tab' => normalized_tab(payload['tab']),
          'filters' => normalize_filters(payload['filters'])
        }
      end
    end

    def normalize_alert_channels(value)
      payload = value.to_h.deep_stringify_keys
      minimum_severity = payload['minimum_severity'].to_s
      webhook_url = payload['webhook_url'].to_s.strip

      {
        'enabled' => ActiveModel::Type::Boolean.new.cast(payload['enabled']),
        'minimum_severity' => VALID_ALERT_SEVERITIES.include?(minimum_severity) ? minimum_severity : 'warning',
        'email_recipients' => normalize_email_recipients(payload['email_recipients']),
        'webhook_url' => webhook_url.presence,
        'notify_on' => normalize_alert_checks(payload['notify_on'])
      }
    end

    def normalize_email_recipients(value)
      Array(value).filter_map do |email|
        normalized = email.to_s.strip.downcase
        next if normalized.blank?
        next unless URI::MailTo::EMAIL_REGEXP.match?(normalized)

        normalized
      end.uniq
    end

    def normalize_alert_checks(value)
      normalized = Array(value).filter_map do |check_name|
        check_name.to_s if VALID_ALERT_CHECKS.include?(check_name.to_s)
      end

      normalized.presence || ['operational_release_gate']
    end

    def normalize_filters(value)
      payload = value.to_h.deep_stringify_keys

      FILTER_KEYS.each_with_object({}) do |key, result|
        normalized = normalize_filter_value(key, payload[key])
        result[key] = normalized if normalized.present?
      end
    end

    def normalize_filter_value(key, value)
      case key
      when 'conversation_display_id', 'copilot_thread_id', 'assistant_id'
        normalize_integer(value, default: nil, minimum: 1, maximum: 9_223_372_036_854_775_807)
      when 'since', 'until'
        digits = value.to_s.strip
        digits.match?(/\A\d+\z/) ? digits : nil
      else
        value.to_s.strip.presence
      end
    end

    def normalized_tab(value)
      tab = value.to_s
      VALID_TABS.include?(tab) ? tab : 'events'
    end

    def normalize_integer(value, default:, minimum:, maximum:)
      integer = Integer(value)
      return default if integer < minimum || integer > maximum

      integer
    rescue ArgumentError, TypeError
      default
    end
  end
end
