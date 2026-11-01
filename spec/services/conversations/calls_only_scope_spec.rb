# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::CallsOnlyScope do
  let(:account) { create(:account) }
  let(:text_inbox) { create(:inbox, account: account) }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).reload.inbox }

  let!(:text_only_conversation) do
    create(
      :conversation,
      account: account,
      inbox: text_inbox,
      additional_attributes: { 'browser_language' => 'ru' }
    ).tap do |conversation|
      create(:message, account: account, inbox: text_inbox, conversation: conversation, content: 'Здравствуйте, можно записаться?')
    end
  end

  let!(:telephony_session_conversation) do
    create(:conversation, account: account, inbox: text_inbox).tap do |conversation|
      create(:telephony_call_session, account: account, conversation: conversation, provider: 'wazo')
    end
  end

  let!(:whatsapp_cloud_call_conversation) do
    create(:call, account: account).conversation
  end

  let!(:telegram_personal_call_conversation) do
    create(:conversation, account: account, inbox: text_inbox).tap do |conversation|
      now = Time.current
      insert_sql = <<~SQL.squish
        INSERT INTO calls
          (account_id, inbox_id, conversation_id, contact_id, provider, provider_call_id, direction, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      sql = ActiveRecord::Base.sanitize_sql_array(
        [
          insert_sql,
          account.id,
          conversation.inbox_id,
          conversation.id,
          conversation.contact_id,
          2,
          "tg-personal-call-#{SecureRandom.hex(6)}",
          0,
          'completed',
          now,
          now
        ]
      )
      ActiveRecord::Base.connection.execute(sql)
    end
  end

  let!(:voice_inbox_conversation) do
    create(:conversation, account: account, inbox: voice_inbox)
  end

  let!(:whatsapp_web_call_conversation) do
    create(
      :conversation,
      account: account,
      inbox: text_inbox,
      additional_attributes: {
        'call_status' => 'terminate',
        'call_provider' => 'whatsapp_web',
        'call_direction' => 'incoming'
      }
    )
  end

  let!(:empty_string_call_attrs_conversation) do
    create(
      :conversation,
      account: account,
      inbox: text_inbox,
      additional_attributes: {
        'call_status' => '',
        'call_provider' => '',
        'call_direction' => ''
      }
    )
  end

  describe '.apply' do
    it 'returns conversations across all call channels and excludes text-only conversations' do
      matched_ids = described_class.apply(account.conversations).pluck(:id)

      expect(matched_ids).to contain_exactly(
        telephony_session_conversation.id,
        whatsapp_cloud_call_conversation.id,
        telegram_personal_call_conversation.id,
        voice_inbox_conversation.id,
        whatsapp_web_call_conversation.id
      )
      expect(matched_ids).not_to include(
        text_only_conversation.id,
        empty_string_call_attrs_conversation.id
      )
    end

    it 'treats empty-string call_* JSONB attributes as non-call across account-scoped SQL, fallback SQL, and Ruby helpers' do
      candidate_ids = [
        whatsapp_web_call_conversation.id,
        empty_string_call_attrs_conversation.id
      ]

      scoped_ids = described_class.apply(
        account.conversations.where(id: candidate_ids),
        account_id: account.id
      ).pluck(:id)
      unscoped_relation = Conversation.where(id: candidate_ids)
      expect(unscoped_relation.where_values_hash).not_to have_key('account_id')
      fallback_ids = described_class.apply(unscoped_relation).pluck(:id)
      preloaded_ids = described_class.conversation_ids_with_calls(
        account_id: account.id,
        conversations: [whatsapp_web_call_conversation, empty_string_call_attrs_conversation]
      )

      expect(scoped_ids).to eq([whatsapp_web_call_conversation.id])
      expect(fallback_ids).to eq([whatsapp_web_call_conversation.id])
      expect(preloaded_ids).to contain_exactly(whatsapp_web_call_conversation.id)
      expect(described_class.conversation_has_calls?(empty_string_call_attrs_conversation)).to be(false)
    end

    it 'isolates single-tenant call subqueries by account_id without leaking other accounts' do
      other_account = create(:account)
      other_call = create(:call, account: other_account)

      matched_ids = described_class.apply(
        account.conversations,
        account_id: account.id
      ).pluck(:id)

      expect(matched_ids).not_to include(other_call.conversation_id)
    end

    it 'does not duplicate a conversation that has multiple call records' do
      binding = Telephony::NumberBinding.find_by!(inbox: text_inbox)
      create(:telephony_call_session, account: account, conversation: telephony_session_conversation,
                                      number_binding: binding, provider: 'beeline')
      create(:telephony_call_session, account: account, conversation: telephony_session_conversation,
                                      number_binding: binding, provider: 'sipuni')

      matched_ids = described_class.apply(account.conversations.where(id: telephony_session_conversation.id)).pluck(:id)

      expect(matched_ids).to eq([telephony_session_conversation.id])
    end
  end

  describe '.conversation_ids_with_calls' do
    it 'preloads call conversation ids across preloaded and unloaded associations without false positives' do
      preloaded_voice = Conversation.includes(:inbox).find(voice_inbox_conversation.id)
      unloaded_voice = Conversation.find(voice_inbox_conversation.id)

      ids = described_class.conversation_ids_with_calls(
        account_id: account.id,
        conversations: [
          text_only_conversation,
          telephony_session_conversation,
          whatsapp_cloud_call_conversation,
          telegram_personal_call_conversation,
          preloaded_voice,
          unloaded_voice,
          whatsapp_web_call_conversation
        ]
      )

      expect(ids).to contain_exactly(
        telephony_session_conversation.id,
        whatsapp_cloud_call_conversation.id,
        telegram_personal_call_conversation.id,
        voice_inbox_conversation.id,
        whatsapp_web_call_conversation.id
      )
    end
  end

  describe '.conversation_has_calls? and .any_conversation_has_calls?' do
    it 'detects whether an individual conversation or thread link set has calls' do
      expect(described_class.conversation_has_calls?(text_only_conversation)).to be(false)
      expect(described_class.conversation_has_calls?(telephony_session_conversation)).to be(true)
      expect(
        described_class.any_conversation_has_calls?(
          account_id: account.id,
          conversations: [text_only_conversation, whatsapp_web_call_conversation]
        )
      ).to be(true)
      expect(
        described_class.any_conversation_has_calls?(
          account_id: account.id,
          conversations: [text_only_conversation]
        )
      ).to be(false)
    end
  end
end
