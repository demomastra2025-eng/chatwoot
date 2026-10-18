class Integrations::Medelement::PatientsSyncService
  def initialize(account:, client:, conflict_tracker: nil, organization_id: nil)
    @account = account
    @resolver = Integrations::Medelement::ContactResolverService.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: organization_id
    )
  end

  def sync_patient_codes(patient_codes, prefetched_patients: {}, preloaded_contacts: nil)
    codes = Array(patient_codes).filter_map { |code| code.to_s.presence }.uniq
    return {} if codes.empty?

    contacts_by_code = preloaded_contacts || preload_contacts_by_patient_code(codes)
    codes.each_with_object({}) do |patient_code, result|
      existing = contacts_by_code[patient_code]
      prefetched = prefetched_patients.key?(patient_code) ? prefetched_patients[patient_code] : :not_prefetched
      result[patient_code] = resolver.sync_patient!(
        patient_code,
        preferred_contact: existing,
        prefetched_patient: prefetched
      )
    end
  end

  def preload_contacts_by_patient_code(codes)
    return {} if codes.empty?

    account.contacts
           .where("custom_attributes ->> 'medelement_patient_code' IN (?)", codes)
           .index_by { |contact| contact.custom_attributes['medelement_patient_code'].to_s }
  end

  def stale_patient_codes(codes, contacts_by_code)
    codes.reject { |code| resolver.fresh_contact?(contacts_by_code[code]) }
  end

  private

  attr_reader :account, :resolver
end
