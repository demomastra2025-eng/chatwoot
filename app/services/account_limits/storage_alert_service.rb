# frozen_string_literal: true

class AccountLimits::StorageAlertService
  ALERT_COOLDOWN = 24.hours
  WARNING_THRESHOLD = 80.0
  CRITICAL_THRESHOLD = 95.0

  def initialize(account:)
    @account = account
  end

  def perform
    return { status: :unlimited, alert_sent: false } if unlimited?

    usage_percent = calculate_usage_percent
    level = determine_level(usage_percent)

    case level
    when :critical
      handle_alert_level(:critical, usage_percent)
    when :warning
      handle_alert_level(:warning, usage_percent)
    else
      clear_alert_level
      { status: :normal, usage_percent: usage_percent, alert_sent: false }
    end
  end

  def self.check_all_accounts!
    accounts_with_limits = Account.where.not(limits: [nil, {}])
    results = { checked: 0, alerts_sent: 0 }

    accounts_with_limits.find_each do |account|
      next unless account.limits&.key?('storage_bytes')

      res = new(account: account).perform
      results[:checked] += 1
      results[:alerts_sent] += 1 if res[:alert_sent]
    end

    results
  end

  private

  def storage_service
    @storage_service ||= AccountLimits::StorageUsageService.new(account: @account)
  end

  def unlimited?
    storage_service.send(:unlimited?)
  end

  def calculate_usage_percent
    consumed = storage_service.usage_bytes
    total = storage_service.send(:total_limit_bytes).to_i
    return 0.0 if total.zero? || total == ChatwootApp.max_limit.to_i

    [((consumed.to_f / total) * 100).round(1), 100.0].min
  end

  def determine_level(percent)
    if percent >= CRITICAL_THRESHOLD
      :critical
    elsif percent >= WARNING_THRESHOLD
      :warning
    else
      :normal
    end
  end

  def handle_alert_level(level, percent)
    sent_key = "account:#{@account.id}:storage_alert_sent_at:#{level}"
    last_sent = Redis::Alfred.get(sent_key).to_i
    now = Time.current.to_i

    if last_sent.zero? || (now - last_sent) > ALERT_COOLDOWN.to_i
      dispatch_alert(level, percent)
      Redis::Alfred.setex(sent_key, ALERT_COOLDOWN.to_i, now.to_s)
      Redis::Alfred.set("account:#{@account.id}:storage_alert_level", level.to_s)
      { status: level, usage_percent: percent, alert_sent: true }
    else
      { status: level, usage_percent: percent, alert_sent: false, throttled: true }
    end
  end

  def clear_alert_level
    current_level = Redis::Alfred.get("account:#{@account.id}:storage_alert_level")
    return if current_level.blank?

    Redis::Alfred.delete("account:#{@account.id}:storage_alert_level")
  end

  def dispatch_alert(level, percent)
    used = storage_service.usage_bytes
    limit = storage_service.send(:total_limit_bytes).to_i

    mailer = AdministratorNotifications::AccountNotificationMailer
    if level == :critical
      mailer.storage_critical(@account, percent, used, limit).deliver_later
    else
      mailer.storage_warning(@account, percent, used, limit).deliver_later
    end
  rescue StandardError => e
    Rails.logger.warn("[StorageAlertService] Failed to dispatch #{level} email for account #{@account.id}: #{e.message}")
  end
end
