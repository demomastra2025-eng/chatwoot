class Integrations::Medelement::PatientsSyncService
  def initialize(account:, client:, conflict_tracker: nil, organization_id: nil)
    @resolver = Integrations::Medelement::ContactResolverService.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: organization_id
    )
  end

  def sync_patient_codes(patient_codes)
    patient_codes.uniq.each_with_object({}) do |patient_code, result|
      result[patient_code.to_s] = resolver.sync_patient!(patient_code)
    end
  end

  private

  attr_reader :resolver
end
