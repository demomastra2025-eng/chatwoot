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
end
