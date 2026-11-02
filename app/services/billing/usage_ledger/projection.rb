# frozen_string_literal: true

require 'digest'
require 'json'

class Billing::UsageLedger::Projection
  UNITS = %w[dialogs seconds].freeze
  def initialize(input)
    @input = input
  end

  def build
    raise Billing::UsageLedger::Refused, :projection_retired if @input.target&.retired?

    data = projected_data
    return { noop: true, deltas: {} } if replay?(data[:fingerprint])

    validate_versions!
    data.merge(deltas: signed_deltas(data[:allocations]), noop: false)
  end

  private

  def projected_data
    @sources = @input.events.sort_by { |event| [event.occurred_at, event.id] }.to_h { |event| [event.id.to_s, verified_source(event)] }
    preserve_sources!
    allocations, windows = allocate
    fingerprint = Digest::SHA256.hexdigest(JSON.generate(canonical([@sources, allocations, windows])))
    { sources: @sources, allocations: allocations, window_sources: windows, fingerprint: fingerprint }
  end

  # PostgreSQL JSONB key order must not change the identity of an exact replay.
  def canonical(value)
    case value
    when Hash then value.sort.map { |key, member| [key, canonical(member)] }
    when Array then value.map { |member| canonical(member) }
    else value
    end
  end

  def replay?(fingerprint)
    @input.target&.fingerprint == fingerprint && @input.merge_projections.all? { |source| source.retired_into_id == @input.target.id }
  end

  def verified_source(event)
    proof = @input.provenance.fetch(event.id)
    workspace = @input.workspaces[proof[:workspace_id]]
    period = @input.periods.fetch(proof[:period_id])
    subscription = @input.subscriptions[proof[:subscription_id]]
    raise Billing::UsageLedger::Refused, :provenance_missing unless workspace_valid?(workspace, event, period)

    validate_terms!(event, period, subscription)
    core = source_tuple(event, workspace, period, subscription)
    previous = previous_source(event.id)
    return confirmed_source!(previous, core, period, event) if previous

    raise Billing::UsageLedger::Refused, :terms_changed if changed_terms?(period, event)

    Billing::UsageLedger::SubscriptionEvidence.capture(event: event, source: core, subscription: subscription, payer_id: period.billing_account_id)
  end

  def source_tuple(event, workspace, period, subscription)
    { 'at' => event.occurred_at.utc.iso8601(6), 'bucket' => event.bucket, 'quantity' => event.quantity,
      'workspace_id' => workspace.id, 'period_id' => period.id, 'subscription_id' => subscription.id }
  end

  def previous_source(event_id)
    ([@input.target] + @input.merge_projections).compact.filter_map { |projection| projection.sources[event_id.to_s] }.first
  end

  def confirmed_source!(previous, core, period, event)
    valid = previous.slice(*Billing::UsageLedger::SubscriptionEvidence::CORE_KEYS) == core &&
            Billing::UsageLedger::SubscriptionEvidence.valid?(previous, event_id: event.id, account_id: @input.account_id) &&
            previous.dig('subscription_evidence', 'billing_account_id') == period.billing_account_id
    raise Billing::UsageLedger::Refused, :provenance_changed unless valid

    previous.deep_dup
  end

  def workspace_valid?(workspace, event, period)
    workspace&.ready? && workspace.account_id == @input.account_id && workspace.billing_account_id == period.billing_account_id &&
      workspace.starts_at <= event.occurred_at && (workspace.detached_at.nil? || event.occurred_at < workspace.detached_at)
  end

  def validate_terms!(event, period, subscription)
    month = event.occurred_at.in_time_zone(Billing::ALMATY_TIMEZONE).to_date.beginning_of_month
    raise Billing::UsageLedger::Refused, :historical_terms_missing unless proved_period?(period, subscription, month)

    raise Billing::UsageLedger::Refused, :terms_changed unless matching_terms?(subscription, period)
  end

  def proved_period?(period, subscription, month)
    period.month == month && period.valid? && subscription&.ready?
  end

  def matching_terms?(subscription, period)
    subscription.billing_account_id == period.billing_account_id && subscription.plan_snapshot == period.plan_snapshot &&
      subscription.price_snapshot == period.price_snapshot
  end

  def changed_terms?(period, event)
    # A different snapshot is not permission to choose a renewal/proration policy.
    @input.subscriptions.values.any? do |candidate|
      candidate.ready? && candidate.billing_account_id == period.billing_account_id &&
        candidate.created_at.between?(period.starts_at, event.occurred_at) && !matching_terms?(candidate, period)
    end
  end

  def preserve_sources!
    ([@input.target] + @input.merge_projections).compact.each do |projection|
      projection.sources.each do |event_id, previous|
        raise Billing::UsageLedger::Refused, :source_missing unless @sources.key?(event_id)
        raise Billing::UsageLedger::Refused, :provenance_changed unless @sources[event_id] == previous
      end
    end
  end

  def allocate
    allocations = {}
    if @input.kind == 'call'
      source = @sources.values.first
      allocations[source['period_id'].to_s] = { 'dialogs' => 0, 'seconds' => source['quantity'] }
      return [allocations, []]
    end
    allocate_windows(allocations)
  end

  def allocate_windows(allocations)
    timeline = @input.events.sort_by { |event| [event.occurred_at, event.id] }.map { |event| [event.occurred_at, 1, false, event.id] }
    windows = Accounts::AiDialogTimeline.new(timeline).windows.map do |window|
      event_id = window.fetch('first_event_id')
      period_id = @sources.fetch(event_id.to_s).fetch('period_id')
      units = allocations[period_id.to_s] ||= { 'dialogs' => 0, 'seconds' => 0 }
      units['dialogs'] += 1
      [event_id, period_id]
    end
    [allocations, windows]
  end

  def validate_versions!
    raise Billing::UsageLedger::Refused, :stale_projection unless (@input.target&.version || 0) == @input.expected_version

    @input.merge_projections.each do |source|
      raise Billing::UsageLedger::Refused, :projection_retired if source.retired?
      raise Billing::UsageLedger::Refused, :stale_projection unless source.version == @input.merge_from.fetch(source.id)
    end
  end

  def signed_deltas(allocations)
    previous = previous_units
    (previous.keys | allocations.keys).each_with_object({}) do |period_id, deltas|
      current = allocations.fetch(period_id, { 'dialogs' => 0, 'seconds' => 0 })
      delta = UNITS.index_with { |unit| current[unit] - previous[period_id][unit] }
      deltas[period_id.to_i] = delta unless delta.values.all?(&:zero?)
    end
  end

  def previous_units
    previous = Hash.new { |hash, key| hash[key] = { 'dialogs' => 0, 'seconds' => 0 } }
    ([@input.target] + @input.merge_projections).compact.each do |projection|
      projection.allocations.each { |period_id, units| UNITS.each { |unit| previous[period_id][unit] += units[unit] } }
    end
    previous
  end
end
