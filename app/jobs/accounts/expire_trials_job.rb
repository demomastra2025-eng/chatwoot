# frozen_string_literal: true

# Ends the trials that ran out. Only accounts that carry a trial snapshot are touched, i.e. accounts whose
# trial was started by Account#activate_trial! (self-registration). Accounts that were put on the "trial"
# plan by hand, or that existed before trials were automated, are never changed by this job.
class Accounts::ExpireTrialsJob < ApplicationJob
  queue_as :housekeeping

  def perform
    expirable_accounts.find_each do |candidate|
      account = Account.find_by(id: candidate.id)
      account&.expire_trial!(only_if_expired: true)
    rescue StandardError => e
      Rails.logger.error("[ExpireTrialsJob] Could not end the trial of account #{candidate.id}: #{e.class.name}: #{e.message}")
    end
  end

  private

  def expirable_accounts
    Account.where("custom_attributes->>'plan_type' = 'trial'")
           .where("jsonb_typeof(custom_attributes->'#{Account::TRIAL_SNAPSHOT_KEY}'->'features') = 'array'")
           .where("custom_attributes->>'trial_expired_at' IS NULL")
  end
end
