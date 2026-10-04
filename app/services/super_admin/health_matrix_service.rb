# frozen_string_literal: true

class SuperAdmin::HealthMatrixService
  CACHE_KEY = 'super_admin:health_matrix'
  CACHE_TTL = 90.seconds
  RECENT_RUNS = 5
  VOICE_CHANNEL_TYPE = 'Channel::Voice'

  def self.build(force_refresh: false)
    new.build(force_refresh: force_refresh)
  end

  def build(force_refresh: false)
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL, force: force_refresh) do
      compute_matrix
    end
  rescue StandardError => e
    Rails.logger.error "Health matrix error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    [[], {}]
  end

  private

  def compute_matrix
    @failed_sources = []
    accounts = Account.order(id: :asc).includes(inboxes: :channel)
    context = load_batch_context(accounts.map(&:id))

    matrix = accounts.map { |account| build_account_health(account, context) }
    summary = calculate_summary(matrix)
    [matrix, summary]
  end

  def load_batch_context(account_ids)
    {
      failed_messages: fetch_failed_messages_map(account_ids),
      sip_profiles: fetch_grouped(Telephony::SipProfile, account_ids),
      bindings: fetch_grouped(Telephony::NumberBinding, account_ids),
      connections: fetch_grouped(Telephony::ProviderConnection, account_ids),
      med_conflicts: fetch_med_conflicts_map(account_ids),
      med_runs: fetch_recent_sync_runs(account_ids)
    }
  end

  # A source that cannot be read must not look like "no problems": it is logged and reported in the summary
  # (incomplete_sources), so the dashboard can say that part of the matrix is missing.
  def load_source(name)
    yield
  rescue StandardError => e
    Rails.logger.warn("[HealthMatrix] #{name} unavailable: #{e.class.name}: #{e.message}")
    @failed_sources << name
    {}
  end

  def fetch_grouped(model_class, account_ids)
    load_source(model_class.name) { model_class.where(account_id: account_ids).group_by(&:account_id) }
  end

  # Only the latest runs per account are needed to judge the sync state; loading the whole (ever growing)
  # run history of every account into memory on each dashboard refresh is not.
  def fetch_recent_sync_runs(account_ids)
    return {} unless defined?(Integrations::Medelement::SyncRun)

    load_source('Integrations::Medelement::SyncRun') do
      model = Integrations::Medelement::SyncRun
      table = model.quoted_table_name
      rank = "ROW_NUMBER() OVER (PARTITION BY #{table}.account_id ORDER BY #{table}.created_at DESC, #{table}.id DESC) AS recency_rank"
      ranked = model.where(account_id: account_ids).select("#{table}.*", rank)
      model.from(ranked, model.table_name).where("recency_rank <= #{RECENT_RUNS}").group_by(&:account_id)
    end
  end

  def fetch_failed_messages_map(account_ids)
    load_source('Message') { Message.unscoped.where(account_id: account_ids, status: :failed).group(:account_id).count }
  end

  def fetch_med_conflicts_map(account_ids)
    return {} unless defined?(Integrations::Medelement::SyncConflict)

    load_source('Integrations::Medelement::SyncConflict') do
      Integrations::Medelement::SyncConflict.where(account_id: account_ids, status: :open).group(:account_id).count
    end
  end

  def build_account_health(account, context)
    wa_status = calculate_whatsapp_status(account)
    tel_status = calculate_telephony_status(account, context)
    med_status = calculate_medelement_status(account, context)
    failed_count = context[:failed_messages][account.id] || 0
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

  def calculate_whatsapp_status(account)
    wa_inboxes = begin
      account.inboxes.select { |i| i.channel_type.to_s.include?('Whatsapp') }
    rescue StandardError
      []
    end
    return { state: 'none', label: 'Не подключен', count: 0 } if wa_inboxes.empty?

    active = wa_inboxes.any? do |i|
      !i.channel.try(:reauthorization_required?)
    end
    {
      state: active ? 'healthy' : 'error',
      label: active ? "#{wa_inboxes.size} подключено" : 'Требует авторизации',
      count: wa_inboxes.size
    }
  end

  def calculate_telephony_status(account, context)
    phone_inboxes = safe_phone_inboxes(account)
    sip_profiles = context[:sip_profiles][account.id] || []
    bindings = context[:bindings][account.id] || []
    connections = context[:connections][account.id] || []

    return { state: 'none', label: 'Нет линий', profiles_count: 0 } if phone_inboxes.empty? && sip_profiles.empty?

    evaluate_telephony_diagnostics(sip_profiles, bindings, connections, phone_inboxes)
  end

  def safe_phone_inboxes(account)
    account.inboxes.select { |i| i.channel_type.to_s == VOICE_CHANNEL_TYPE }
  rescue StandardError
    []
  end

  def evaluate_telephony_diagnostics(sip_profiles, bindings, connections, phone_inboxes)
    if connections.any? { |c| c.remote_janus_url.blank? }
      { state: 'error', label: 'Janus URL не задан', profiles_count: sip_profiles.size }
    elsif phone_inboxes.any? && bindings.empty?
      { state: 'warning', label: 'Линии не привязаны', profiles_count: sip_profiles.size }
    else
      { state: 'healthy', label: "#{sip_profiles.size} профилей OK", profiles_count: sip_profiles.size }
    end
  end

  def calculate_medelement_status(account, context)
    conflicts = context[:med_conflicts][account.id] || 0
    return { state: 'warning', label: "#{conflicts} конфликтов" } if conflicts.positive?

    evaluate_medelement_runs(context[:med_runs][account.id] || [])
  end

  def evaluate_medelement_runs(runs)
    recent_runs = runs.sort_by { |r| r.created_at || Time.zone.at(0) }.last(RECENT_RUNS).reverse
    return { state: 'none', label: 'Не настроен' } if recent_runs.empty?

    has_error = recent_runs.any? { |r| r.status.to_s.include?('fail') || r.status.to_s.include?('error') }
    has_error ? { state: 'error', label: 'Ошибка синхронизации' } : { state: 'healthy', label: 'В норме' }
  end

  def calculate_summary(accounts)
    {
      total_accounts: accounts.size,
      needs_attention: accounts.count { |a| a[:needs_attention] },
      whatsapp_healthy: accounts.count { |a| a[:whatsapp][:state] == 'healthy' },
      telephony_healthy: accounts.count { |a| a[:telephony][:state] == 'healthy' },
      git_sha: GIT_HASH.presence || 'unknown',
      incomplete_sources: Array(@failed_sources).uniq,
      updated_at: Time.current.strftime('%H:%M:%S')
    }
  end
end
