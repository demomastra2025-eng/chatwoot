class Integrations::Medelement::CleanupService
  RESOURCE_CUSTOM_ATTRIBUTE_KEYS = %w[
    medelement_cabinets
    medelement_default_work_rules_seeded_at
    medelement_reception_time
    medelement_schedule_published
    medelement_specialist_code
  ].freeze

  def initialize(account:)
    @account = account
  end

  def perform
    cleanup_imported_appointments!
    cleanup_imported_resources!
  end

  private

  attr_reader :account

  def cleanup_imported_appointments!
    account.scheduling_appointments.where(source: 'medelement').find_each(&:destroy!)
  end

  def cleanup_imported_resources!
    imported_resources.find_each do |resource|
      if resource.appointments.where.not(source: 'medelement').exists?
        resource.update!(custom_attributes: local_resource_custom_attributes(resource))
      else
        resource.destroy!
      end
    end
  end

  def imported_resources
    account.scheduling_resources.where("custom_attributes ->> 'medelement_specialist_code' IS NOT NULL")
  end

  def local_resource_custom_attributes(resource)
    resource.custom_attributes.except(*RESOURCE_CUSTOM_ATTRIBUTE_KEYS)
  end
end
