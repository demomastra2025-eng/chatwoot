class Integrations::Medelement::SyncConflictFilter
  def initialize(hook:, filters: {})
    @hook = hook
    @filters = filters.to_h.symbolize_keys
  end

  def apply
    scope = status_scope
    scope = scope.where(conflict_type: filters[:conflict_type]) if filters[:conflict_type].present?
    scope = apply_date_range(scope)
    apply_contact(scope)
  end

  private

  attr_reader :hook, :filters

  def status_scope
    scope = Integrations::Medelement::SyncConflict.where(account_id: hook.account_id, hook_id: hook.id)
    return scope.where(status: filters[:status]) if filters[:status].in?(Integrations::Medelement::SyncConflict::STATUSES)

    scope.actionable
  end

  def apply_date_range(scope)
    scope = scope.where(last_seen_at: Time.zone.parse(filters[:from]).beginning_of_day..) if filters[:from].present?
    scope = scope.where(last_seen_at: ..Time.zone.parse(filters[:to]).end_of_day) if filters[:to].present?
    scope
  rescue ArgumentError
    scope
  end

  def apply_contact(scope)
    query = filters[:contact].to_s.strip
    return scope if query.blank?

    contact_ids = matching_contact_ids(query)
    return scope.none if contact_ids.empty?

    scope.where("details ->> 'contact_id' IN (:ids) OR details ->> 'conflicting_contact_id' IN (:ids)", ids: contact_ids)
  end

  def matching_contact_ids(query)
    hook.account.contacts.where(
      'name ILIKE :query OR email ILIKE :query OR phone_number ILIKE :query OR identifier ILIKE :query',
      query: "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
    ).limit(500).pluck(:id).map(&:to_s)
  end
end
