require 'rails_helper'

RSpec.describe SuperAdmin::AiConnectionState do
  let(:health) { { status: 'valid', checked_at: '2026-10-15T12:05:09Z', credits: { status: 'available', remaining_credits: 12.5 } } }
  let(:key_status) { { effective_configured: true, health: health } }
  let(:catalog) { { last_refreshed_at: '2026-10-15T12:05:09Z', total_models: 311, using_fallback: false } }
  let(:runtime) { { estimated_cost: 0.42, request_count: 21, error_count: 1 } }
  let(:state) { described_class.new(key_status: key_status, catalog: catalog, runtime: runtime) }

  describe 'the key' do
    it 'is «Рабочий» in green with the time of the check' do
      expect(state).to have_attributes(key_state: 'valid', key_text: 'Рабочий', key_tone: 'teal', key_set?: true)
      expect(state.key_note).to eq('Ключ рабочий. Проверен 15.10.2026 17:05')
    end

    it 'is red and says what to do when it is missing' do
      state = described_class.new(key_status: { effective_configured: false, health: {} })

      expect(state).to have_attributes(key_state: 'missing', key_text: 'Не задан', key_tone: 'ruby', key_set?: false)
      expect(state.key_note).to eq('Ключ не задан. Без него ИИ-агенты не отвечают.')
    end

    it 'is amber while it was not checked' do
      state = described_class.new(key_status: { effective_configured: true, health: {} })

      expect(state).to have_attributes(key_text: 'Не проверялся', key_tone: 'amber')
      expect(state.key_note).to include('Проверить ключ и баланс')
    end

    it 'says in plain words that the money on the account is gone' do
      state = described_class.new(key_status: { effective_configured: true, health: { status: 'credits_exhausted', error: 'No credits' } })

      expect(state).to have_attributes(key_text: 'Деньги на счёте закончились', key_tone: 'ruby')
      expect(state.key_note).to eq('No credits')
    end
  end

  describe 'the balance' do
    it 'is written in dollars' do
      expect(state.balance_text).to eq('$12,50 осталось')
    end

    it 'says the limit of the key when there is one' do
      health[:key] = { limit: '50', limit_remaining: '12.5' }

      expect(state.balance_note).to eq('Лимит ключа: $50,00, осталось $12,50.')
    end

    it 'says the balance is unknown and what is needed to see it' do
      health[:credits] = { status: 'management_key_required' }

      expect(state.balance_text).to eq('Баланс неизвестен')
      expect(state.balance_note).to include('добавьте ключ для проверки баланса')
    end
  end

  describe 'the spend of the last day' do
    it 'is written in dollars, with the number of requests in Russian' do
      expect(state.spend_text).to eq('$0,42')
      expect(state.spend_note).to eq('21 запрос, ошибок: 1')
    end

    it 'is not written as zero when it is only below a cent' do
      runtime[:estimated_cost] = 0.002

      expect(state.spend_text).to eq('< $0,01')
    end
  end

  describe 'the catalog' do
    it 'says when it was loaded and how many models it has' do
      expect(state).to be_catalog_loaded
      expect(state.catalog_text).to eq('Загружен 15.10.2026 17:05')
      expect(state.catalog_note).to eq('311 моделей')
    end

    it 'says it is not loaded while the built-in list is in use' do
      catalog.merge!(using_fallback: true, last_refreshed_at: nil, total_models: 170)

      expect(state).not_to be_catalog_loaded
      expect(state.catalog_text).to eq('Не загружен')
      expect(state.catalog_note).to include('встроенный список платформы (170)')
    end

    it 'passes the error of the last refresh on' do
      catalog[:last_refresh_error] = 'HTTP 401'

      expect(state.catalog_error).to eq('HTTP 401')
    end
  end

  it 'reads an empty diagnostics without failing' do
    state = described_class.new({})

    expect(state.key_text).to eq('Не задан')
    expect(state.spend_text).to eq('$0,00')
    expect(state.catalog_text).to eq('Не загружен')
  end
end
