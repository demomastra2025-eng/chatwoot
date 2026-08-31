class Contacts::ReferenceMergeService
  class UnsafeMergeError < StandardError; end

  REFERENCE_COLUMNS = {
    'assignment_client_ownerships' => 'contact_id',
    'assignment_quota_usages' => 'contact_id',
    'calls' => 'contact_id',
    'campaign_deliveries' => 'contact_id',
    'communication_threads' => 'contact_id',
    'confirmation_requests' => 'contact_id',
    'contact_channel_profiles' => 'contact_id',
    'contact_inboxes' => 'contact_id',
    'conversations' => 'contact_id',
    'crm_deal_contacts' => 'contact_id',
    'csat_survey_responses' => 'contact_id',
    'lead_submissions' => 'contact_id',
    'medelement_provider_commands' => 'contact_id',
    'meta_ad_referrals' => 'contact_id',
    'notes' => 'contact_id',
    'reminders' => 'target_contact_id',
    'scheduling_appointments' => 'contact_id',
    'telephony_call_sessions' => 'contact_id',
    'telephony_contact_endpoints' => 'contact_id'
  }.freeze

  HANDLED_BY_CONTACT_MERGE = %w[
    communication_threads contact_channel_profiles contact_inboxes conversations crm_deal_contacts notes
  ].freeze

  def initialize(account:, base_contact:, mergee_contact:)
    @account = account
    @base_contact = base_contact
    @mergee_contact = mergee_contact
  end

  def perform
    ensure_provider_commands_do_not_collide!
    ensure_assignment_ownerships_do_not_collide!
    deduplicate_assignment_quota_usages!
    ensure_campaign_deliveries_do_not_collide!
    self.class.merge_reminder_references!(base_contact: base_contact, mergee_contact: mergee_contact)

    remaining_references.each { |table, column| bulk_reassign(table, column) }
  end

  def self.merge_reminder_references!(base_contact:, mergee_contact:)
    raise UnsafeMergeError, 'Reminder contacts must belong to the same account.' unless base_contact.account_id == mergee_contact.account_id

    Reminder.where(account_id: base_contact.account_id, target_contact_id: mergee_contact.id).find_each do |reminder|
      reminder.update!(target_contact: base_contact)
    end
  end

  def self.safe_to_delete?(contact)
    no_direct_references?(contact) && no_contact_messages?(contact)
  end

  def self.no_direct_references?(contact)
    REFERENCE_COLUMNS.none? do |table, column|
      next false unless connection.data_source_exists?(table)

      connection.select_value(
        "SELECT 1 FROM #{connection.quote_table_name(table)} " \
        "WHERE #{connection.quote_column_name(column)} = #{connection.quote(contact.id)} LIMIT 1"
      ).present?
    end
  end

  def self.no_contact_messages?(contact)
    !Message.exists?(sender_type: 'Contact', sender_id: contact.id)
  end

  def self.connection
    ActiveRecord::Base.connection
  end

  private

  attr_reader :account, :base_contact, :mergee_contact

  def remaining_references
    REFERENCE_COLUMNS.except(*HANDLED_BY_CONTACT_MERGE, 'reminders')
  end

  def ensure_provider_commands_do_not_collide!
    base_scope = unfinished_patient_identity_commands(base_contact)
    mergee_scope = unfinished_patient_identity_commands(mergee_contact)
    return if base_scope.none? || mergee_scope.none?

    raise UnsafeMergeError, 'Both contacts have unfinished MedElement patient commands. Finish or cancel one command before merging.'
  end

  def unfinished_patient_identity_commands(contact)
    return Integrations::Medelement::ProviderCommand.none unless table_exists?('medelement_provider_commands')

    Integrations::Medelement::ProviderCommand
      .where(account_id: account.id, contact_id: contact.id)
      .unfinished
      .patient_identity_writes
  end

  def ensure_assignment_ownerships_do_not_collide!
    return unless table_exists?('assignment_client_ownerships')

    base_exists = AssignmentClientOwnership.exists?(account_id: account.id, contact_id: base_contact.id)
    mergee_exists = AssignmentClientOwnership.exists?(account_id: account.id, contact_id: mergee_contact.id)
    return unless base_exists && mergee_exists

    raise UnsafeMergeError, 'Both contacts have assignment ownership. Resolve ownership before merging.'
  end

  def deduplicate_assignment_quota_usages!
    return unless table_exists?('assignment_quota_usages')

    base_keys = AssignmentQuotaUsage.where(account_id: account.id, contact_id: base_contact.id)
                                    .pluck(:user_id, :period_start)
    base_keys.each do |user_id, period_start|
      AssignmentQuotaUsage.where(
        account_id: account.id,
        contact_id: mergee_contact.id,
        user_id: user_id,
        period_start: period_start
      ).delete_all
    end
  end

  def ensure_campaign_deliveries_do_not_collide!
    return unless table_exists?('campaign_deliveries')

    base_run_ids = CampaignDelivery.where(account_id: account.id, contact_id: base_contact.id)
                                   .where.not(campaign_run_id: nil)
                                   .pluck(:campaign_run_id)
    collision_exists = CampaignDelivery.exists?(
      account_id: account.id,
      contact_id: mergee_contact.id,
      campaign_run_id: base_run_ids
    )
    return unless collision_exists

    raise UnsafeMergeError, 'Both contacts have deliveries in the same campaign run. Preserve the delivery history before merging.'
  end

  def bulk_reassign(table, column)
    return unless table_exists?(table)

    assignments = { column => base_contact.id }
    assignments['updated_at'] = Time.current if connection.column_exists?(table, :updated_at)
    quoted_assignments = assignments.map do |attribute, value|
      "#{connection.quote_column_name(attribute)} = #{connection.quote(value)}"
    end.join(', ')
    connection.update(<<~SQL.squish)
      UPDATE #{connection.quote_table_name(table)}
      SET #{quoted_assignments}
      WHERE #{connection.quote_column_name(column)} = #{connection.quote(mergee_contact.id)}
    SQL
  end

  def table_exists?(table)
    connection.data_source_exists?(table)
  end

  def connection
    self.class.connection
  end
end
