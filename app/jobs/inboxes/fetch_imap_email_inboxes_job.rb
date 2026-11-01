class Inboxes::FetchImapEmailInboxesJob < ApplicationJob
  queue_as :scheduled_jobs
  include BillingHelper

  def perform
    eligible_email_channels.find_each(batch_size: 100) do |channel|
      ::Inboxes::FetchImapEmailsJob.perform_later(channel) if should_fetch_emails?(channel)
    end
  end

  private

  def eligible_email_channels
    Channel::Email
      .where(imap_enabled: true)
      .joins(:account, :inbox)
      .merge(Account.active)
      .includes(:account)
  end

  def should_fetch_emails?(channel)
    return false if channel.account.suspended?
    return false unless channel.imap_enabled
    return false if channel.reauthorization_required?

    return true unless ChatwootApp.chatwoot_cloud?
    return false if default_plan?(channel.account)

    true
  end
end
