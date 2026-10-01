# frozen_string_literal: true

class SuperAdmin::HealthMatrixService
  def self.build
    new.build
  end

  def build
    accounts = Account.order(id: :asc).map { |account| build_account_health(account) }
    summary = calculate_summary(accounts)
    [accounts, summary]
  rescue StandardError => e
    Rails.logger.error "Health matrix error: #{e.message}"
    [[], {}]
  end

  private

  def build_account_health(account)
    wa_status = calculate_whatsapp_status(account)
    tel_status = calculate_telephony_status(account)
    med_status = calculate_medelement_status(account)
    failed_count = count_failed_messages(account)
    attention = wa_status[:state] == 'error' ||
                tel_status[:state] == 'error' ||
                med_status[:state] == 'error' ||
                failed_count.positive?

    {
      id: account.id,
      name: account.name,
      status: account.status,
      whatsapp: wa_status,
      telephony: tel_status,
      medelement: med_status,
      failed_messages: failed_count,
      needs_attention: attention
    }
  end

  def count_failed_messages(account)
    account.messages.where(status: :failed).count
  rescue StandardError
    0
  end

  def calculate_whatsapp_status(account)
    wa_inboxes = begin
      account.inboxes.select { |i| i.channel_type.to_s.include?('Whatsapp') }
    rescue StandardError
      []
    end
    return { state: 'none', label: '???? ????????????????', count: 0 } if wa_inboxes.empty?

    active = wa_inboxes.any? do |i|
      !i.channel.try(:reauthorization_required?)
    end
    {
      state: active ? 'healthy' : 'error',
      label: active ? "#{wa_inboxes.size} ??????????????" : '???????? ????????????',
      count: wa_inboxes.size
    }
  end

  def calculate_telephony_status(account)
    phone_inboxes = begin
      account.inboxes.select { |i| i.channel_type.to_s.include?('Phone') }
    rescue StandardError
      []
    end
    sip_profiles = begin
      Telephony::SipProfile.where(account_id: account.id)
    rescue StandardError
      []
    end
    bindings = begin
      Telephony::NumberBinding.where(account_id: account.id)
    rescue StandardError
      []
    end
    connections = begin
      Telephony::ProviderConnection.where(account_id: account.id)
    rescue StandardError
      []
    end

    missing_janus = begin
      connections.any? { |c| c.remote_janus_url.blank? }
    rescue StandardError
      false
    end
    unbound_lines = phone_inboxes.any? && bindings.empty?

    if phone_inboxes.empty? && sip_profiles.empty?
      { state: 'none', label: '?????? ??????????', profiles_count: 0 }
    elsif missing_janus
      { state: 'error', label: 'Janus URL ????????', profiles_count: sip_profiles.size }
    elsif unbound_lines
      { state: 'warning', label: '?????????? ?????? ????????????????', profiles_count: sip_profiles.size }
    else
      { state: 'healthy', label: "#{sip_profiles.size} ???????????????? OK", profiles_count: sip_profiles.size }
    end
  end

  def calculate_medelement_status(account)
    med_runs = begin
      Integrations::Medelement::SyncRun.where(account_id: account.id).order(created_at: :desc).limit(5)
    rescue StandardError
      []
    end
    med_conflicts = begin
      Integrations::Medelement::SyncConflict.where(account_id: account.id, resolved: false).count
    rescue StandardError
      0
    end

    if med_conflicts.positive?
      { state: 'warning', label: "#{med_conflicts} ????????????????????" }
    elsif med_runs.any? { |r| r.status.to_s.include?('fail') || r.status.to_s.include?('error') }
      { state: 'error', label: '???????????? ??????????????????????????' }
    elsif med_runs.any?
      { state: 'healthy', label: '?? ??????????' }
    else
      { state: 'none', label: '???? ??????????????????' }
    end
  end

  def calculate_summary(accounts)
    {
      total_accounts: accounts.size,
      needs_attention: accounts.count { |a| a[:needs_attention] },
      whatsapp_healthy: accounts.count { |a| a[:whatsapp][:state] == 'healthy' },
      telephony_healthy: accounts.count { |a| a[:telephony][:state] == 'healthy' },
      git_sha: (defined?(GIT_HASH) ? GIT_HASH : '93611c276e3b')
    }
  end
end
