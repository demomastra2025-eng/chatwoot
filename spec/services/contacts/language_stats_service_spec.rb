# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Contacts::LanguageStatsService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

  def add_incoming_message(content, content_type: :text, content_attributes: {}, private_msg: false)
    conversation.messages.create!(
      account: account,
      inbox: inbox,
      sender: contact,
      message_type: :incoming,
      private: private_msg,
      content_type: content_type,
      content: content,
      content_attributes: content_attributes
    )
  end

  describe 'automatic programmatic detection on incoming messages' do
    it 'detects 100% Russian even when a Kazakh doctor name or medical acronym is mentioned' do
      add_incoming_message('Здравствуйте! Запишите меня пожалуйста завтра на УЗИ к Әмин Әйгерім.')

      contact.reload
      expect(contact.client_language).to eq('ru')
      expect(contact.client_language_confidence).to eq(100)
      expect(contact.client_language_breakdown).to eq([{ 'code' => 'ru', 'percentage' => 100 }])
    end

    it 'detects 100% Kazakh even with shared Cyrillic medical loanwords and standalone specialty reply' do
      add_incoming_message('Сәлеметсіз бе, ертең гинекологқа скрининг пен анализ тапсыруға бола ма?')
      add_incoming_message('Гинеколог')

      contact.reload
      expect(contact.client_language).to eq('kk')
      expect(contact.client_language_confidence).to eq(100)
      expect(contact.client_language_breakdown).to eq([{ 'code' => 'kk', 'percentage' => 100 }])
    end

    it 'detects 100% Kazakh when typed on a Russian keyboard without special letters' do
      add_incoming_message('Саламатсыз ба, ертен даригерге жазылуга бола ма, багасы канша турады?')

      contact.reload
      expect(contact.client_language).to eq('kk')
      expect(contact.client_language_breakdown).to eq([{ 'code' => 'kk', 'percentage' => 100 }])
    end

    it 'computes normalized percentage breakdown summing to 100% for bilingual Russian + Kazakh contacts' do
      add_incoming_message('Здравствуйте, подскажите пожалуйста сколько стоит консультация сегодня?')
      add_incoming_message('Можно записаться на завтра утром к врачу?')
      add_incoming_message('Сәлеметсіз бе, ертең уақыт бар ма?')

      contact.reload
      breakdown = contact.client_language_breakdown
      expect(breakdown.map { |row| row['code'] }).to eq(%w[ru kk])
      expect(breakdown.sum { |row| row['percentage'] }).to eq(100)
      expect(breakdown.first['percentage']).to be_between(60, 80)
      expect(breakdown.second['percentage']).to be_between(20, 40)
      expect(contact.client_language).to eq('ru')
      expect(contact.client_language_confidence).to eq(breakdown.first['percentage'])
    end

    it 'ignores system call status content and operator speech while scoring client call turns' do
      add_incoming_message(
        'Входящий звонок',
        content_type: :voice_call,
        content_attributes: {
          'data' => {
            'external_call_ref' => 'call-999',
            'transcript_items' => [
              { 'speaker' => 'operator', 'text' => 'Здравствуйте, клиника Смагул Дент, слушаю вас!' },
              { 'speaker' => 'client', 'text' => 'Сәлеметсіз бе, ертең сағат онға тіс дәрігеріне жазылайын деп едім' }
            ]
          }
        }
      )

      contact.reload
      expect(contact.client_language).to eq('kk')
      expect(contact.client_language_breakdown).to eq([{ 'code' => 'kk', 'percentage' => 100 }])
    end

    it 'detects Kazakh Latin with diacritics and ignores standalone patient names/cities/addresses' do
      expect(
        described_class.analyze_texts(['Sälemetsiz be, erteñ därigerge jazylğym keledi'])
      ).to eq([{ 'code' => 'kk', 'percentage' => 100 }])

      expect(
        described_class.analyze_texts(['Ахметова Айгуль Сериковна', 'Алматы', 'Кенесары 40'])
      ).to eq([])

      expect(
        described_class.analyze_texts(['Сәлеметсіз бе', 'Ахметова Айгуль', 'Алматы', 'Кенесары 40'])
      ).to eq([{ 'code' => 'kk', 'percentage' => 100 }])
    end

    it 'extracts client turns from outbound voice_call messages and AI Voice final_items' do
      conversation.messages.create!(
        account: account,
        inbox: inbox,
        message_type: :outgoing,
        content_type: :voice_call,
        content: 'Исходящий звонок',
        content_attributes: {
          'data' => {
            'external_call_ref' => 'outbound-call-1',
            'transcript_items' => [
              { 'speaker' => 'operator', 'text' => 'Здравствуйте, клиника Смагул Дент' },
              { 'speaker' => 'клиент', 'text' => 'Сәлеметсіз бе, ертең уақыт бар ма?' }
            ]
          }
        }
      )

      described_class.refresh!(contact)
      contact.reload
      expect(contact.client_language).to eq('kk')
      expect(contact.client_language_breakdown).to eq([{ 'code' => 'kk', 'percentage' => 100 }])
    end

    it 'leaves language empty when contact only sent digits, IIN, or missed calls without speech' do
      add_incoming_message('900515300123')
      add_incoming_message(
        'Пропущенный звонок',
        content_type: :voice_call,
        content_attributes: { 'data' => { 'external_call_ref' => 'missed-1', 'transcript_items' => [] } }
      )

      contact.reload
      expect(contact.client_language).to be_nil
      expect(contact.client_language_breakdown).to eq([])
    end
  end
end
