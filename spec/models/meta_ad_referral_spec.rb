# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MetaAdReferral do
  def create_referral(attributes = {})
    account = attributes[:account] || create(:account)
    inbox = attributes[:inbox] || create(:inbox, account: account)

    described_class.create!(
      {
        account: account,
        inbox: inbox,
        provider: 'whatsapp',
        provider_message_id: SecureRandom.uuid,
        received_at: Time.current
      }.merge(attributes)
    )
  end

  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:inbox) }
    it { is_expected.to belong_to(:contact).optional }
    it { is_expected.to belong_to(:conversation).optional }
    it { is_expected.to belong_to(:communication_thread).optional }
    it { is_expected.to belong_to(:message).optional }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:provider) }
    it { is_expected.to validate_presence_of(:provider_message_id) }
    it { is_expected.to validate_presence_of(:received_at) }
  end

  describe 'parent cleanup' do
    it 'is deleted before account deletion' do
      referral = create_referral

      expect { referral.account.destroy! }.to change(described_class, :count).by(-1)
    end

    it 'is deleted before inbox deletion' do
      referral = create_referral

      expect { referral.inbox.destroy! }.to change(described_class, :count).by(-1)
    end

    it 'nullifies optional contact linkage on contact deletion' do
      account = create(:account)
      contact = create(:contact, account: account)
      referral = create_referral(account: account, contact: contact)

      expect { contact.destroy! }.not_to raise_error
      expect(referral.reload.contact_id).to be_nil
    end

    it 'nullifies optional conversation linkage on conversation deletion' do
      conversation = create(:conversation)
      referral = create_referral(account: conversation.account, inbox: conversation.inbox, conversation: conversation)

      expect { conversation.destroy! }.not_to raise_error
      expect(referral.reload.conversation_id).to be_nil
    end

    it 'nullifies optional communication thread linkage on thread deletion' do
      thread = create(:communication_thread)
      inbox = create(:inbox, account: thread.account)
      referral = create_referral(account: thread.account, inbox: inbox, communication_thread: thread)

      expect { thread.destroy! }.not_to raise_error
      expect(referral.reload.communication_thread_id).to be_nil
    end

    it 'nullifies optional message linkage on message deletion' do
      message = create(:message)
      referral = create_referral(account: message.account, inbox: message.inbox, message: message)

      expect { message.destroy! }.not_to raise_error
      expect(referral.reload.message_id).to be_nil
    end
  end
end
