# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::MonthlyAiUsageService do
  let(:account) { create(:account, custom_attributes: { 'existing_flag' => 'kept' }) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:service) { described_class.new(account) }

  describe '#record_ai_dialog_reply!' do
    it 'counts up to 20 AI replies within 24 hours in one contact as 1 billable dialog' do
      base_time = Time.utc(2026, 10, 15, 5, 0, 0)

      expect(service.record_ai_dialog_reply!(conversation, message_id: 101, at: base_time)).to eq(:new_dialog)
      19.times do |idx|
        result = service.record_ai_dialog_reply!(conversation, message_id: 102 + idx, at: base_time + (idx + 1).minutes)
        expect(result).to eq(:existing_dialog)
      end

      expect(service.ai_dialogs_consumed(at: base_time)).to eq(1)
      expect(account.reload.custom_attributes['existing_flag']).to eq('kept')
    end

    it 'is idempotent when retried with the same message_id and preserves atomic bucket increments across token usage writes' do
      base_time = Time.utc(2026, 10, 15, 5, 0, 0)
      stale_account = Account.find(account.id)

      expect(service.record_ai_dialog_reply!(conversation, message_id: 9001, at: base_time)).to eq(:new_dialog)
      expect(service.record_ai_dialog_reply!(conversation, message_id: 9001, at: base_time + 1.minute)).to eq(:duplicate)
      stale_account.increment_token_usage(420)

      fresh = account.reload
      expect(described_class.new(fresh).ai_dialogs_consumed(at: base_time)).to eq(1)
      expect(fresh.captain_tokens_usage).to eq(420)
    end

    it 'opens a new billable dialog on the 21st AI reply within 24 hours' do
      base_time = Time.utc(2026, 10, 15, 5, 0, 0)

      20.times { |idx| service.record_ai_dialog_reply!(conversation, message_id: 200 + idx, at: base_time + idx.minutes) }
      expect(service.ai_dialogs_consumed(at: base_time)).to eq(1)

      expect(service.record_ai_dialog_reply!(conversation, message_id: 300, at: base_time + 30.minutes)).to eq(:new_dialog)
      expect(service.ai_dialogs_consumed(at: base_time)).to eq(2)
    end

    it 'opens a new billable dialog once 24 hours have elapsed since window start' do
      base_time = Time.utc(2026, 10, 15, 5, 0, 0)

      service.record_ai_dialog_reply!(conversation, message_id: 401, at: base_time)
      service.record_ai_dialog_reply!(conversation, message_id: 402, at: base_time + 23.hours + 59.minutes)
      expect(service.ai_dialogs_consumed(at: base_time)).to eq(1)

      expect(service.record_ai_dialog_reply!(conversation, message_id: 403, at: base_time + 24.hours)).to eq(:new_dialog)
      expect(service.ai_dialogs_consumed(at: base_time + 24.hours)).to eq(2)
    end

    it 'buckets monthly usage in Asia/Almaty (UTC+5) timezone and atomically prunes only buckets older than 6 months' do
      oct_almaty = Time.utc(2026, 10, 31, 18, 30, 0)
      nov_almaty = Time.utc(2026, 10, 31, 19, 30, 0)

      conv_oct = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      conv_nov = create(:conversation, account: account, inbox: inbox)

      service.record_ai_dialog_reply!(conv_oct, message_id: 801, at: oct_almaty)
      service.record_ai_dialog_reply!(conv_nov, message_id: 802, at: nov_almaty)

      expect(service.period_key(oct_almaty)).to eq('2026-10')
      expect(service.period_key(nov_almaty)).to eq('2026-11')
      expect(service.ai_dialogs_consumed(at: oct_almaty)).to eq(1)
      expect(service.ai_dialogs_consumed(at: nov_almaty)).to eq(1)

      seeded = %w[2026-04 2026-05 2026-06 2026-07 2026-08 2026-09 2026-10].index_with(3)
      account.update!(custom_attributes: account.custom_attributes.merge(described_class::AI_DIALOGS_MONTHLY_KEY => seeded))
      conv_extra = create(:conversation, account: account, inbox: inbox)
      service.record_ai_dialog_reply!(conv_extra, message_id: 803, at: nov_almaty)

      buckets = account.reload.custom_attributes[described_class::AI_DIALOGS_MONTHLY_KEY]
      expect(buckets.keys.sort).to eq(%w[2026-06 2026-07 2026-08 2026-09 2026-10 2026-11])
      expect(buckets['2026-11']).to eq(1)
    end
  end

  describe 'contact identity and durable event accounting' do
    let(:now) { Time.utc(2026, 10, 20, 8) }

    it 'shares the 20-reply window across channels and reopened conversations of one contact' do
      whatsapp = create(:conversation, account: account, contact: contact, inbox: shared_phone_cloud_inbox(account))
      other = create(:conversation, account: account, contact: contact, inbox: create(:channel_telegram, account: account).inbox)
      20.times do |idx|
        service.record_ai_dialog_reply!(idx.even? ? whatsapp : other, message_id: 1000 + idx, at: now + idx.minutes)
      end
      expect(service.ai_dialogs_consumed(at: now)).to eq(1)
      expect(service.record_ai_dialog_reply!(other, message_id: 1100, at: now + 30.minutes)).to eq(:new_dialog)
      expect(service.ai_dialogs_consumed(at: now)).to eq(2)
      expect(Accounts::AiDialogState.find_by!(contact_id: contact.id).state['replies_count']).to eq(1)
    end

    it 'does not merge two people using the same family phone' do
      phone = SharedPhoneHelpers::FAMILY_PHONE
      contact.update!(phone_number: phone)
      dependent = shared_phone_card(account, contact, phone: phone)
      other = create(:conversation, account: account, contact: dependent, inbox: inbox)

      service.record_ai_dialog_reply!(conversation, message_id: 1201, at: now)
      service.record_ai_dialog_reply!(other, message_id: 1202, at: now)

      expect(service.ai_dialogs_consumed(at: now)).to eq(2)
      expect(Accounts::AiDialogState.find_by!(contact_id: dependent.id).state['replies_count']).to eq(1)
    end

    it 'retains the window when an old contact form writes its stale additional attributes' do
      stale = Contact.find(contact.id)
      service.record_ai_dialog_reply!(conversation, message_id: 1251, at: now)
      stale.update!(additional_attributes: { 'city' => 'Synthetic city' })
      expect(service.record_ai_dialog_reply!(conversation, message_id: 1252, at: now + 1.minute)).to eq(:existing_dialog)
      expect(service.ai_dialogs_consumed(at: now)).to eq(1)
    end

    it 'rejects a conversation from another account and never modifies its window or counter' do
      foreign = create(:conversation)
      expect(service.record_ai_dialog_reply!(foreign, message_id: 1301, at: now)).to be(false)
      expect(Accounts::AiUsageEvent.count).to eq(0)
      expect(foreign.contact.reload.additional_attributes).not_to have_key(described_class::CONVERSATION_WINDOW_KEY)
    end

    it 'keeps source deduplication after multiple 20-reply windows and a month rollover' do
      41.times { |idx| service.record_ai_dialog_reply!(conversation, message_id: 1400 + idx, at: now + idx.minutes) }
      expect(service.record_ai_dialog_reply!(conversation, message_id: 1400, at: now + 32.days)).to eq(:duplicate)
      expect(service.ai_dialogs_consumed(at: now)).to eq(3)
      expect(service.ai_dialogs_consumed(at: now + 32.days)).to eq(0)
    end

    it 'adopts old per-channel windows and message ids without recounting historical dialogs' do
      attrs = { described_class::CONVERSATION_WINDOW_KEY => {
        'started_at' => now.iso8601, 'replies_count' => 2, 'message_ids' => %w[1500 1501]
      } }
      conversation.update!(additional_attributes: attrs)
      account.update!(custom_attributes: account.custom_attributes.merge(described_class::AI_DIALOGS_MONTHLY_KEY => { '2026-10' => 1 }))
      other = create(:conversation, account: account, contact: contact, inbox: create(:inbox, account: account))

      expect(service.record_ai_dialog_reply!(other, message_id: 1500, at: now + 1.minute)).to eq(:duplicate)
      expect(service.record_ai_dialog_reply!(other, message_id: 1502, at: now + 2.minutes)).to eq(:existing_dialog)
      expect(service.ai_dialogs_consumed(at: now)).to eq(1)
      expect(Accounts::AiDialogState.find_by!(contact_id: contact.id).state['replies_count']).to eq(3)
      expect(conversation.reload.additional_attributes).to eq(attrs)
    end

    it 'rolls back the source event and window when the monthly increment fails, and retries once' do
      allow(service).to receive(:increment_monthly_bucket!).and_raise(ActiveRecord::StatementInvalid, 'injected failure')
      expect { service.record_ai_dialog_reply!(conversation, message_id: 1600, at: now) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Accounts::AiUsageEvent.count).to eq(0)
      expect(Accounts::AiDialogState.where(contact_id: contact.id)).not_to exist

      allow(service).to receive(:increment_monthly_bucket!).and_call_original
      expect(service.record_ai_dialog_reply!(conversation, message_id: 1600, at: now)).to eq(:new_dialog)
      expect(described_class.new(account.reload).ai_dialogs_consumed(at: now)).to eq(1)
    end
  end

  describe '#record_call_analysis!' do
    let(:now) { Time.utc(2026, 10, 20, 8, 0, 0) }
    let(:call) { create(:call, account: account) }

    it 'ignores unanswered calls, non-finite durations, and calls shorter than 5 seconds' do
      invalid_samples = [
        [4.9, false], [0, false], [nil, false], [Float::INFINITY, false], [Float::NAN, false], [45, true]
      ]
      results = invalid_samples.map { |dur, unans| service.record_call_analysis!(call: call, duration_seconds: dur, unanswered: unans, at: now) }

      expect(results).to all(be(false))
      expect(service.call_analysis_seconds_consumed(at: now)).to eq(0)
      expect(service.call_analysis_minutes_consumed(at: now)).to eq(0)
    end

    it 'accumulates exact seconds across calls before converting to monthly minutes' do
      expect(service.record_call_analysis!(call: call, duration_seconds: 30, unanswered: false, at: now)).to be(true)
      expect(service.record_call_analysis!(call: create(:call, account: account), duration_seconds: 30, unanswered: false, at: now)).to be(true)

      expect(service.call_analysis_seconds_consumed(at: now)).to eq(60)
      expect(service.call_analysis_minutes_consumed(at: now)).to eq(1)

      expect(service.record_call_analysis!(call: create(:call, account: account), duration_seconds: 5, unanswered: false, at: now)).to be(true)
      expect(service.call_analysis_seconds_consumed(at: now)).to eq(65)
      expect(service.call_analysis_minutes_consumed(at: now)).to eq(2)
    end

    it 'deduplicates the same call source forever and isolates other accounts' do
      expect(service.record_call_analysis!(call: call, duration_seconds: 31, at: now)).to be(true)
      expect(service.record_call_analysis!(call: call, duration_seconds: 31, at: now + 32.days)).to be(false)
      foreign = create(:call)
      expect(service.record_call_analysis!(call: foreign, duration_seconds: 31, at: now)).to be(false)
      expect(service.call_analysis_seconds_consumed(at: now)).to eq(31)
      expect(service.call_analysis_seconds_consumed(at: now + 32.days)).to eq(0)
    end

    it 'rolls back the event when its counter fails and can safely retry' do
      allow(service).to receive(:increment_monthly_bucket!).and_raise(ActiveRecord::StatementInvalid, 'injected failure')
      expect { service.record_call_analysis!(call: call, duration_seconds: 31, at: now) }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Accounts::AiUsageEvent.count).to eq(0)
      allow(service).to receive(:increment_monthly_bucket!).and_call_original
      expect(service.record_call_analysis!(call: call, duration_seconds: 31, at: now)).to be(true)
      expect(described_class.new(account.reload).call_analysis_seconds_consumed(at: now)).to eq(31)
    end
  end
end
