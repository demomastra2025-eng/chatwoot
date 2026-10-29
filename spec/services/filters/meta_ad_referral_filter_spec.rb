# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Filters::MetaAdReferralFilter do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let(:secondary_inbox) { create(:inbox, account: account, enable_auto_assignment: false) }

  before do
    create(:inbox_member, user: admin, inbox: inbox)
    create(:inbox_member, user: admin, inbox: secondary_inbox)
    create(:inbox_member, user: agent, inbox: inbox)
    create(:inbox_member, user: agent, inbox: secondary_inbox)
  end

  def condition(attribute_key, filter_operator, values = [], query_operator: nil)
    {
      attribute_key: attribute_key,
      filter_operator: filter_operator,
      values: values,
      query_operator: query_operator
    }.with_indifferent_access
  end

  def create_referral(conversation:, source_id: '238001', ad_id: 'ad_001', headline: 'МРТ + невролог', **overrides)
    create(
      :meta_ad_referral,
      {
        account: conversation.account,
        inbox: conversation.inbox,
        contact: conversation.contact,
        conversation: conversation,
        communication_thread: conversation.communication_thread,
        source_id: source_id,
        ad_id: ad_id,
        headline: headline
      }.merge(overrides)
    )
  end

  describe 'Conversations::FilterService' do
    let!(:mri_conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }
    let!(:dental_conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }
    let!(:organic_conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }

    before do
      create_referral(conversation: mri_conversation, source_id: '238001', ad_id: '990001', headline: 'МРТ головного мозга + невролог')
      create_referral(
        conversation: mri_conversation,
        provider_message_id: 'wamid.second-click',
        source_id: '238001',
        ad_id: '990001',
        headline: 'МРТ головного мозга + невролог'
      )
      create_referral(conversation: dental_conversation, source_id: '238002', ad_id: '990002', headline: 'Имплантация зубов')
    end

    def filter_conversations(payload)
      Conversations::FilterService.new({ payload: payload, page: 1 }, admin, account).perform
    end

    it 'filters conversations by meta_ad_referral equal_to true and false without duplicating multi-referral rows' do
      ad_result = filter_conversations([condition('meta_ad_referral', 'equal_to', ['true'])])
      organic_result = filter_conversations([condition('meta_ad_referral', 'equal_to', ['false'])])

      expect(ad_result[:conversations].map(&:id)).to contain_exactly(mri_conversation.id, dental_conversation.id)
      expect(ad_result[:count][:all_count]).to eq(2)
      expect(organic_result[:conversations].map(&:id)).to contain_exactly(organic_conversation.id)
    end

    it 'filters conversations by meta_ad_referral is_present, is_not_present, and not_equal_to' do
      present = filter_conversations([condition('meta_ad_referral', 'is_present')])
      absent = filter_conversations([condition('meta_ad_referral', 'is_not_present')])
      not_true = filter_conversations([condition('meta_ad_referral', 'not_equal_to', ['true'])])

      expect(present[:conversations].map(&:id)).to contain_exactly(mri_conversation.id, dental_conversation.id)
      expect(absent[:conversations].map(&:id)).to contain_exactly(organic_conversation.id)
      expect(not_true[:conversations].map(&:id)).to contain_exactly(organic_conversation.id)
    end

    it 'raises InvalidValue when meta_ad_referral receives a non-boolean value' do
      expect do
        filter_conversations([condition('meta_ad_referral', 'equal_to', ['maybe'])])
      end.to raise_error(CustomExceptions::CustomFilter::InvalidValue)
    end

    it 'filters conversations by meta_ad_source_id across source_id, ad_id, and Cyrillic headline' do
      by_source = filter_conversations([condition('meta_ad_source_id', 'equal_to', ['238001'])])
      by_ad_id = filter_conversations([condition('meta_ad_source_id', 'equal_to', ['990002'])])
      by_headline = filter_conversations([condition('meta_ad_source_id', 'contains', ['невролог'])])
      excluding_mri = filter_conversations([condition('meta_ad_source_id', 'does_not_contain', ['мрт'])])

      expect(by_source[:conversations].map(&:id)).to contain_exactly(mri_conversation.id)
      expect(by_ad_id[:conversations].map(&:id)).to contain_exactly(dental_conversation.id)
      expect(by_headline[:conversations].map(&:id)).to contain_exactly(mri_conversation.id)
      expect(excluding_mri[:conversations].map(&:id)).to contain_exactly(dental_conversation.id, organic_conversation.id)
    end
  end

  describe 'CommunicationThreads::FilterService' do
    let!(:mri_whatsapp_conv) { create(:conversation, account: account, inbox: inbox, status: :open) }
    let!(:mri_secondary_conv) do
      create(:conversation, account: account, inbox: secondary_inbox, contact: mri_whatsapp_conv.contact, status: :pending)
    end
    let!(:dental_conv) { create(:conversation, account: account, inbox: inbox, status: :open) }
    let!(:organic_conv) { create(:conversation, account: account, inbox: inbox, status: :open) }

    let(:mri_thread) { mri_whatsapp_conv.reload.communication_thread }
    let(:dental_thread) { dental_conv.reload.communication_thread }
    let(:organic_thread) { organic_conv.reload.communication_thread }

    before do
      account.enable_features!('communication_threads')
      [mri_whatsapp_conv, mri_secondary_conv, dental_conv, organic_conv].each(&:refresh_communication_thread!)
      create_referral(conversation: mri_whatsapp_conv.reload, source_id: '238111', ad_id: '880111', headline: 'МРТ позвоночника')
      create_referral(
        conversation: dental_conv.reload,
        communication_thread: nil,
        source_id: '238222',
        ad_id: '880222',
        headline: 'Чистка зубов'
      )
    end

    def filter_threads(payload, as: agent)
      CommunicationThreads::FilterService.new({ payload: payload, page: 1 }, as, account).perform
    end

    it 'matches and excludes multi-channel communication threads accurately on meta_ad_referral' do
      ad_threads = filter_threads([condition('meta_ad_referral', 'equal_to', ['true'])])
      non_ad_threads = filter_threads([condition('meta_ad_referral', 'equal_to', ['false'])])
      absent_threads = filter_threads([condition('meta_ad_referral', 'is_not_present')])

      expect(ad_threads[:communication_threads].map(&:id)).to contain_exactly(mri_thread.id, dental_thread.id)
      expect(ad_threads[:count][:all_count]).to eq(2)
      expect(non_ad_threads[:communication_threads].map(&:id)).to contain_exactly(organic_thread.id)
      expect(absent_threads[:communication_threads].map(&:id)).to contain_exactly(organic_thread.id)
    end

    it 'intersects meta_ad_referral with sibling channel conditions and filters by meta_ad_source_id' do
      pending_ad = filter_threads([
                                    condition('status', 'equal_to', ['pending'], query_operator: 'AND'),
                                    condition('meta_ad_referral', 'is_present')
                                  ])
      by_headline = filter_threads([condition('meta_ad_source_id', 'contains', ['позвоночник'])])
      without_mri = filter_threads([condition('meta_ad_source_id', 'does_not_contain', ['мрт'])])

      expect(pending_ad[:communication_threads].map(&:id)).to contain_exactly(mri_thread.id)
      expect(by_headline[:communication_threads].map(&:id)).to contain_exactly(mri_thread.id)
      expect(without_mri[:communication_threads].map(&:id)).to contain_exactly(dental_thread.id, organic_thread.id)
    end
  end

  describe 'Contacts::FilterService' do
    let!(:cardio_contact) { create(:contact, account: account, email: 'cardio@example.com') }
    let!(:neuro_contact) { create(:contact, account: account, email: 'neuro@example.com') }
    let!(:organic_contact) { create(:contact, account: account, email: 'organic@example.com') }

    before do
      cardio_conv = create(:conversation, account: account, inbox: inbox, contact: cardio_contact)
      neuro_conv = create(:conversation, account: account, inbox: inbox, contact: neuro_contact)
      create_referral(conversation: cardio_conv, source_id: '550001', ad_id: '770001', headline: 'Чек-ап кардиолога')
      create_referral(
        conversation: cardio_conv,
        provider_message_id: 'wamid.cardio-2',
        source_id: '550001',
        ad_id: '770001',
        headline: 'Чек-ап кардиолога'
      )
      create_referral(conversation: neuro_conv, source_id: '550002', ad_id: '770002', headline: 'Приём невролога')
    end

    def filter_contacts(payload)
      Contacts::FilterService.new(account, admin, { payload: payload, page: 1 }).perform
    end

    it 'filters contacts by meta_ad_referral without duplicating contacts with multiple referrals' do
      ad_contacts = filter_contacts([condition('meta_ad_referral', 'equal_to', ['true'])])
      non_ad_contacts = filter_contacts([condition('meta_ad_referral', 'is_not_present')])

      expect(ad_contacts[:contacts].map(&:id)).to contain_exactly(cardio_contact.id, neuro_contact.id)
      expect(ad_contacts[:count]).to eq(2)
      expect(non_ad_contacts[:contacts].map(&:id)).to contain_exactly(organic_contact.id)
    end

    it 'filters contacts by meta_ad_source_id equal_to, contains, and does_not_contain' do
      by_source = filter_contacts([condition('meta_ad_source_id', 'equal_to', ['550001'])])
      by_headline = filter_contacts([condition('meta_ad_source_id', 'contains', ['невролог'])])
      excluding_cardio = filter_contacts([condition('meta_ad_source_id', 'does_not_contain', ['кардиолог'])])

      expect(by_source[:contacts].map(&:id)).to contain_exactly(cardio_contact.id)
      expect(by_headline[:contacts].map(&:id)).to contain_exactly(neuro_contact.id)
      expect(excluding_cardio[:contacts].map(&:id)).to contain_exactly(neuro_contact.id, organic_contact.id)
    end
  end

  describe 'AutomationRules::ConditionsFilterService' do
    let(:ad_conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:organic_conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:rule) do
      create(
        :automation_rule,
        account: account,
        conditions: [
          { 'attribute_key' => 'meta_ad_referral', 'filter_operator' => 'is_present', 'values' => [], 'query_operator' => 'AND' },
          { 'attribute_key' => 'meta_ad_source_id', 'filter_operator' => 'contains', 'values' => ['МРТ'], 'query_operator' => nil }
        ]
      )
    end

    before do
      create_referral(conversation: ad_conversation, source_id: '238999', headline: 'МРТ со скидкой')
    end

    it 'evaluates meta_ad_referral and meta_ad_source_id conditions cleanly' do
      expect(AutomationRules::ConditionsFilterService.new(rule, ad_conversation).perform).to be(true)
      expect(AutomationRules::ConditionsFilterService.new(rule, organic_conversation).perform).to be(false)
    end
  end
end
