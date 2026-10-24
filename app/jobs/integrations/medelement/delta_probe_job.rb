# Without an argument (the cron entry in config/schedule.yml) it queues one probe per enabled MedElement hook; with a
# hook id it probes that hook. The probe re-syncs the hook's cron jobs; that writes to Redis and works from any worker.
class Integrations::Medelement::DeltaProbeJob < ApplicationJob
  queue_as :scheduled_jobs

  # The probes are independent and cheap; spreading them keeps 200 clinics from calling MedElement in the same second.
  STAGGER = 2.seconds

  discard_on ActiveRecord::RecordNotFound

  def perform(hook_id = nil)
    return enqueue_probes if hook_id.nil?

    hook = Integrations::Hook.find_by!(id: hook_id, app_id: 'medelement')
    Integrations::Medelement::DeltaProbeService.new(hook: hook).perform
  end

  private

  def enqueue_probes
    Integrations::Hook.where(app_id: 'medelement', status: 'enabled').order(:id).pluck(:id).each_with_index do |id, index|
      self.class.set(wait: index * STAGGER).perform_later(id)
    end
  end
end
