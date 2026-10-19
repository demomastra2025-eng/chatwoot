# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::DashboardAlerts do
  def alerts = described_class.new.alerts

  def alert(key) = alerts.find { |entry| entry[:key] == key }

  def trial_account(expires_at, **attributes)
    create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => expires_at.iso8601 }.merge(attributes))
  end

  def queue_stats(dead: 0, queues: [])
    SuperAdmin::QueueStats::Result.new(busy: 0, enqueued: 0, scheduled: 0, retries: 0, dead: dead, processed: 0, failed: 0, queues: queues)
  end

  def queue(name, latency, jobs: 3) = SuperAdmin::QueueStats::Queue.new(name: name, jobs: jobs, latency: latency)

  def write_snapshot(account, consumed:, total: 100, unlimited: false)
    Redis::Alfred.set("account:#{account.id}:storage_overview_v1",
                      JSON.generate(limits: { total_count: total, consumed: consumed, unlimited: unlimited, current_available: total - consumed }))
  end

  def mark_for_reauthorization(channel)
    Redis::Alfred.set(Reauthorizable.required_key(channel.class, channel.id), 'true')
  end

  before do
    allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return({ status: 'valid' })
    allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats)
  end

  after do
    Account.pluck(:id).each { |id| Redis::Alfred.delete("account:#{id}:storage_overview_v1") }
    [Channel::Whatsapp, Channel::Email, Channel::FacebookPage].each do |klass|
      klass.pluck(:id).each { |id| Redis::Alfred.delete(Reauthorizable.required_key(klass, id)) }
    end
  end

  it 'has nothing to report on a quiet platform' do
    create(:account)

    expect(alerts).to eq([])
  end

  describe 'trials' do
    it 'lists the trials that end within three days, the soonest first, with the time left' do
      later = trial_account(2.days.from_now)
      sooner = trial_account(5.hours.from_now)
      trial_account(5.days.from_now)

      found = alert('trials_ending')

      expect(found).to include(severity: :warning, count: 2, title: 'Пробный период заканчивается в ближайшие 3 дня')
      expect(found[:items].pluck(:label)).to eq([sooner.name, later.name])
      expect(found[:items].pluck(:url)).to eq(["/super_admin/accounts/#{sooner.id}", "/super_admin/accounts/#{later.id}"])
      expect(found[:items].first[:note]).to match(/\Aосталось 4 часа · до \d\d\.\d\d\.\d{4} \d\d:\d\d\z/)
      expect(found[:more_url]).to eq('/super_admin/accounts?search=trial_active%3A')
      expect(found[:more_label]).to eq('Все аккаунты на пробном периоде')
    end

    it 'lists the trials that ended within seven days, the latest first' do
      older = trial_account(6.days.ago)
      latest = trial_account(1.day.ago)
      trial_account(8.days.ago)

      found = alert('trials_expired')

      expect(found).to include(severity: :warning, count: 2)
      expect(found[:items].pluck(:label)).to eq([latest.name, older.name])
      expect(found[:items].first[:note]).to match(/\Aзакончился \d\d\.\d\d\.\d{4} \d\d:\d\d\z/)
      expect(found[:more_url]).to eq('/super_admin/accounts?search=trial_expired%3A')
      expect(found[:more_label]).to eq('Все аккаунты с истёкшим пробным периодом')
    end

    it 'leaves out accounts without a trial, with an unreadable date and the ones marked for deletion' do
      create(:account, custom_attributes: { 'plan_type' => 'paid', 'trial_expires_at' => 1.day.from_now.iso8601 })
      create(:account, custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => 'soon' })
      create(:account, custom_attributes: { 'plan_type' => 'trial' })
      trial_account(1.day.from_now, 'marked_for_deletion_at' => 1.day.from_now.iso8601)

      expect(alerts).to eq([])
    end

    it 'shows ten and counts all' do
      create_list(:account, 12) do |account, index|
        account.update!(custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => (index + 1).hours.from_now.iso8601 })
      end

      found = alert('trials_ending')

      expect(found[:count]).to eq(12)
      expect(found[:items].size).to eq(described_class::LIST_LIMIT)
    end
  end

  describe 'storage' do
    it 'tells the accounts that filled 95% from those that filled 80%, the fullest first' do
      full = create(:account)
      fuller = create(:account)
      filling = create(:account)
      calm = create(:account)
      write_snapshot(full, consumed: 96)
      write_snapshot(fuller, consumed: 99)
      write_snapshot(filling, consumed: 80)
      write_snapshot(calm, consumed: 79)

      expect(alert('storage_critical')).to include(severity: :danger, count: 2)
      expect(alert('storage_critical')[:items].pluck(:label)).to eq([fuller.name, full.name])
      expect(alert('storage_critical')[:items].first[:note]).to eq('99% · 99 Б из 100 Б')
      expect(alert('storage_warning')).to include(severity: :warning, count: 1)
      expect(alert('storage_warning')[:items].pluck(:label)).to eq([filling.name])
      expect(alert('storage_warning')[:more_url]).to eq('/super_admin/accounts?search=storage_high%3A')
    end

    it 'says that the link opens every account with the disk from 80%, as that list is wider than the alert' do
      write_snapshot(create(:account), consumed: 97)
      write_snapshot(create(:account), consumed: 85)

      expect(alerts.pluck(:more_label)).to eq(['Все аккаунты с диском от 80%'] * 2)
    end

    it 'does not count an account without a limit, without a snapshot yet or being deleted' do
      unlimited = create(:account)
      create(:account)
      deleting = create(:account, custom_attributes: { 'marked_for_deletion_at' => 3.days.from_now.iso8601 })
      write_snapshot(unlimited, consumed: 500, unlimited: true)
      write_snapshot(deleting, consumed: 99)

      expect(alerts).to eq([])
    end
  end

  describe 'the OpenRouter key' do
    {
      'invalid' => :danger, 'expired' => :danger, 'credits_exhausted' => :danger, 'key_limit_exhausted' => :danger,
      'missing' => :warning, 'unavailable' => :warning
    }.each do |status, severity|
      it "raises a #{severity} alert for the status #{status}, with a link to the AI models page" do
        allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return({ status: status })

        found = alert("openrouter_#{status}")

        expect(found).to include(severity: severity, count: 1)
        expect(found[:items].first[:url]).to eq('/super_admin/app_config?config=captain#openrouter-diagnostics')
        expect(found[:title]).to be_present
      end
    end

    it 'is quiet while the key is valid, not checked yet, or its credits cannot be read' do
      %w[valid not_checked credits_unavailable].each do |status|
        allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return({ status: status })

        expect(alerts).to eq([])
      end
    end

    it 'warns when a tenth or less of the credits is left' do
      allow(Llm::OpenRouterKeyHealth).to receive(:metadata)
        .and_return({ status: 'valid', credits: { status: 'available', total_credits: 100.0, remaining_credits: 8.0 } })

      expect(alert('openrouter_credits_low')).to include(severity: :warning)
    end

    it 'does not warn while there is more left, and does not read the metadata live' do
      allow(Llm::OpenRouterKeyHealth).to receive(:metadata)
        .and_return({ status: 'valid', credits: { status: 'available', total_credits: 100.0, remaining_credits: 60.0 } })
      expect(Llm::OpenRouterKeyHealth).not_to receive(:refresh!)

      expect(alerts).to eq([])
    end
  end

  describe 'the queues' do
    it 'raises a danger alert for a queue that has waited more than a minute' do
      queues = [queue('default', 61), queue('mailers', 60), queue('low', 400, jobs: 9)]
      allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats(queues: queues))

      found = alert('queues_slow')

      expect(found).to include(severity: :danger, count: 2)
      expect(found[:items].pluck(:label)).to eq(%w[low default])
      expect(found[:items].first).to include(url: '/super_admin/monitoring?tab=queues', note: 'ждёт 6 минут, задач в очереди: 9')
    end

    it 'raises a warning for jobs that are dead' do
      allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats(dead: 4, queues: [queue('default', 2)]))

      expect(alert('queues_dead')).to include(severity: :warning, count: 4)
      expect(alert('queues_slow')).to be_nil
    end

    it 'says so when the queues cannot be read' do
      allow(SuperAdmin::QueueStats).to receive(:read).and_return(nil)

      expect(alert('queues_unavailable')).to include(severity: :warning)
    end
  end

  describe 'channels to authorize again' do
    let(:account) { create(:account, name: 'Клиника «Алатау»') }

    def whatsapp(name = 'WhatsApp клиники')
      channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      channel.inbox.update!(name: name)
      channel
    end

    it 'lists the channels that ask for it, with the kind and the account' do
      marked = whatsapp
      mark_for_reauthorization(marked)
      email = create(:channel_email, account: account)
      email.inbox.update!(name: 'Почта клиники')
      mark_for_reauthorization(email)
      whatsapp('Рабочий номер') # not marked

      found = alert('reauthorization')

      expect(found).to include(severity: :danger, count: 2)
      expect(found[:items].pluck(:label)).to contain_exactly('WhatsApp клиники · Клиника «Алатау»', 'Почта клиники · Клиника «Алатау»')
      expect(found[:items].pluck(:note)).to contain_exactly('WhatsApp', 'Email')
      expect(found[:items].pluck(:url).uniq).to eq(["/super_admin/accounts/#{account.id}"])
    end

    it 'counts a WhatsApp channel that keeps the mark in its settings even when Redis lost it' do
      channel = whatsapp
      config = channel.provider_config.merge('reauthorization_required' => true)
      channel.update_columns(provider_config: config) # rubocop:disable Rails/SkipsModelValidations

      expect(alert('reauthorization')).to include(count: 1)
    end

    it 'is quiet when no channel asks' do
      whatsapp
      create(:channel_email, account: account)

      expect(alert('reauthorization')).to be_nil
    end
  end

  describe 'ordering and failures' do
    it 'puts the danger alerts before the warnings' do
      trial_account(1.day.from_now)
      allow(SuperAdmin::QueueStats).to receive(:read).and_return(queue_stats(queues: [queue('default', 300)]))

      expect(alerts.pluck(:key)).to eq(%w[queues_slow trials_ending])
    end

    it 'names a check that could not be made instead of looking like all is well' do
      trial_account(1.day.from_now)
      allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_raise(StandardError, 'cache down')

      found = alerts

      expect(found.pluck(:key)).to include('trials_ending', 'incomplete')
      expect(alert('incomplete')[:text]).to eq('Не удалось проверить: ключ OpenRouter. Остальные проверки выполнены.')
    end
  end

  describe '.build' do
    let(:store) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(store) }

    it 'keeps the answer for a short while and runs the checks again on request' do
      trial_account(1.day.from_now)
      expect(described_class.build.pluck(:key)).to eq(['trials_ending'])
      expect_any_instance_of(described_class).not_to receive(:alerts) # rubocop:disable RSpec/AnyInstance

      expect(described_class.build.pluck(:key)).to eq(['trials_ending'])
    end

    it 'runs again when it is asked to refresh' do
      trial_account(1.day.from_now)
      described_class.build
      trial_account(2.days.from_now)

      expect(described_class.build.first[:count]).to eq(1)
      expect(described_class.build(force_refresh: true).first[:count]).to eq(2)
    end

    it 'says that nothing could be checked instead of failing the page or looking like all is well' do
      allow(store).to receive(:fetch).and_raise(StandardError, 'cache down')

      found = described_class.build

      expect(found.pluck(:key)).to eq(['incomplete'])
      expect(found.first).to include(severity: :warning, count: 5, title: 'Часть проверок не выполнена')
      expect(found.first[:text]).to start_with('Не удалось выполнить ни одну проверку (')
      expect(found.first[:text]).to include('пробные периоды, место на диске, ключ OpenRouter, очереди задач, каналы')
    end
  end

  describe 'the cost' do
    def seed(extra)
      extra.times do
        trial_account(1.day.from_now)
        full = create(:account)
        write_snapshot(full, consumed: 97)
        channel = create(:channel_email, account: full)
        mark_for_reauthorization(channel)
      end
    end

    it 'is the same for one problem of each kind and for many' do
      seed(1)
      few = sql_queries_during { described_class.new.alerts }
      seed(11)
      many = sql_queries_during { described_class.new.alerts }

      expect(many.size).to eq(few.size), ['few:', *few, 'many:', *many].join("\n")
    end
  end
end
