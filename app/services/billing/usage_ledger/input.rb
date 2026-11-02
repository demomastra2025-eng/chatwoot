# frozen_string_literal: true

class Billing::UsageLedger::Input
  delegate(*Billing::UsageLedger::Arguments::KEYS, to: :@arguments)
  attr_reader :events, :target, :merge_projections, :periods, :workspaces, :subscriptions, :kind, :subject_id

  def initialize(**values)
    @arguments = Billing::UsageLedger::Arguments.new(**values)
  end

  def load!
    raise Billing::UsageLedger::Refused, :account_missing unless Account.exists?(account_id)

    load_events!
    load_projections!
    load_terms!
    self
  end

  def with_locks
    Account.transaction(requires_new: true) do
      lock_clinical_scope!
      Account.lock('FOR NO KEY UPDATE').find_by(id: account_id) || raise(Billing::UsageLedger::Refused, :account_missing)
      load!
      lock_evidence!
      lock_projections!
      @periods = Billing::UsagePeriod.where(id: periods.keys).order(:id).lock.index_by(&:id)
      yield
    end
  end

  private

  def lock_evidence!
    lock_contracts!
    Accounts::AiUsageEvent.where(id: event_ids, account_id: account_id).order(:id).lock.load
    load_events!
  end

  def lock_contracts!
    payer_ids = (periods.values.map(&:billing_account_id) + subscriptions.values.map(&:billing_account_id)).uniq.sort
    BillingAccount.where(id: payer_ids).order(:id).lock('FOR NO KEY UPDATE').load
    # Mutable cycle/status is read again only after payer, before any later lock class.
    @subscriptions = subscription_scope(payer_ids).order(:id).lock.index_by(&:id)
    @workspaces = BillingAccountWorkspace.where(id: workspaces.keys).order(:id).lock.index_by(&:id)
  end

  def lock_projections!
    ids = ([target&.id] + merge_projections.map(&:id)).compact
    locked = Billing::UsageProjection.where(id: ids).order(:id).lock.index_by(&:id)
    @target = locked.fetch(target.id) if target
    @merge_projections = merge_projections.map { |source| locked.fetch(source.id) }
  end

  def load_events!
    @events = Accounts::AiUsageEvent.where(account_id: account_id, id: event_ids).order(:occurred_at, :id).to_a
    raise Billing::UsageLedger::Refused, :source_missing unless events.size == event_ids.size

    if ai_events?
      @kind = 'contact'
      @subject_id = contact_id
      validate_contact_history!
    elsif call_event?
      @kind = 'call'
      @subject_id = events.first.id
    else
      raise Billing::UsageLedger::Refused, :unsupported_source
    end
  end

  def ai_events?
    events.all? { |event| event.bucket == Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY && event.quantity == 1 }
  end

  def call_event?
    events.one? && contact_id.nil? && events.first.bucket == Accounts::MonthlyAiUsageService::CALL_SECONDS_MONTHLY_KEY &&
      events.first.quantity.positive?
  end

  def validate_contact_history!
    raise Billing::UsageLedger::Refused, :clinical_source_missing unless Contact.exists?(id: contact_id, account_id: account_id)
    raise Billing::UsageLedger::Refused, :source_scope unless events.all? { |event| event.contact_id == contact_id }

    scope = Accounts::AiUsageEvent.where(account_id: account_id, contact_id: contact_id,
                                         bucket: Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY)
    raise Billing::UsageLedger::Refused, :legacy_baseline_missing if scope.exists?(quantity: 0) || legacy_history?
    raise Billing::UsageLedger::Refused, :incomplete_source unless scope.order(:id).pluck(:id) == event_ids.sort
  end

  def legacy_history?
    state = Accounts::AiDialogState.find_by(account_id: account_id, contact_id: contact_id)&.state.to_h
    Array(state['legacy_seeds']).any? || Conversation.where(account_id: account_id, contact_id: contact_id)
                                                     .exists?(['jsonb_exists(additional_attributes, ?)',
                                                               Accounts::MonthlyAiUsageService::CONVERSATION_WINDOW_KEY])
  end

  def load_projections!
    @target = Billing::UsageProjection.find_by(account_id: account_id, kind: kind, subject_id: subject_id)
    @merge_projections = Billing::UsageProjection.where(account_id: account_id, id: merge_from.keys).order(:id).to_a
    validate_merge!
    require_baseline!
    ([@target] + @merge_projections).compact.each do |projection|
      raise Billing::UsageLedger::Refused, :projection_corrupt unless projection.valid?
    end
  end

  def validate_merge!
    raise Billing::UsageLedger::Refused, :merge_source_missing unless merge_projections.size == merge_from.size

    valid = merge_projections.all? { |source| [kind, source.kind] == %w[contact contact] && source.subject_id != contact_id }
    raise Billing::UsageLedger::Refused, :invalid_merge unless valid
  end

  def require_baseline!
    return if target || merge_projections.any? || baseline == :empty

    raise Billing::UsageLedger::Refused, :legacy_baseline_missing
  end

  def load_terms!
    ids = provenance.values.pluck(:period_id) | previous_period_ids
    @periods = Billing::UsagePeriod.where(id: ids).index_by(&:id)
    raise Billing::UsageLedger::Refused, :historical_terms_missing unless periods.size == ids.size

    @workspaces = BillingAccountWorkspace.where(id: provenance.values.pluck(:workspace_id).uniq).index_by(&:id)
    @subscriptions = subscription_scope(periods.values.map(&:billing_account_id)).index_by(&:id)
  end

  def subscription_scope(payer_ids)
    BillingSubscription.where(billing_account_id: payer_ids).or(BillingSubscription.where(id: provenance.values.pluck(:subscription_id).uniq))
  end

  def previous_period_ids
    ([target] + merge_projections).compact.flat_map { |projection| projection.allocations.keys.map(&:to_i) }.uniq
  end

  def lock_clinical_scope!
    return unless contact_id

    Contacts::PhoneIdentityLock.acquire!(account_id: account_id)
    source_ids = Billing::UsageProjection.where(account_id: account_id, kind: 'contact', id: merge_from.keys).pluck(:subject_id)
    Contact.where(account_id: account_id, id: [contact_id, *source_ids].uniq).order(:id).lock.load
  end
end
