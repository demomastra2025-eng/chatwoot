# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::DashboardChecklist do
  # An alert as SuperAdmin::DashboardAlerts builds it
  def alert(key, severity: :warning, items: [], **extra)
    {
      key: key, severity: severity, title: "Заголовок #{key}", text: "Совет #{key}", count: items.size, items: items,
      more_url: nil, more_label: nil, listed: true
    }.merge(extra)
  end

  def item(label, id: 1, note: nil)
    { label: label, url: "/super_admin/accounts/#{id}", note: note }
  end

  # An account as SuperAdmin::HealthMatrixService builds it
  def account(id, name = "Аккаунт #{id}", **lines)
    {
      id: id, name: name, status: 'active', whatsapp: { state: 'none', label: 'Не подключен' }, telephony: { state: 'none', label: 'Нет линий' },
      medelement: { state: 'none', label: 'Не настроен' }, failed_messages: 0, needs_attention: false
    }.merge(lines)
  end

  let(:summary) { { total_accounts: 1, incomplete_sources: [] } }

  def build(alerts: [], accounts: [], health_summary: summary)
    described_class.build(alerts: alerts, health_accounts: accounts, health_summary: health_summary)
  end

  def keys(checklist) = checklist.rows.pluck(:key)

  it 'has nothing to report on a quiet platform' do
    checklist = build(accounts: [account(1)])

    expect(checklist.rows).to eq([])
    expect(checklist.total).to eq(0)
    expect(checklist.severity).to be_nil
  end

  describe 'a row of an alert that names accounts' do
    it 'says what is wrong, which account, and opens the place where it is put right' do
      ending = alert('trials_ending', items: [item('Клиника «Алатау»', id: 7, note: 'осталось 2 дня · до 22.10.2026 12:00')])

      row = build(alerts: [ending]).rows.first

      expect(row).to include(
        key: 'trials_ending', severity: :warning, title: 'Пробный период заканчивается', subject: 'Клиника «Алатау»',
        note: 'осталось 2 дня · до 22.10.2026 12:00', more: false
      )
      expect(row[:action]).to eq(label: 'Продлить или назначить тариф', url: '/super_admin/accounts/7#trial-title')
    end

    it 'sends the storage to the block of the card that shows where the place goes, and a channel to the card' do
      storage = alert('storage_critical', severity: :danger, items: [item('Клиника А', id: 3, note: '97% · 9,7 ГБ из 10 ГБ')])
      channel = alert('reauthorization', severity: :danger, items: [item('Рабочий Telegram · Клиника Б', id: 4, note: 'Telegram (личный)')])

      rows = build(alerts: [storage, channel]).rows.index_by { |row| row[:key] }

      expect(rows['storage_critical'][:action]).to eq(label: 'Посмотреть место', url: '/super_admin/accounts/3#usage-title')
      expect(rows['storage_critical'][:title]).to eq('Место почти закончилось')
      expect(rows['reauthorization'][:action]).to eq(label: 'Открыть аккаунт', url: '/super_admin/accounts/4')
      expect(rows['reauthorization'][:subject]).to eq('Рабочий Telegram · Клиника Б')
    end

    it 'has a row for every account of the alert' do
      ended = alert('trials_expired', items: [item('А', id: 1), item('Б', id: 2)])

      checklist = build(alerts: [ended])

      expect(checklist.rows.pluck(:subject)).to eq(%w[А Б])
      expect(checklist.rows.map { |row| row[:action][:label] }.uniq).to eq(['Назначить тариф'])
    end
  end

  describe 'a row of an alert about the whole platform' do
    it 'is one row with the advice of the alert, the first link of the alert as its button and «Вся платформа» as its subject' do
      key = alert('openrouter_invalid', severity: :danger, items: [{ label: 'Модели ИИ', url: '/super_admin/app_config?config=captain#openrouter-diagnostics', note: nil }], count: 1)

      row = build(alerts: [key]).rows.first

      expect(row).to include(title: 'Заголовок openrouter_invalid', subject: 'Вся платформа', hint: 'Совет openrouter_invalid')
      expect(row[:action]).to eq(label: 'Открыть «Модели ИИ»', url: '/super_admin/app_config?config=captain#openrouter-diagnostics')
    end

    it 'folds the names of the slow queues under «Для разработчика»' do
      queues = [{ label: 'default', url: '/super_admin/monitoring?tab=queues', note: 'ждёт 3 минуты, задач в очереди: 7' },
                { label: 'low', url: '/super_admin/monitoring?tab=queues', note: 'ждёт 2 минуты, задач в очереди: 1' }]

      checklist = build(alerts: [alert('queues_slow', severity: :danger, items: queues)])

      expect(checklist.rows.size).to eq(1)
      expect(checklist.rows.first[:details]).to eq(['default: ждёт 3 минуты, задач в очереди: 7', 'low: ждёт 2 минуты, задач в очереди: 1'])
      expect(checklist.rows.first[:action]).to eq(label: 'Открыть очереди', url: '/super_admin/monitoring?tab=queues')
      expect(checklist.total).to eq(1)
    end

    it 'counts the dead jobs in the title and as one problem' do
      link = { label: 'Мониторинг', url: '/super_admin/monitoring?tab=queues', note: nil }

      checklist = build(alerts: [alert('queues_dead', items: [link], count: 1250, listed: false)])

      expect(checklist.rows.first[:title]).to eq('Часть фоновых задач не выполнилась: 1 250')
      expect(checklist.total).to eq(1)
    end

    it 'offers to run the checks again when some could not be made' do
      checklist = build(alerts: [alert('incomplete', items: [], count: 2, listed: false)])

      expect(checklist.rows.first[:action]).to eq(label: 'Проверить ещё раз', url: '/super_admin?refresh=true')
    end
  end

  describe 'the order' do
    it 'puts the serious first, and inside one severity what stops everybody before what stops one account' do
      alerts = [
        alert('trials_ending', items: [item('А')]),
        alert('storage_warning', items: [item('Б')]),
        alert('reauthorization', severity: :danger, items: [item('В')]),
        alert('queues_slow', severity: :danger, items: []),
        alert('openrouter_invalid', severity: :danger, items: [])
      ]

      checklist = build(alerts: alerts)

      expect(keys(checklist)).to eq(%w[openrouter_invalid queues_slow reauthorization trials_ending storage_warning])
      expect(checklist.severity).to eq(:danger)
    end

    it 'has the colour of a warning when nothing is serious' do
      expect(build(alerts: [alert('trials_ending', items: [item('А')])]).severity).to eq(:warning)
    end

    it 'puts the problems of the accounts among the alerts by the same rule' do
      alerts = [alert('trials_ending', items: [item('Триал')]), alert('reauthorization', severity: :danger, items: [item('Канал')])]
      accounts = [account(5, 'Звонки', telephony: { state: 'error', label: 'Сервер звонков не настроен' }),
                  account(6, 'Письма', failed_messages: 3)]

      expect(keys(build(alerts: alerts, accounts: accounts))).to eq(%w[reauthorization telephony_error trials_ending failed_messages])
    end
  end

  describe 'the rows after the first ones of a kind' do
    it 'says that only the first ones are listed and links to the whole list when the alert has one' do
      items = Array.new(10) { |index| item("Аккаунт #{index}", id: index + 1) }
      ending = alert('trials_ending', items: items, count: 25, more_url: '/super_admin/accounts?search=trial_active%3A', more_label: 'Все аккаунты на пробном периоде')

      checklist = build(alerts: [ending])

      more = checklist.rows.last
      expect(checklist.rows.size).to eq(11)
      expect(more).to include(more: true, note: 'Показаны первые 10 из 25.', severity: :warning)
      expect(more[:action]).to eq(label: 'Все аккаунты на пробном периоде', url: '/super_admin/accounts?search=trial_active%3A')
      expect(checklist.total).to eq(25)
    end

    it 'sends to the table «Подробно по каналам» when the alert has no list of its own' do
      items = Array.new(10) { |index| item("Канал #{index}", id: index + 1) }

      checklist = build(alerts: [alert('reauthorization', severity: :danger, items: items, count: 14)])

      more = checklist.rows.last
      expect(more).to include(more: true, note: 'Показаны первые 10 из 14.', hint: 'Остальные видны в блоке «Подробно по каналам» ниже.')
      expect(more[:action]).to be_nil
    end

    it 'does not count a row of this kind as a problem' do
      items = Array.new(10) { |index| item("А#{index}", id: index + 1) }

      expect(build(alerts: [alert('trials_ending', items: items, count: 10)]).rows.count { |row| row[:more] }).to eq(0)
    end
  end

  describe 'the problems found in the table of accounts' do
    it 'lists a telephony without the server of calls as serious, with the account and the words of the table' do
      accounts = [account(5, 'Звонки', telephony: { state: 'error', label: 'Сервер звонков не настроен' })]

      row = build(accounts: accounts).rows.first

      expect(row).to include(key: 'telephony_error', severity: :danger, title: 'Телефония не настроена', subject: 'Звонки', note: 'Сервер звонков не настроен')
      expect(row[:action]).to eq(label: 'Открыть аккаунт', url: '/super_admin/accounts/5')
    end

    it 'lists a line without a number, a failed sync and the conflicts of MedElement' do
      accounts = [
        account(1, 'А', telephony: { state: 'warning', label: 'Линии не привязаны' }),
        account(2, 'Б', medelement: { state: 'error', label: 'Ошибка синхронизации' }),
        account(3, 'В', medelement: { state: 'warning', label: '3 конфликта' })
      ]

      checklist = build(accounts: accounts)

      expect(keys(checklist)).to eq(%w[medelement_error telephony_unbound medelement_conflicts])
      expect(checklist.rows.pluck(:note)).to eq(['Ошибка синхронизации', 'Линии не привязаны', '3 конфликта'])
      expect(checklist.rows.pluck(:severity)).to eq(%i[danger warning warning])
    end

    it 'lists the accounts with messages that did not go out, the most of them first, with the window of days' do
      accounts = [account(1, 'А', failed_messages: 2), account(2, 'Б', failed_messages: 1250), account(3, 'В')]

      checklist = build(accounts: accounts)

      expect(checklist.rows.pluck(:subject)).to eq(%w[Б А])
      expect(checklist.rows.first).to include(title: 'Сообщения не отправились', note: 'за 3 дня: 1 250', severity: :warning)
    end

    it 'does not list the WhatsApp state of the table: the alert about channels names the same channels' do
      accounts = [account(1, 'А', whatsapp: { state: 'error', label: 'Требует авторизации' }, needs_attention: true)]

      expect(build(accounts: accounts).rows).to eq([])
    end

    it 'does not list the problems of a blocked account: it is stopped on purpose' do
      accounts = [account(1, 'А', status: 'suspended', telephony: { state: 'error', label: 'x' }, failed_messages: 5)]

      expect(build(accounts: accounts).rows).to eq([])
    end

    it 'lists the first ten of a kind and counts all of them' do
      accounts = Array.new(13) { |index| account(index + 1, "А#{index}", failed_messages: index + 1) }

      checklist = build(accounts: accounts)

      expect(checklist.rows.size).to eq(11)
      expect(checklist.rows.last).to include(more: true, note: 'Показаны первые 10 из 13.')
      expect(checklist.total).to eq(13)
    end
  end

  describe 'a table of accounts that could not be read' do
    it 'does not look like «all is well» when the whole table is missing' do
      checklist = build(accounts: [], health_summary: {})

      expect(checklist.rows.size).to eq(1)
      expect(checklist.rows.first).to include(key: 'matrix_incomplete', severity: :warning, title: 'Состояние аккаунтов не прочиталось')
      expect(checklist.rows.first[:action]).to eq(label: 'Проверить ещё раз', url: '/super_admin?refresh=true')
    end

    it 'names the sources that could not be read' do
      checklist = build(health_summary: { total_accounts: 2, incomplete_sources: ['сообщения', 'линии телефонии'] })

      expect(checklist.rows.first[:hint]).to eq('Не удалось прочитать: сообщения, линии телефонии. Блок «Подробно по каналам» может быть неполным.')
      expect(checklist.total).to eq(1)
    end
  end

  it 'counts every problem once in the total' do
    alerts = [alert('trials_ending', items: [item('А'), item('Б')]), alert('queues_slow', severity: :danger, items: [])]
    accounts = [account(1, 'А', failed_messages: 1), account(2, 'Б', medelement: { state: 'warning', label: '1 конфликт' })]

    expect(build(alerts: alerts, accounts: accounts).total).to eq(5)
  end

  it 'copes with a stale or empty input' do
    expect(described_class.build(alerts: nil, health_accounts: nil, health_summary: nil).rows.size).to eq(1)
  end
end
