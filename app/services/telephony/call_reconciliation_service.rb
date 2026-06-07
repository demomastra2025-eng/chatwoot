class Telephony::CallReconciliationService
  DEFAULT_PAGE_SIZE = 100
  DEFAULT_MAX_PAGES = 3
  DEFAULT_STALE_AFTER = 30.seconds
  DEFAULT_MISSING_AFTER = 5.minutes

  BRIDGE_STATUS_MAP = {
    'queued' => 'created',
    'initiated' => 'created',
    'api_originated' => 'created',
    'ringing' => 'ringing',
    'dialing' => 'connecting',
    'connecting' => 'connecting',
    'answered' => 'in_progress',
    'in_progress' => 'in_progress',
    'in-progress' => 'in_progress',
    'inprogress' => 'in_progress',
    'completed' => 'completed',
    'complete' => 'completed',
    'ended' => 'completed',
    'normal_clearing' => 'completed',
    'no_answer' => 'no_answer',
    'no-answer' => 'no_answer',
    'busy' => 'busy',
    'cancelled' => 'cancelled',
    'canceled' => 'cancelled',
    'rejected' => 'rejected',
    'declined' => 'rejected',
    'failed' => 'failed',
    'error' => 'failed'
  }.freeze

  STATUS_PROGRESS = {
    'created' => 0,
    'ringing' => 1,
    'connecting' => 2,
    'in_progress' => 3
  }.freeze

  def initialize(account: nil, bridge_client: nil, now: Time.current, page_size: nil, max_pages: nil, stale_after: nil)
    @account = account
    @bridge_client = bridge_client
    @now = now
    @page_size = positive_integer(page_size || ENV.fetch('TELEPHONY_RECONCILE_PAGE_SIZE', DEFAULT_PAGE_SIZE))
    @max_pages = positive_integer(max_pages || ENV.fetch('TELEPHONY_RECONCILE_MAX_PAGES', DEFAULT_MAX_PAGES))
    @stale_after = stale_after || ENV.fetch('TELEPHONY_RECONCILE_STALE_AFTER_SECONDS', DEFAULT_STALE_AFTER.to_i).to_i.seconds
    @missing_after = ENV.fetch('TELEPHONY_RECONCILE_MISSING_AFTER_SECONDS', DEFAULT_MISSING_AFTER.to_i).to_i.seconds
  end

  def perform
    result = { checked: 0, updated: 0, missing: 0, errors: 0 }

    grouped_active_sessions.each do |account, sessions|
      result[:checked] += sessions.size
      bridge_items = fetch_bridge_items(account, sessions)
      indexed_items = index_bridge_items(bridge_items)

      sessions.each do |session|
        bridge_item = bridge_item_for(session, indexed_items)
        unless bridge_item
          result[:missing] += 1
          result[:updated] += 1 if reconcile_missing_session(session)
          next
        end

        result[:updated] += 1 if reconcile_session(session, bridge_item)
      end
    rescue Telephony::Error => e
      result[:errors] += 1
      log_reconciliation_error(account, e)
    end

    result
  end

  private

  attr_reader :account, :bridge_client, :max_pages, :missing_after, :now, :page_size, :stale_after

  def grouped_active_sessions
    sessions = active_candidate_scope.includes(:account).to_a
    sessions.group_by(&:account)
  end

  def active_candidate_scope
    scope = Telephony::CallSession.active.where(provider: 'fonoster')
    scope = scope.where(account_id: account.id) if account.present?
    scope.where('COALESCE(last_event_at, started_at, updated_at, created_at) <= ?', now - stale_after)
  end

  def fetch_bridge_items(account, sessions)
    items = []
    page_token = nil
    base_query = { page_size: page_size }
    earliest_time = sessions.filter_map { |session| session.started_at || session.created_at }.min
    base_query[:after] = earliest_time.iso8601 if earliest_time.present?

    max_pages.times do
      query = base_query.dup
      query[:page_token] = page_token if page_token.present?
      response = client_for(account).get('/telephony/calls', query: query)
      items.concat(Array(response['items'] || response[:items]).map { |item| stringify_item(item) })
      page_token = response['nextPageToken'] || response[:nextPageToken] || response['next_page_token'] || response[:next_page_token]
      break if page_token.blank?
    end

    items
  end

  def client_for(account)
    bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def index_bridge_items(items)
    items.each_with_object({}) do |item, index|
      bridge_item_keys(item).each { |key| index[key] = item }
    end
  end

  def bridge_item_for(session, indexed_items)
    matching_key = [session.external_call_ref, session.provider_call_sid].compact_blank.map(&:to_s).detect { |key| indexed_items[key] }
    indexed_items[matching_key]
  end

  def bridge_item_keys(item)
    [item['ref'], item['callId'], item['call_id'], item['provider_call_sid']].compact_blank.map(&:to_s).uniq
  end

  def reconcile_session(session, item)
    target_status = next_status_for(session, item)
    attrs = base_reconciliation_attributes(session, item, target_status)
    status_to_apply = status_update_for(session, target_status)

    attrs.merge!(status_change_attributes(session, item, status_to_apply, target_status)) if status_to_apply.present?

    session.update!(attrs)
    sync_reconciled_session!(session, status_to_apply) if status_to_apply.present?
    true
  end

  def reconcile_missing_session(session)
    return false unless missing_terminal_candidate?(session)

    target_status = missing_terminal_status(session)
    ended_at = now
    session.update!(
      status: target_status,
      ended_at: ended_at,
      ended_by: 'bridge_reconciliation',
      end_reason: missing_end_reason(session, target_status),
      duration_seconds: missing_duration_seconds(session, ended_at),
      last_event_at: ended_at,
      metadata: missing_metadata(session, target_status),
      legs: append_missing_leg_snapshot(session, target_status)
    )
    sync_reconciled_session!(session, target_status)
    true
  end

  def sync_reconciled_session!(session, status)
    return unless Telephony::CallSession::TERMINAL_STATUSES.include?(status)

    Telephony::EventsIngestionService.new(payload: reconciliation_event_payload(session, status)).perform
  rescue StandardError => e
    Rails.logger.warn(
      event: 'telephony_call_reconciliation_side_effect_failed',
      account_id: session.account_id,
      call_ref: session.external_call_ref,
      status: status,
      error_class: e.class.name,
      error_message: e.message
    )
  end

  def reconciliation_event_payload(session, status)
    {
      account_id: session.account_id,
      inbox_id: session.inbox_id,
      call_ref: session.external_call_ref,
      event_key: reconciliation_event_key(session, status),
      event: reconciliation_event_type(status),
      status: status,
      direction: session.direction,
      from_number: session.from_number,
      to_number: session.to_number,
      started_at: session.started_at&.iso8601,
      answered_at: session.answered_at&.iso8601,
      ended_at: session.ended_at&.iso8601,
      ended_by: session.ended_by,
      end_reason: session.end_reason,
      duration: session.duration_seconds,
      metadata: {
        source: 'bridge_reconciliation'
      }
    }.compact
  end

  def reconciliation_event_key(session, status)
    ended_key = (session.ended_at || now).to_i
    "bridge_reconciliation:#{session.account_id}:#{session.external_call_ref}:#{status}:#{ended_key}"
  end

  def reconciliation_event_type(status)
    return 'session_completed' if status == 'completed'

    status
  end

  def missing_terminal_candidate?(session)
    return false if session.terminal?
    return false unless missing_reconcilable_route?(session)

    reference_time = session.last_event_at || session.started_at || session.updated_at || session.created_at
    reference_time.present? && reference_time <= now - missing_after
  end

  def missing_reconcilable_route?(session)
    %w[operator reject].include?(route_action(session)) || session.direction == 'outbound'
  end

  def missing_terminal_status(session)
    return 'rejected' if route_action(session) == 'reject'
    return 'no_answer' if route_action(session) == 'operator'
    return 'no_answer' if session.direction == 'outbound'

    'missed'
  end

  def base_reconciliation_attributes(session, item, target_status)
    attrs = {
      metadata: merged_metadata(session, item, target_status)
    }

    provider_call_id = item['callId'] || item['call_id'] || item['provider_call_sid']
    attrs[:provider_call_sid] = provider_call_id if provider_call_id.present? && session.provider_call_sid.blank?

    started_at = parse_time(item['startedAt'] || item['started_at'])
    attrs[:started_at] = started_at if started_at.present? && session.started_at.blank?

    attrs
  end

  def status_change_attributes(session, item, status_to_apply, target_status)
    attrs = {
      status: status_to_apply,
      last_event_at: now
    }

    if Telephony::CallSession::TERMINAL_STATUSES.include?(status_to_apply)
      ended_at = parse_time(item['endedAt'] || item['ended_at']) || now
      attrs[:ended_at] = ended_at
      attrs[:duration_seconds] = resolved_duration_seconds(session, item, ended_at)
      attrs[:end_reason] = target_status.blank? ? nil : end_reason_for(item, status_to_apply, target_status)
      attrs[:last_event_at] = ended_at
    elsif status_to_apply == 'in_progress'
      attrs[:answered_at] = parse_time(item['answeredAt'] || item['answered_at']) || now if session.answered_at.blank?
      attrs[:answered_by] = 'bridge_reconciliation' if session.answered_by.blank?
    end

    attrs[:legs] = append_leg_snapshot(session, item, status_to_apply)
    attrs
  end

  def next_status_for(session, item)
    canonical_bridge_status(item) || terminal_fallback_status(session, item)
  end

  def canonical_bridge_status(item)
    raw_status = item['status'].to_s.strip
    return if raw_status.blank?

    normalized_status = raw_status.downcase.tr(' ', '_')
    BRIDGE_STATUS_MAP[normalized_status] || Telephony::CallSession.normalize_status(normalized_status)
  end

  def terminal_fallback_status(session, item)
    return if parse_time(item['endedAt'] || item['ended_at']).blank?

    return 'completed' if raw_duration_seconds(item).to_i.positive?
    return 'no_answer' if session.direction == 'outbound'

    'missed'
  end

  def status_update_for(session, target_status)
    return if target_status.blank?

    current_status = session.canonical_status
    return target_status if Telephony::CallSession::TERMINAL_STATUSES.include?(target_status)
    return if Telephony::CallSession::TERMINAL_STATUSES.include?(current_status)
    return if target_status == current_status

    target_rank = STATUS_PROGRESS[target_status]
    current_rank = STATUS_PROGRESS[current_status]
    return if target_rank.blank? || current_rank.blank?
    return if target_rank < current_rank

    target_status
  end

  def resolved_duration_seconds(session, item, ended_at)
    raw_duration = raw_duration_seconds(item)
    return raw_duration.to_i if raw_duration.present?

    started_at = parse_time(item['startedAt'] || item['started_at']) || session.started_at
    return unless started_at.present? && ended_at.present?

    [ended_at.to_i - started_at.to_i, 0].max
  end

  def raw_duration_seconds(item)
    item['duration'] || item['durationSec'] || item['duration_sec'] || item['duration_seconds']
  end

  def missing_end_reason(session, target_status)
    return 'bridge_missing_operator_no_answer' if target_status == 'no_answer' && route_action(session) == 'operator'
    return 'bridge_missing_rejected_route' if target_status == 'rejected'

    'bridge_missing_call'
  end

  def missing_duration_seconds(session, ended_at)
    return session.duration_seconds if session.duration_seconds.present?

    started_at = session.answered_at || session.started_at || session.created_at
    return unless started_at.present? && ended_at.present?

    [ended_at.to_i - started_at.to_i, 0].max
  end

  def missing_metadata(session, target_status)
    metadata = session.metadata.to_h.deep_dup
    metadata['bridge_reconciliation'] = {
      'target_status' => target_status,
      'missing_from_bridge' => true,
      'route_action' => route_action(session),
      'route_reason' => route_reason(session),
      'reconciled_at' => now.iso8601
    }.compact
    metadata
  end

  def append_missing_leg_snapshot(session, status)
    legs = Array(session.legs).map { |leg| leg.respond_to?(:to_h) ? leg.to_h : leg }
    legs << {
      'source' => 'bridge_reconciliation',
      'status' => status,
      'missing_from_bridge' => true,
      'route_action' => route_action(session),
      'occurred_at' => now.iso8601
    }.compact
    legs.last(20)
  end

  def route_action(session)
    route_metadata_value(session, 'route_action')
  end

  def route_reason(session)
    route_metadata_value(session, 'route_reason')
  end

  def route_metadata_value(session, key)
    metadata = session.metadata.to_h.deep_stringify_keys
    metadata[key].presence ||
      metadata.dig('metadata', key).presence ||
      metadata.dig('last_payload', 'metadata', key).presence
  end

  def merged_metadata(session, item, target_status)
    metadata = session.metadata.to_h.deep_dup
    terminal_fallback = canonical_bridge_status(item).blank? ? terminal_fallback_status(session, item) : nil
    reconciliation = {
      'provider_status' => item['status'],
      'provider_direction' => item['direction'],
      'provider_type' => item['type'],
      'raw_ref' => item['ref'],
      'raw_call_id' => item['callId'] || item['call_id'],
      'target_status' => target_status,
      'terminal_fallback' => terminal_fallback,
      'reconciled_at' => now.iso8601
    }.compact

    metadata['bridge_reconciliation'] = reconciliation
    metadata
  end

  def append_leg_snapshot(session, item, status)
    legs = Array(session.legs).map { |leg| leg.respond_to?(:to_h) ? leg.to_h : leg }
    legs << {
      'source' => 'bridge_reconciliation',
      'status' => status,
      'provider_status' => item['status'],
      'provider_direction' => item['direction'],
      'provider_type' => item['type'],
      'ref' => item['ref'],
      'call_id' => item['callId'] || item['call_id'],
      'occurred_at' => now.iso8601
    }.compact
    legs.last(20)
  end

  def end_reason_for(item, status_to_apply, target_status)
    return 'bridge_unknown_terminal' if canonical_bridge_status(item).blank? && target_status == status_to_apply

    status_to_apply
  end

  def stringify_item(item)
    return {} unless item.respond_to?(:to_h)

    item.to_h.deep_stringify_keys
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def positive_integer(value)
    parsed_value = value.to_i
    parsed_value.positive? ? parsed_value : 1
  end

  def log_reconciliation_error(account, error)
    Rails.logger.warn(
      event: 'telephony_call_reconciliation_failed',
      account_id: account&.id,
      error_class: error.class.name,
      error_message: error.message
    )
  end
end
