class Crm::FieldDefinitionValueCleanupService
  ENTITY_SCOPES = {
    'deal' => ->(account) { account.crm_deals },
    'task' => ->(account) { account.crm_tasks },
    'appointment' => ->(account) { account.scheduling_appointments }
  }.freeze

  def initialize(account:, entity_kind:, key:)
    @account = account
    @entity_kind = entity_kind.to_s
    @key = key.to_s
  end

  def perform
    return if key.blank?

    scope = scope_for_entity_kind
    return if scope.blank?

    quoted_key = scope.model.connection.quote(key)
    # This is a tenant-scoped cleanup for a deleted field definition; the intent is to
    # remove stale JSONB keys in bulk without instantiating each record.
    # rubocop:disable Rails/SkipsModelValidations
    scope.where('custom_attributes ? :key', key: key)
         .update_all("custom_attributes = COALESCE(custom_attributes, '{}'::jsonb) - #{quoted_key}")
    # rubocop:enable Rails/SkipsModelValidations
  end

  private

  attr_reader :account, :entity_kind, :key

  def scope_for_entity_kind
    ENTITY_SCOPES[entity_kind]&.call(account)
  end
end
