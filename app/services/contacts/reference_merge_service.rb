class Contacts::ReferenceMergeService
  class UnsafeMergeError < StandardError; end

  # [table, column] pairs: one table may reference contacts through several columns.
  REFERENCE_COLUMNS = [
    %w[assignment_client_ownerships contact_id],
    %w[assignment_quota_usages contact_id],
    %w[calls contact_id],
    %w[campaign_audience_recipients contact_id],
    %w[campaign_deliveries contact_id],
    %w[communication_threads contact_id],
    %w[confirmation_requests contact_id],
    %w[contact_channel_profiles contact_id],
    %w[contact_inboxes contact_id],
    %w[conversations contact_id],
    %w[crm_deal_contacts contact_id],
    %w[csat_survey_responses contact_id],
    %w[lead_submissions contact_id],
    %w[medelement_provider_commands contact_id],
    %w[meta_ad_referrals contact_id],
    %w[notes contact_id],
    %w[reminders target_contact_id],
    %w[scheduling_appointments contact_id],
    %w[scheduling_appointments patient_contact_id],
    %w[telephony_call_sessions contact_id],
    %w[telephony_contact_endpoints contact_id]
  ].freeze

  HANDLED_BY_CONTACT_MERGE = %w[
    communication_threads contact_channel_profiles contact_inboxes conversations crm_deal_contacts notes
  ].freeze

  def initialize(account:, base_contact:, mergee_contact:)
    @account = account
    @base_contact = base_contact
    @mergee_contact = mergee_contact
  end

  def perform
    ensure_patient_bindings_are_settled!
    ensure_provider_commands_do_not_collide!
    ensure_assignment_ownerships_do_not_collide!
    deduplicate_assignment_quota_usages!
    ensure_campaign_deliveries_do_not_collide!
    self.class.merge_reminder_references!(base_contact: base_contact, mergee_contact: mergee_contact)

    remaining_references.each { |table, column| bulk_reassign(table, column) }
  end

  def self.merge_reminder_references!(base_contact:, mergee_contact:)
    raise UnsafeMergeError, 'Reminder contacts must belong to the same account.' unless base_contact.account_id == mergee_contact.account_id

    # An open appointment touch re-derives its target from its appointment when saved, so the appointment chat and
    # patient contacts move first; otherwise the touch would point back at the mergee that is about to be deleted.
    merge_appointment_references!(base_contact: base_contact, mergee_contact: mergee_contact)
    Reminder.where(account_id: base_contact.account_id, target_contact_id: mergee_contact.id).find_each do |reminder|
      reminder.update!(target_contact: base_contact)
    end
  end

  def self.merge_appointment_references!(base_contact:, mergee_contact:)
    now = Time.current
    %w[contact_id patient_contact_id].each do |column|
      Scheduling::Appointment.where(account_id: base_contact.account_id).where(column => mergee_contact.id)
                             .update_all(column => base_contact.id, 'updated_at' => now) # rubocop:disable Rails/SkipsModelValidations
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
    REFERENCE_COLUMNS.reject { |table, _column| table.in?(HANDLED_BY_CONTACT_MERGE) || table == 'reminders' }
  end

  def ensure_patient_bindings_are_settled!
    Contacts::PatientIdentityMergeGuard.lock_patient_bindings!(base_contact, mergee_contact)
    return unless Contacts::PatientIdentityMergeGuard.patient_binding_write_in_flight?(base_contact, mergee_contact)

    raise UnsafeMergeError, 'A MedElement write for this patient card is in progress or awaits verification. Finish it before merging.'
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
