class Crm::BaseWriteService
  private

  attr_reader :account, :actor, :params, :record

  def initialize(account:, params:, record:, actor: nil)
    @account = account
    @params = params.to_h.deep_symbolize_keys
    @record = record
    @actor = actor
  end

  def assert_lock_version!
    return unless record.persisted?
    raise ArgumentError, 'lock_version is required' unless params.key?(:lock_version)
    return if params[:lock_version].to_i == record.lock_version

    raise ActiveRecord::StaleObjectError.new(record, self.class.name.demodulize.underscore)
  end

  def ensure_unique_reference!(scope:, attribute:, value:, code:)
    return if value.blank?

    existing = scope.find_by(attribute => value)
    return if existing.blank? || existing.id == record.id

    raise ::Crm::Error.new(
      code: code,
      message: "#{attribute} must be unique within account",
      status: :conflict,
      details: { attribute => ['has already been taken'] }
    )
  end

  def filtered_previous_changes
    record.previous_changes.except('updated_at', 'created_at', 'lock_version')
  end

  def resolve_date(key, current:)
    return current unless params.key?(key)
    return nil if params[key].blank?

    value = params[key]
    value.is_a?(Date) ? value : Date.iso8601(value.to_s)
  rescue Date::Error
    raise ArgumentError, "#{key} must be YYYY-MM-DD"
  end

  def resolve_datetime(key, current:)
    return current unless params.key?(key)
    return nil if params[key].blank?

    Time.zone.parse(params[key].to_s) || raise(ArgumentError, "#{key} must be a valid datetime")
  end

  def resolve_integer(key, current:, allow_nil: false)
    return current unless params.key?(key)
    return nil if params[key].blank? && allow_nil
    return 0 if params[key].blank?

    Integer(params[key])
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{key} must be an integer"
  end

  def resolve_many_records(scope, ids)
    normalized_ids = Array(ids).filter_map(&:presence)
    return [] if normalized_ids.empty?

    records = scope.find(normalized_ids)
    records.index_by { |item| normalized_ids.index(item.id.to_s) || normalized_ids.index(item.id) }.values
  end

  def resolve_optional_record(key, scope, current:)
    return current unless params.key?(key)
    return nil if params[key].blank?

    scope.find(params[key])
  end

  def resolve_optional_text(key, current:)
    return current unless params.key?(key)

    params[key].to_s.strip.presence
  end

  def validation_error!(attribute, message)
    raise ::Crm::Error.new(
      code: 'VALIDATION_ERROR',
      message: "#{attribute} #{message}",
      status: :unprocessable_content,
      details: { attribute => [message] }
    )
  end

  def resolve_closing_reasons!(target_stage:, current_reasons:, require_input:)
    return [] if target_stage.outcome_open?
    return current_reasons unless params.key?(:closing_reasons) || require_input

    submitted_reasons = ::Crm::Stage.normalize_closing_reason_values(params[:closing_reasons])
    invalid_reasons = target_stage.invalid_closing_reasons(submitted_reasons)
    raise_invalid_closing_reasons!(target_stage, invalid_reasons) if invalid_reasons.present?

    canonical_reasons = target_stage.canonical_closing_reasons(submitted_reasons)
    canonical_reasons
  end

  def resolve_transition_reason!(target_stage:, require_input:)
    return if target_stage.terminal_outcome?
    return unless params.key?(:transition_reason) || (require_input && target_stage.transition_reason_required?)

    submitted_reason = ::Crm::Stage.normalize_closing_reason_values([params[:transition_reason]]).first
    invalid_reasons = target_stage.invalid_transition_reason(submitted_reason)
    raise_invalid_transition_reason!(target_stage, invalid_reasons) if invalid_reasons.present?

    canonical_reason = target_stage.canonical_transition_reason(submitted_reason)
    raise_missing_transition_reason!(target_stage) if target_stage.transition_reason_required? && canonical_reason.blank?

    canonical_reason
  end

  def dispatch_crm_deal_realtime_event!(event_name, deal, meta: {})
    Rails.configuration.dispatcher.dispatch(
      event_name,
      Time.zone.now,
      {
        account: account,
        deal: deal,
        meta: meta
      }
    )
  end

  def raise_invalid_closing_reasons!(target_stage, invalid_reasons)
    raise ::Crm::Error.new(
      code: 'DEAL_STAGE_INVALID_CLOSING_REASONS',
      message: "Closing reasons are not configured for #{target_stage.name}: #{invalid_reasons.join(', ')}.",
      status: :unprocessable_content,
      details: {
        stage_id: target_stage.id,
        outcome: target_stage.outcome,
        invalid_reasons: invalid_reasons,
        closing_reason_options: target_stage.closing_reason_options
      }
    )
  end

  def raise_missing_transition_reason!(target_stage)
    raise ::Crm::Error.new(
      code: 'DEAL_STAGE_REQUIRES_TRANSITION_REASON',
      message: "Select a transition reason before moving the deal to #{target_stage.name}.",
      status: :unprocessable_content,
      details: {
        stage_id: target_stage.id,
        outcome: target_stage.outcome,
        transition_reason_options: target_stage.transition_reason_options
      }
    )
  end

  def raise_invalid_transition_reason!(target_stage, invalid_reasons)
    raise ::Crm::Error.new(
      code: 'DEAL_STAGE_INVALID_TRANSITION_REASON',
      message: "Transition reason is not configured for #{target_stage.name}: #{invalid_reasons.join(', ')}.",
      status: :unprocessable_content,
      details: {
        stage_id: target_stage.id,
        outcome: target_stage.outcome,
        invalid_reasons: invalid_reasons,
        transition_reason_options: target_stage.transition_reason_options
      }
    )
  end
end
