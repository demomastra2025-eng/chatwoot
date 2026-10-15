require 'rails_helper'

RSpec.describe SuperAdmin::AccountUsage do
  def summary(consumed:, total:, unlimited: false)
    { total_count: total, current_available: [total - consumed, 0].max, consumed: consumed, unlimited: unlimited }
  end

  let(:overview) do
    {
      agents: summary(consumed: 7, total: 10),
      inboxes: summary(consumed: 2, total: ChatwootApp.max_limit, unlimited: true),
      conversations: summary(consumed: 850, total: 1000),
      non_web_inboxes: summary(consumed: 0, total: 0),
      emails: summary(consumed: 12, total: 100),
      storage: summary(consumed: 48.gigabytes, total: 50.gigabytes),
      captain: {
        responses: summary(consumed: 5, total: 100),
        documents: summary(consumed: 1, total: 10),
        tokens: summary(consumed: 900, total: 1000)
      }
    }
  end
  let(:usage) { described_class.new(overview: overview) }

  def row(key)
    usage.row(key)
  end

  it 'lists every limit in the order the card shows them, with Russian names' do
    expect(usage.rows.map(&:label)).to eq(
      ['Операторы', 'Каналы', 'Диалоги за 30 дней', 'Основные каналы', 'Хранилище', 'Ответы ИИ', 'Документы ИИ', 'Токены ИИ', 'Письма в день']
    )
  end

  it 'gives every limit a Russian hint' do
    expect(usage.rows.map(&:hint)).to all(match(/\p{Cyrillic}/))
  end

  it 'computes the share of a limit that is used' do
    expect(row(:agents).percent).to eq(70.0)
    expect(row(:conversations).percent).to eq(85.0)
    expect(row(:storage).percent).to eq(96.0)
  end

  it 'tones the meter by how full it is: good below 80%, warn from 80%, bad from 95%' do
    expect(row(:agents).tone).to eq(:good)
    expect(row(:conversations).tone).to eq(:warn)
    expect(row(:storage).tone).to eq(:bad)
    expect(row(:captain_tokens).percent).to eq(90.0)
    expect(row(:captain_tokens).tone).to eq(:warn)
  end

  it 'has no meter for an unlimited limit' do
    channels = row(:inboxes)

    expect(channels.unlimited).to be(true)
    expect(channels.percent).to be_nil
    expect(channels.tone).to eq(:idle)
  end

  it 'reads the no-limit value a plan writes (the maximum limit) as unlimited, except for the storage size' do
    overview[:conversations] = summary(consumed: 3, total: ChatwootApp.max_limit)
    overview[:storage] = summary(consumed: 3, total: ChatwootApp.max_limit)

    expect(row(:conversations)).to have_attributes(unlimited: true, percent: nil, tone: :idle)
    expect(row(:storage)).to have_attributes(unlimited: false)
  end

  it 'marks a limit of 0 as forbidden' do
    main_channels = row(:non_web_inboxes)

    expect(main_channels).to be_blocked
    expect(main_channels.percent).to be_nil
    expect(main_channels.tone).to eq(:bad)
  end

  it 'flags the storage as a size' do
    expect(row(:storage).bytes).to be(true)
    expect(row(:agents).bytes).to be(false)
  end

  it 'skips a limit the overview does not know' do
    overview.delete(:emails)

    expect(usage.rows.map(&:key)).not_to include(:emails)
  end

  it 'reads the overview of a real clinic once' do
    account = create(:account)
    allow(account).to receive(:account_usage_overview).and_call_original

    described_class.new(account).rows

    expect(account).to have_received(:account_usage_overview).once
  end
end
