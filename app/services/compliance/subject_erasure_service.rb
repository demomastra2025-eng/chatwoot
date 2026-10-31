# frozen_string_literal: true

require 'securerandom'

# Executes irreversible RK Personal Data Law Art. 15/18 cascading subject erasure across
# PostgreSQL, ps.kz S3 call recordings & attachments, Redis PII/IIN vaults, and MedElement bindings,
# records PII-free HMAC tombstones in PostgreSQL + ps.kz S3 BEFORE destructive steps,
# and issues a Destruction Certificate («Акт об уничтожении персональных данных»).
# rubocop:disable Metrics/ClassLength
class Compliance::SubjectErasureService
  ALMATY_TIME_ZONE = 'Asia/Almaty'
  ANONYMIZED_NAME = '[УДАЛЕНО]'
  APPOINTMENT_PII_CUSTOM_KEYS = %w[
    iin medelement_iin medelement_patient_code medelement_merged_patient_codes
    medelement_owned_patient_identity client_phone phone phone_number email
    patient_name client_name birth_date
  ].freeze

  def initialize(account:, contact:, reason: 'subject_request', actor_id: nil)
    @account = account
    @contact = contact
    @reason = reason.to_s.presence || 'subject_request'
    @actor_id = actor_id
  end

  def perform!
    validate_target!

    erased_at = Time.current
    certificate_uid = generate_certificate_uid(erased_at)
    conv_ids = Conversation.where(account_id: account.id, contact_id: contact.id).pluck(:id)
    entries = collect_all_subject_identifiers(conv_ids)

    # Record tombstones FIRST so partial storage/DB errors never leave an untombstoned subject.
    persist_tombstones!(certificate_uid, entries, erased_at, { status: 'in_progress' })
    counts = execute_cascade!(conv_ids, erased_at, certificate_uid)
    remote_key = persist_tombstones!(certificate_uid, entries, erased_at, counts)

    build_certificate(
      certificate_uid: certificate_uid,
      erased_at: erased_at,
      entries: entries,
      counts: counts,
      remote_key: remote_key
    )
  end

  private

  attr_reader :account, :contact, :reason, :actor_id

  def persist_tombstones!(certificate_uid, entries, erased_at, counts)
    remote_key = sync_remote_ledger(certificate_uid, entries, erased_at, counts)
    Compliance::DeletedSubjectTombstone.upsert_entries!(
      account_id: account.id,
      entries: entries,
      certificate_uid: certificate_uid,
      reason: reason,
      erased_at: erased_at,
      remote_synced_at: remote_key.present? ? Time.current : nil,
      metadata: counts
    )
    remote_key
  end

  def validate_target!
    raise ArgumentError, 'account is required' if account.blank?
    raise ArgumentError, 'contact is required' if contact.blank?
    return if contact.account_id == account.id

    raise ArgumentError, 'contact does not belong to account'
  end

  def generate_certificate_uid(erased_at)
    "ACT-PDN-#{erased_at.in_time_zone(ALMATY_TIME_ZONE).strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4).upcase}"
  end

  def collect_all_subject_identifiers(conv_ids)
    entries = Compliance::TombstoneHasher.extract_contact_identifiers(contact)
    appointment_scope(conv_ids).pluck(:client_phone, :client_identifier, :custom_attributes).each do |c_phone, c_ident, c_attrs|
      attrs = c_attrs.to_h
      extra = Compliance::TombstoneHasher.build_entries(
        account.id,
        phone: [c_phone, attrs['client_phone'], attrs['phone']],
        iin: [c_ident, attrs['iin'], attrs['medelement_iin']],
        medelement_patient_code: [attrs['medelement_patient_code']]
      )
      entries.concat(extra)
    end
    entries.uniq { |entry| [entry[:kind], entry[:hmac]] }
  end

  def execute_cascade!(conv_ids, erased_at, certificate_uid)
    counts = initial_counts
    call_session_ids = purge_call_sessions!(conv_ids, counts, erased_at, certificate_uid)
    purge_conversation_attachment_blobs!(conv_ids, counts)

    ApplicationRecord.transaction do
      anonymize_appointments!(conv_ids, counts, erased_at, certificate_uid)
      cleanup_conversation_fk_dependents!(conv_ids)
      destroy_conversations!(conv_ids, counts)
      delete_dependent_records!
      contact.reload.destroy!
      counts[:contact_deleted] = true
    end

    purge_redis_vaults!(conv_ids, call_session_ids)
    counts
  end

  def initial_counts
    {
      conversations_deleted: 0,
      messages_deleted: 0,
      attachments_purged: 0,
      call_sessions_scrubbed: 0,
      call_recordings_purged: 0,
      appointments_anonymized: 0,
      contact_deleted: false
    }
  end

  # rubocop:disable Rails/SkipsModelValidations
  def purge_call_sessions!(conv_ids, counts, erased_at, certificate_uid)
    return [] unless defined?(Telephony::CallSession)

    session_ids = []
    call_sessions_scope(conv_ids).find_each do |session|
      session_ids << session.id
      counts[:call_recordings_purged] += purge_session_recordings!(session)
      session.update_columns(scrubbed_call_session_attributes(erased_at, certificate_uid))
      counts[:call_sessions_scrubbed] += 1
    end
    session_ids
  end
  # rubocop:enable Rails/SkipsModelValidations

  def call_sessions_scope(conv_ids)
    base = Telephony::CallSession.where(account_id: account.id)
    return base.where(contact_id: contact.id) if conv_ids.empty?

    base.where(contact_id: contact.id).or(base.where(conversation_id: conv_ids))
  end

  def scrubbed_call_session_attributes(erased_at, certificate_uid)
    {
      contact_id: nil,
      conversation_id: nil,
      recording_ref: nil,
      from_number: nullable_column?(Telephony::CallSession, 'from_number') ? nil : '[REDACTED]',
      to_number: nullable_column?(Telephony::CallSession, 'to_number') ? nil : '[REDACTED]',
      metadata: { 'compliance_erased_at' => erased_at.utc.iso8601, 'certificate_uid' => certificate_uid },
      updated_at: Time.current
    }
  end

  def purge_session_recordings!(session)
    meta = session.metadata.to_h
    remote_keys = [session.try(:recording_storage_key), meta.dig('recording', 'storage_key'), meta.dig('trash', 'storage_key')]
    local_refs = [session.recording_ref, meta.dig('trash', 'original_reference'), meta.dig('trash', 'trash_path')]

    purge_remote_recording_keys!(remote_keys) + purge_local_recording_refs!(local_refs)
  end

  def purge_remote_recording_keys!(keys)
    keys.compact_blank.uniq.count { |key| Storage::VoiceRecordingRemoteStorage.delete_key(key) }
  end

  def purge_local_recording_refs!(refs)
    refs.compact_blank.uniq.count { |ref| delete_local_recording_ref!(ref) }
  end

  def delete_local_recording_ref!(ref)
    local = resolve_local_recording_path(ref)
    return false unless local && File.file?(local)

    File.delete(local)
    true
  rescue StandardError
    false
  end

  def resolve_local_recording_path(ref)
    resolved = Storage::RecordingPaths.resolve(ref, account_id: account.id) ||
               Storage::RecordingPaths.resolve_trash(ref, account_id: account.id)
    resolved&.to_s
  rescue StandardError
    nil
  end

  def purge_conversation_attachment_blobs!(conv_ids, counts)
    return if conv_ids.empty?

    msg_ids = Message.where(account_id: account.id, conversation_id: conv_ids).select(:id)
    Attachment.where(account_id: account.id, message_id: msg_ids).find_each do |att|
      purge_single_attachment!(att, counts)
    end
  end

  def destroy_conversations!(conv_ids, counts)
    return if conv_ids.empty?

    delete_conversation_messages_synchronously!(conv_ids, counts)
    Conversation.where(account_id: account.id, id: conv_ids).find_each do |conv|
      conv.destroy!
      counts[:conversations_deleted] += 1
    end
  end

  def delete_conversation_messages_synchronously!(conv_ids, counts)
    msg_ids = Message.where(account_id: account.id, conversation_id: conv_ids).pluck(:id)
    return if msg_ids.empty?

    unlink_or_delete_by_column!(MetaAdReferral, :message_id, msg_ids) if defined?(MetaAdReferral)
    Attachment.where(account_id: account.id, message_id: msg_ids).delete_all
    Notification.where(primary_actor_type: 'Message', primary_actor_id: msg_ids).delete_all if defined?(Notification)
    counts[:messages_deleted] += Message.where(account_id: account.id, id: msg_ids).delete_all
  end

  def purge_single_attachment!(att, counts)
    return unless att.respond_to?(:file) && att.file.attached?

    att.file.purge
    counts[:attachments_purged] += 1
  rescue StandardError => e
    Rails.logger.warn("[Compliance::SubjectErasureService] attachment purge warning id=#{att.id}: #{e.class}")
  end

  # rubocop:disable Rails/SkipsModelValidations
  def cleanup_conversation_fk_dependents!(conv_ids)
    return if conv_ids.empty?

    delete_direct_conversation_rows!(conv_ids)
    delete_conversation_reminders_and_notifications!(conv_ids)
    unlink_conversation_optional_references!(conv_ids)
  end

  def delete_direct_conversation_rows!(conv_ids)
    %w[
      AssignmentDecisionLog AssignmentQuotaUsage CommunicationThreadConversation
      ConfirmationRequest ConversationStatusTransition WhatsappFlowSession
      ConversationParticipant CsatSurveyResponse Mention ReportingEvent
    ].each do |class_name|
      klass = class_name.safe_constantize
      next unless klass&.column_names&.include?('conversation_id')

      klass.where(conversation_id: conv_ids).delete_all
    end
  end

  def delete_conversation_reminders_and_notifications!(conv_ids)
    if defined?(Reminder)
      scope = Reminder.where(conversation_id: conv_ids)
      scope = scope.or(Reminder.where(target_conversation_id: conv_ids)) if Reminder.column_names.include?('target_conversation_id')
      scope.delete_all
    end
    return unless defined?(Notification)

    Notification.where(primary_actor_type: 'Conversation', primary_actor_id: conv_ids).delete_all
  end

  def unlink_conversation_optional_references!(conv_ids)
    %w[Crm::Deal Crm::Task].each do |class_name|
      klass = class_name.safe_constantize
      next unless klass&.column_names&.include?('originating_conversation_id')

      klass.where(originating_conversation_id: conv_ids).update_all(originating_conversation_id: nil)
    end
    unlink_or_delete_by_column!(LeadSubmission, :conversation_id, conv_ids) if defined?(LeadSubmission)
    unlink_or_delete_by_column!(MetaAdReferral, :conversation_id, conv_ids) if defined?(MetaAdReferral)
  end

  def anonymize_appointments!(conv_ids, counts, erased_at, certificate_uid)
    return unless defined?(Scheduling::Appointment)

    appointment_scope(conv_ids).find_each do |appointment|
      appointment.update_columns(anonymized_appointment_attributes(appointment, erased_at, certificate_uid))
      counts[:appointments_anonymized] += 1
    end
  end
  # rubocop:enable Rails/SkipsModelValidations

  def anonymized_appointment_attributes(appointment, erased_at, certificate_uid)
    clean_custom = appointment.custom_attributes.to_h.except(*APPOINTMENT_PII_CUSTOM_KEYS).merge(
      'compliance_erased_at' => erased_at.utc.iso8601,
      'compliance_certificate_uid' => certificate_uid
    )
    attrs = base_anonymized_appointment_columns(clean_custom)
    attrs[:client_comment] = nil if appointment.has_attribute?(:client_comment)
    attrs
  end

  def base_anonymized_appointment_columns(clean_custom)
    {
      contact_id: nil, patient_contact_id: nil, conversation_id: nil,
      client_name: ANONYMIZED_NAME, client_first_name: nil, client_last_name: nil,
      client_middle_name: nil, client_phone: nil, client_identifier: nil,
      client_birth_date: nil, client_gender: nil, custom_attributes: clean_custom,
      updated_at: Time.current
    }
  end

  # rubocop:disable Rails/SkipsModelValidations
  def delete_dependent_records!
    delete_account_scoped_dependents!
    delete_contact_scoped_dependents!
    unlink_nullable_contact_references!
  end

  def delete_account_scoped_dependents!
    Telephony::ContactEndpoint.where(account_id: account.id, contact_id: contact.id).delete_all if defined?(Telephony::ContactEndpoint)
    Call.where(account_id: account.id, contact_id: contact.id).delete_all if defined?(Call)
    Reminder.where(account_id: account.id, target_contact_id: contact.id).delete_all if defined?(Reminder)
    ConfirmationRequest.where(account_id: account.id, contact_id: contact.id).delete_all if defined?(ConfirmationRequest)
  end

  def delete_contact_scoped_dependents!
    %w[
      Crm::DealContact Crm::Activity CampaignDelivery CsatSurveyResponse
      Note ContactPhone ContactChannelProfile WhatsappFlowSession
    ].each do |class_name|
      klass = class_name.safe_constantize
      next unless klass&.column_names&.include?('contact_id')

      klass.where(contact_id: contact.id).delete_all
    end
    CommunicationThread.where(contact_id: contact.id).destroy_all if defined?(CommunicationThread)
    ContactInbox.where(contact_id: contact.id).destroy_all
  end

  def unlink_nullable_contact_references!
    %w[Crm::Deal Crm::Task].each do |class_name|
      klass = class_name.safe_constantize
      unlink_or_delete_by_column!(klass, :contact_id, contact.id) if klass&.column_names&.include?('contact_id')
    end
    unlink_lead_submissions_contact! if defined?(LeadSubmission)
    unlink_or_delete_by_column!(MetaAdReferral, :contact_id, contact.id) if defined?(MetaAdReferral)
    Message.where(account_id: account.id, sender_type: 'Contact', sender_id: contact.id).update_all(sender_type: nil, sender_id: nil)
  end

  def unlink_lead_submissions_contact!
    scope = LeadSubmission.where(account_id: account.id, contact_id: contact.id)
    if nullable_column?(LeadSubmission, :contact_id)
      updates = { contact_id: nil }
      updates[:contact_inbox_id] = nil if LeadSubmission.column_names.include?('contact_inbox_id')
      scope.update_all(updates)
    else
      scope.delete_all
    end
  end

  def unlink_or_delete_by_column!(klass, column, values)
    scope = klass.where(column => values)
    nullable_column?(klass, column) ? scope.update_all(column => nil) : scope.delete_all
  end
  # rubocop:enable Rails/SkipsModelValidations

  def purge_redis_vaults!(conv_ids, call_session_ids)
    scopes = conv_ids.map { |cid| "conv:#{cid}" } + call_session_ids.map { |sid| "call:#{sid}" }
    scopes.uniq.each do |scope_id|
      Llm::PiiSessionPseudonymizer.purge_scope!(account_id: account.id, scope_id: scope_id) if defined?(Llm::PiiSessionPseudonymizer)
      Llm::IinTokenVault.purge_scope!(account_id: account.id, scope_id: scope_id) if defined?(Llm::IinTokenVault)
    end
  rescue StandardError => e
    Rails.logger.warn("[Compliance::SubjectErasureService] Redis vault purge warning: #{e.class}")
  end

  def appointment_scope(conv_ids = [])
    return Scheduling::Appointment.none unless defined?(Scheduling::Appointment)

    base = Scheduling::Appointment.where(account_id: account.id)
    by_contact = base.where('contact_id = :id OR patient_contact_id = :id', id: contact.id)
    conv_ids.present? ? by_contact.or(base.where(conversation_id: conv_ids)) : by_contact
  end

  def nullable_column?(klass, column_name)
    klass.columns_hash[column_name.to_s]&.null != false
  end

  def sync_remote_ledger(certificate_uid, entries, erased_at, counts)
    Compliance::TombstoneRemoteLedger.write_erasure!(
      account_id: account.id,
      certificate_uid: certificate_uid,
      entries: entries,
      erased_at: erased_at,
      reason: reason,
      metadata: counts
    )
  rescue StandardError => e
    Rails.logger.error("[Compliance::SubjectErasureService] remote ledger sync failed account_id=#{account.id}: #{e.class}: #{e.message}")
    nil
  end

  def build_certificate(certificate_uid:, erased_at:, entries:, counts:, remote_key:)
    almaty_time = erased_at.in_time_zone(ALMATY_TIME_ZONE)
    {
      document_title: 'Акт об уничтожении персональных данных',
      legal_basis: 'Закон Республики Казахстан «О персональных данных и их защите» (ст. 15, ст. 18)',
      certificate_uid: certificate_uid,
      account_id: account.id,
      actor_id: actor_id,
      reason: reason,
      erased_at: almaty_time.iso8601,
      timezone: ALMATY_TIME_ZONE,
      identifiers_tombstoned_count: entries.size,
      identifier_kinds: entries.pluck(:kind).uniq.sort,
      erased_counts: counts,
      remote_ledger_synced: remote_key.present?,
      remote_ledger_key: remote_key
    }
  end
end
# rubocop:enable Metrics/ClassLength
