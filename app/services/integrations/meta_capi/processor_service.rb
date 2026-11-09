# frozen_string_literal: true

class Integrations::MetaCapi::ProcessorService
  DEDUP_TTL_SECONDS = 30.days.to_i

  def self.process_hook_event(hook, event_name)
    return { error: 'No processor found' } unless %w[test sync].include?(event_name.to_s)
    return { error: 'Meta Conversions API integration is disabled' } unless hook.enabled?

    summary = new(hook: hook, event_name: 'test').perform
    { message: 'Meta Conversions API test event sent successfully', sync_summary: summary }
  rescue Integrations::MetaCapi::ApiClient::ApiError => e
    { error: e.message }
  end

  def initialize(hook:, event_name: nil, event_data: {})
    @hook = hook
    @account = hook.account
    @event_name = event_name.to_s
    @event_data = event_data.to_h.with_indifferent_access
  end

  def perform
    return { skipped: true, reason: 'hook_disabled' } unless @hook.enabled?

    case @event_name
    when 'crm.deal.created'
      handle_deal_created(@event_data[:deal])
    when 'crm.deal.stage_changed'
      handle_deal_stage_changed(@event_data[:deal])
    when 'appointment.created'
      handle_appointment_created(@event_data[:appointment])
    when 'appointment.completed', 'appointment.updated'
      handle_appointment_conversion(@event_data[:appointment])
    when 'test', 'sync'
      handle_test_event
    else
      { skipped: true, reason: "unsupported_event:#{@event_name}" }
    end
  end

  private

  def handle_deal_created(deal)
    return { skipped: true, reason: 'missing_deal' } if deal.blank?
    return handle_deal_stage_changed(deal) if deal.stage&.outcome_won?
    return { skipped: true, reason: 'lead_event_disabled' } unless setting_enabled?('send_lead_on_deal_created')

    dispatch_deal_event(deal, event_name: 'Lead', event_id: "onelink_deal_lead_#{deal.id}")
  end

  def handle_deal_stage_changed(deal)
    return { skipped: true, reason: 'missing_deal' } if deal.blank?
    return { skipped: true, reason: 'stage_not_won' } unless deal.stage&.outcome_won?
    return { skipped: true, reason: 'purchase_event_disabled' } unless setting_enabled?('send_purchase_on_deal_won')

    dispatch_deal_event(deal, event_name: 'Purchase', event_id: "onelink_deal_purchase_#{deal.id}")
  end

  def handle_appointment_created(appointment)
    return { skipped: true, reason: 'missing_appointment' } if appointment.blank?
    return { skipped: true, reason: 'schedule_event_disabled' } unless setting_enabled?('send_schedule_on_appointment_created')

    dispatch_appointment_event(appointment, event_name: 'Schedule', event_id: "onelink_appointment_schedule_#{appointment.id}")
  end

  def handle_appointment_conversion(appointment)
    return { skipped: true, reason: 'missing_appointment' } if appointment.blank?
    return { skipped: true, reason: 'purchase_event_disabled' } unless setting_enabled?('send_purchase_on_deal_won')
    return { skipped: true, reason: 'not_paid_or_completed' } unless appointment_converted?(appointment)

    dispatch_appointment_event(appointment, event_name: 'Purchase', event_id: "onelink_appointment_purchase_#{appointment.id}")
  end

  def handle_test_event
    event_payload = Integrations::MetaCapi::PayloadBuilder.new(account: @account, hook: @hook).build_test_event
    deliver_event!(event_payload)
  end

  def dispatch_deal_event(deal, event_name:, event_id:)
    return { skipped: true, reason: 'already_sent', event_id: event_id } if already_sent?(event_id)

    payload = Integrations::MetaCapi::PayloadBuilder.new(account: @account, hook: @hook, record: deal)
                                                    .build_deal_event(event_name: event_name, event_id: event_id)
    result = deliver_event!(payload)
    mark_sent!(event_id)
    result
  end

  def dispatch_appointment_event(appointment, event_name:, event_id:)
    return { skipped: true, reason: 'already_sent', event_id: event_id } if already_sent?(event_id)

    payload = Integrations::MetaCapi::PayloadBuilder.new(account: @account, hook: @hook, record: appointment)
                                                    .build_appointment_event(event_name: event_name, event_id: event_id)
    result = deliver_event!(payload)
    mark_sent!(event_id)
    result
  end

  def deliver_event!(event_payload)
    response = api_client.send_events([event_payload], test_event_code: test_event_code)
    summary = {
      synced_at: Time.current.iso8601,
      last_event_name: event_payload[:event_name],
      last_event_id: event_payload[:event_id],
      action_source: event_payload[:action_source],
      events_received: response['events_received'].to_i,
      fbtrace_id: response['fbtrace_id']
    }
    persist_sync_summary!(summary)
    summary
  end

  def api_client
    Integrations::MetaCapi::ApiClient.new(
      dataset_id: @hook.settings&.dig('dataset_id'),
      access_token: resolve_access_token
    )
  end

  def resolve_access_token
    secret_token = @hook.secret_settings['access_token'].presence || @hook.secret_settings['api_token'].presence
    return secret_token.to_s.strip if secret_token.present?

    raw = @hook.access_token.to_s.strip
    raw.start_with?('{') ? '' : raw
  end

  def test_event_code
    @hook.settings&.dig('test_event_code').to_s.strip.presence
  end

  def setting_enabled?(key)
    val = @hook.settings&.dig(key)
    val.nil? || ActiveModel::Type::Boolean.new.cast(val)
  end

  def appointment_converted?(appointment)
    appointment.status == 'completed' || appointment.payment_status.in?(%w[paid prepaid])
  end

  def already_sent?(event_id)
    Redis::Alfred.get(dedup_key(event_id)).present?
  rescue StandardError
    false
  end

  def mark_sent!(event_id)
    Redis::Alfred.setex(dedup_key(event_id), '1', DEDUP_TTL_SECONDS)
  rescue StandardError
    nil
  end

  def dedup_key(event_id)
    "meta_capi:sent:#{@account.id}:#{event_id}"
  end

  def persist_sync_summary!(summary)
    current = @hook.settings.is_a?(Hash) ? @hook.settings.deep_dup : {}
    total = current.dig('last_sync_summary', 'total_sent').to_i + summary[:events_received].to_i
    current['last_synced_at'] = summary[:synced_at]
    current['last_sync_summary'] = summary.merge(total_sent: total).stringify_keys
    # rubocop:disable Rails/SkipsModelValidations
    @hook.update_columns(settings: current, updated_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations
  end
end
