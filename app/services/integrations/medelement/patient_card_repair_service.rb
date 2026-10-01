# Explicit repair for owned appointments created before separate patient cards existed, where the chat
# (communication) contact already holds the appointment's MedElement patient code. Dry-run by default.
# It never merges contacts and never matches by phone: the code moves from the chat contact to a card that is
# resolved by the patient code/IIN exactly like PatientContactBinding does for new appointments.
class Integrations::Medelement::PatientCardRepairService
  PATIENT_PROFILE_KEYS = %w[
    medelement_patient_code medelement_last_synced_at medelement_first_name medelement_last_name medelement_middle_name
    medelement_iin medelement_birth_date medelement_gender medelement_email medelement_address
  ].freeze

  def initialize(account:, apply: false)
    @account = account
    @apply = apply
  end

  def perform
    report = Hash.new(0)
    %i[owned_without_card owner_holds_code repairable].each { |key| report[key] = 0 }
    legacy_groups(report).each_value { |ids| process_group(ids, report) }
    { 'apply' => apply }.merge(report.transform_keys(&:to_s))
  end

  private

  attr_reader :account, :apply

  def binding = Integrations::Medelement::PatientContactBinding

  def policy = Integrations::Medelement::AppointmentPatientIdentity

  def legacy_groups(report)
    groups = Hash.new { |hash, key| hash[key] = [] }
    owned_without_card.find_each do |appointment|
      report[:owned_without_card] += 1
      next unless binding.legacy_owner_holds_code?(appointment)

      report[:owner_holds_code] += 1
      groups[[appointment.contact_id, appointment.custom_attributes['medelement_patient_code'].to_s]] << appointment.id
    end
    groups
  end

  def owned_without_card
    account.scheduling_appointments.where(patient_contact_id: nil)
           .where("(custom_attributes ->> ?) = 'true'", policy::OWNED_IDENTITY_KEY)
           .includes(:contact)
  end

  def process_group(ids, report)
    reason = skip_reason(account.scheduling_appointments.where(id: ids).includes(:contact).to_a)
    return report[:"skipped_#{reason}"] += ids.size if reason

    report[:repairable] += ids.size
    return unless apply

    repair_group!(ids) ? report[:repaired] += ids.size : report[:repair_failed] += ids.size
  end

  # Only an owner that provably differs from the authored patient is repaired; anything else needs a human decision.
  def skip_reason(appointments)
    return 'owner_has_iin' if appointments.any? { |appointment| policy.contact_iin(appointment.contact).present? }
    return 'owner_identity_matches' if appointments.any? { |appointment| owner_names_match?(appointment) }

    'unfinished_provider_commands' if appointments.any? { |appointment| unfinished_commands?(appointment) }
  end

  # Pre-release phone claims also copied the provider patient's name onto the chat contact, so a chat contact whose
  # local first name equals the authored patient's cannot be told apart from that patient automatically.
  def owner_names_match?(appointment)
    authored = appointment.client_first_name.to_s.squish.downcase
    authored.present? && authored == appointment.contact.name.to_s.squish.downcase
  end

  def unfinished_commands?(appointment)
    Integrations::Medelement::ProviderCommand.where(account_id: account.id)
                                             .where('appointment_id = :appointment OR contact_id = :contact',
                                                    appointment: appointment.id, contact: appointment.contact_id)
                                             .unfinished.exists?
  end

  # Lock order matches the importer, UpsertService and merges: appointment rows (by id) first, then the account-wide
  # phone identity lock (PatientContactBinding takes it again, re-entrantly). A deadlock still only fails this group.
  def repair_group!(ids)
    Scheduling::Appointment.transaction do
      appointments = account.scheduling_appointments.where(id: ids).order(:id).lock.to_a
      Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
      raise ActiveRecord::Rollback unless still_repairable?(appointments)

      owner = account.contacts.lock.find(appointments.first.contact_id)
      code = owner.custom_attributes['medelement_patient_code']
      release_patient_code!(owner)
      appointments.each { |appointment| bind_card!(appointment, code) }
      true
    end
  rescue Scheduling::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::Deadlocked
    false
  end

  def still_repairable?(appointments)
    appointments.all? { |appointment| binding.legacy_owner_holds_code?(appointment) } && skip_reason(appointments).nil?
  end

  def release_patient_code!(owner)
    owner.skip_runtime_events = true
    owner.update!(custom_attributes: owner.custom_attributes.except(*PATIENT_PROFILE_KEYS))
  end

  def bind_card!(appointment, code)
    appointment.reload
    card = binding.new(appointment: appointment).prepare!(patient_code: code)
    raise ActiveRecord::Rollback unless card

    # Local repair only: the provider already holds this reception under the same patient code.
    appointment.update_columns(patient_contact_id: card.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
