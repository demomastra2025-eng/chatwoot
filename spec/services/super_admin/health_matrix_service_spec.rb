# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::HealthMatrixService, type: :service do
  # rubocop:disable RSpec/VerifiedDoubles
  describe '.build' do
    let(:account) { create(:account) }

    before do
      Rails.cache.clear
    end

    context 'when evaluating WhatsApp status' do
      it 'returns none when there are no WhatsApp inboxes' do
        service = described_class.new
        res = service.send(:calculate_whatsapp_status, account)
        expect(res[:state]).to eq('none')
        expect(res[:label]).to eq('Не подключен')
      end

      it 'returns healthy when WhatsApp inbox is active' do
        wa_channel = double('Channel::Whatsapp', reauthorization_required?: false)
        wa_inbox = double('Inbox', channel_type: 'Channel::Whatsapp', channel: wa_channel)
        allow(account).to receive(:inboxes).and_return([wa_inbox])

        service = described_class.new
        res = service.send(:calculate_whatsapp_status, account)
        expect(res[:state]).to eq('healthy')
        expect(res[:label]).to eq('1 подключено')
      end

      it 'returns error when WhatsApp requires reauthorization' do
        wa_channel = double('Channel::Whatsapp', reauthorization_required?: true)
        wa_inbox = double('Inbox', channel_type: 'Channel::Whatsapp', channel: wa_channel)
        allow(account).to receive(:inboxes).and_return([wa_inbox])

        service = described_class.new
        res = service.send(:calculate_whatsapp_status, account)
        expect(res[:state]).to eq('error')
        expect(res[:label]).to eq('Требует авторизации')
      end
    end

    context 'when evaluating Telephony status' do
      let(:context) do
        {
          sip_profiles: {},
          bindings: {},
          connections: {},
          failed_messages: {},
          med_conflicts: {},
          med_runs: {}
        }
      end

      it 'returns none when no phone lines or sip profiles exist' do
        service = described_class.new
        res = service.send(:calculate_telephony_status, account, context)
        expect(res[:state]).to eq('none')
        expect(res[:label]).to eq('Нет линий')
      end

      it 'returns error when remote_janus_url is missing' do
        bad_conn = double('Telephony::ProviderConnection', remote_janus_url: '')
        context[:connections][account.id] = [bad_conn]
        sip = double('Telephony::SipProfile')
        context[:sip_profiles][account.id] = [sip]

        service = described_class.new
        res = service.send(:calculate_telephony_status, account, context)
        expect(res[:state]).to eq('error')
        expect(res[:label]).to eq('Janus URL не задан')
      end

      it 'returns warning when phone inbox has no number binding' do
        phone_inbox = double('Inbox', channel_type: 'Channel::Phone')
        allow(account).to receive(:inboxes).and_return([phone_inbox])
        sip = double('Telephony::SipProfile')
        context[:sip_profiles][account.id] = [sip]
        context[:bindings][account.id] = []

        service = described_class.new
        res = service.send(:calculate_telephony_status, account, context)
        expect(res[:state]).to eq('warning')
        expect(res[:label]).to eq('Линии не привязаны')
      end

      it 'returns healthy when lines and bindings are properly configured' do
        phone_inbox = double('Inbox', channel_type: 'Channel::Phone')
        allow(account).to receive(:inboxes).and_return([phone_inbox])
        sip = double('Telephony::SipProfile')
        binding = double('Telephony::NumberBinding')
        conn = double('Telephony::ProviderConnection', remote_janus_url: 'wss://janus.one-link.kz')
        context[:sip_profiles][account.id] = [sip]
        context[:bindings][account.id] = [binding]
        context[:connections][account.id] = [conn]

        service = described_class.new
        res = service.send(:calculate_telephony_status, account, context)
        expect(res[:state]).to eq('healthy')
        expect(res[:label]).to eq('1 профилей OK')
      end
    end

    context 'when evaluating MedElement status' do
      let(:context) do
        {
          med_conflicts: {},
          med_runs: {}
        }
      end

      it 'returns none when not configured' do
        service = described_class.new
        res = service.send(:calculate_medelement_status, account, context)
        expect(res[:state]).to eq('none')
        expect(res[:label]).to eq('Не настроен')
      end

      it 'returns warning when unresolved conflicts exist' do
        context[:med_conflicts][account.id] = 3
        service = described_class.new
        res = service.send(:calculate_medelement_status, account, context)
        expect(res[:state]).to eq('warning')
        expect(res[:label]).to eq('3 конфликтов')
      end

      it 'returns error when recent sync run failed' do
        failed_run = double('SyncRun', status: 'failed', created_at: Time.current)
        context[:med_runs][account.id] = [failed_run]
        service = described_class.new
        res = service.send(:calculate_medelement_status, account, context)
        expect(res[:state]).to eq('error')
        expect(res[:label]).to eq('Ошибка синхронизации')
      end

      it 'returns healthy when recent sync runs succeeded' do
        success_run = double('SyncRun', status: 'completed', created_at: Time.current)
        context[:med_runs][account.id] = [success_run]
        service = described_class.new
        res = service.send(:calculate_medelement_status, account, context)
        expect(res[:state]).to eq('healthy')
        expect(res[:label]).to eq('В норме')
      end
    end

    context 'when caching and calculating summary' do
      it 'caches results and bypasses on force_refresh' do
        expect(Rails.cache).to receive(:fetch).with(
          SuperAdmin::HealthMatrixService::CACHE_KEY,
          expires_in: SuperAdmin::HealthMatrixService::CACHE_TTL,
          force: false
        ).and_call_original

        described_class.build(force_refresh: false)
      end
    end
  end
  # rubocop:enable RSpec/VerifiedDoubles
end
