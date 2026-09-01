# frozen_string_literal: true

require 'rails_helper'

require Rails.root.join 'spec/models/concerns/avatarable_shared.rb'

RSpec.describe Contact do
  context 'with validations' do
    it { is_expected.to validate_presence_of(:account_id) }

    it 'rejects an owner from another account' do
      contact = build(:contact, owner: create(:user))

      expect(contact).not_to be_valid
      expect(contact.errors[:owner_id]).to include('must belong to the current account')
    end

    it 'allows unrelated updates when a legacy owner no longer belongs to the account' do
      contact = create(:contact)
      stale_owner = create(:user)
      contact.update_column(:owner_id, stale_owner.id)

      expect { contact.reload.update_labels(['vip']) }.not_to raise_error
      expect(contact.reload.label_list).to contain_exactly('vip')
    end
  end

  context 'with associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:owner).optional }
    it { is_expected.to have_many(:assignment_client_ownerships).dependent(:delete_all) }
    it { is_expected.to have_many(:assignment_quota_usages).dependent(:delete_all) }
    it { is_expected.to have_many(:campaign_deliveries).dependent(:delete_all) }
    it { is_expected.to have_many(:campaign_audience_recipients).dependent(:nullify) }
    it { is_expected.to have_many(:communication_threads).dependent(:destroy) }
    it { is_expected.to have_many(:conversations).dependent(:destroy_async) }
    it { is_expected.to have_many(:meta_ad_referrals).dependent(:nullify) }
    it { is_expected.to have_many(:crm_deals).through(:crm_deal_contacts) }
  end

  describe 'phone identity locking' do
    it 'locks a normalized phone inside the contact save transaction' do
      account = create(:account)
      lock_transaction_states = []
      allow(Contacts::PhoneIdentityLock).to receive(:acquire!).and_wrap_original do |original, **arguments|
        lock_transaction_states << ActiveRecord::Base.connection.transaction_open?
        original.call(**arguments)
      end

      create(:contact, account: account, phone_number: '+77051234567')

      expect(lock_transaction_states).to eq([true])
    end
  end

  describe 'concerns' do
    it_behaves_like 'avatarable'
  end

  context 'when prepare contact attributes before validation' do
    it 'sets email to lowercase' do
      contact = create(:contact, email: 'Test@test.com')
      expect(contact.email).to eq('test@test.com')
      expect(contact.contact_type).to eq('lead')
    end

    it 'sets email to nil when empty string' do
      contact = create(:contact, email: '')
      expect(contact.email).to be_nil
      expect(contact.contact_type).to eq('visitor')
    end

    it 'sets custom_attributes to {} when nil' do
      contact = create(:contact, custom_attributes: nil)
      expect(contact.custom_attributes).to eq({})
    end

    it 'sets custom_attributes to {} when empty string' do
      contact = create(:contact, custom_attributes: '')
      expect(contact.custom_attributes).to eq({})
    end

    it 'sets additional_attributes to {} when nil' do
      contact = create(:contact, additional_attributes: nil)
      expect(contact.additional_attributes).to eq({})
    end

    it 'sets additional_attributes to {} when empty string' do
      contact = create(:contact, additional_attributes: '')
      expect(contact.additional_attributes).to eq({})
    end
  end

  context 'when phone number format' do
    it 'will throw error for existing invalid phone number' do
      contact = create(:contact)
      expect { contact.update!(phone_number: '123456789') }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'updates phone number when adding valid phone number' do
      contact = create(:contact)
      expect(contact.update!(phone_number: '+12312312321')).to be true
      expect(contact.phone_number).to eq '+12312312321'
    end

    it 'normalizes Kazakhstan phone numbers to compact E.164' do
      contact = create(
        :contact,
        phone_number: '87011234567',
        additional_attributes: { country_code: 'KZ' }
      )

      expect(contact.phone_number).to eq '+77011234567'
    end

    it 'normalizes Kazakhstan phone numbers starting with 8 even with formatting characters' do
      contact = create(
        :contact,
        phone_number: '8 (701) 123-45-67',
        additional_attributes: { country_code: 'KZ' }
      )

      expect(contact.phone_number).to eq '+77011234567'
    end

    it 'normalizes formatted phone numbers using the contact country code' do
      contact = create(
        :contact,
        phone_number: '(415) 555-2671',
        additional_attributes: { country_code: 'US' }
      )

      expect(contact.phone_number).to eq '+14155552671'
    end

    it 'does not guess a country when the phone number is local and no country is provided' do
      contact = build(:contact, phone_number: '87011234567')

      expect(contact).not_to be_valid
      expect(contact.errors[:phone_number]).to be_present
    end
  end

  context 'when email format' do
    it 'will throw error for existing invalid email' do
      contact = create(:contact)
      expect { contact.update!(email: '<2324234234') }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'updates email when adding valid email' do
      contact = create(:contact)
      expect(contact.update!(email: 'test@test.com')).to be true
      expect(contact.email).to eq 'test@test.com'
    end
  end

  context 'when city and country code passed in additional attributes' do
    it 'updates location and country code' do
      contact = create(
        :contact,
        additional_attributes: { city: 'New York', country: 'United States', country_code: 'US' }
      )
      expect(contact.location).to eq 'New York'
      expect(contact.country_code).to eq 'US'
    end
  end

  context 'when a contact is created' do
    it 'has contact type "visitor" by default' do
      contact = create(:contact)
      expect(contact.contact_type).to eq 'visitor'
    end

    it 'has contact type "lead" when email is present' do
      contact = create(:contact, email: 'test@test.com')
      expect(contact.contact_type).to eq 'lead'
    end

    it 'has contact type "lead" when contacted through a social channel' do
      contact = create(:contact, additional_attributes: { social_facebook_user_id: '123' })
      expect(contact.contact_type).to eq 'lead'
    end
  end

  context 'when a contact has campaign deliveries' do
    it 'can be deleted without foreign key violations' do
      contact = create(:contact, :with_phone_number)
      campaign = create(:campaign, account: contact.account)
      delivery = create(
        :campaign_delivery,
        campaign: campaign,
        account: contact.account,
        inbox: campaign.inbox,
        contact: contact
      )

      contact.destroy!

      expect(described_class.exists?(contact.id)).to be false
      expect(CampaignDelivery.exists?(delivery.id)).to be false
    end
  end

  context 'when a contact has communication threads' do
    it 'can be deleted without foreign key violations' do
      contact = create(:contact, :with_phone_number)
      thread = create(:communication_thread, account: contact.account, contact: contact)

      contact.destroy!

      expect(described_class.exists?(contact.id)).to be false
      expect(CommunicationThread.exists?(thread.id)).to be false
    end
  end

  context 'when a contact has assignment tracking records' do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:contact) { create(:contact, account: account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
    let(:assignment_policy) { create(:assignment_policy, account: account) }
    let!(:ownership) do
      create(
        :assignment_client_ownership,
        account: account,
        contact: contact,
        user: user,
        assignment_policy: assignment_policy
      )
    end
    let!(:quota_usage) do
      create(
        :assignment_quota_usage,
        account: account,
        contact: contact,
        user: user,
        conversation: conversation,
        assignment_policy: assignment_policy
      )
    end

    it 'deletes the ownership and quota usage with the contact' do
      contact.destroy!

      expect(AssignmentClientOwnership.exists?(ownership.id)).to be false
      expect(AssignmentQuotaUsage.exists?(quota_usage.id)).to be false
    end

    it 'cascades the tracking record deletion when callbacks are bypassed' do
      described_class.where(id: contact.id).delete_all

      expect(AssignmentClientOwnership.exists?(ownership.id)).to be false
      expect(AssignmentQuotaUsage.exists?(quota_usage.id)).to be false
    end
  end

  describe '.resolved_contacts' do
    let(:account) { create(:account) }

    context 'when crm_v2 feature flag is disabled' do
      it 'returns contacts with email, phone_number, or identifier using feature flag value' do
        # Create contacts with different attributes
        contact_with_email = create(:contact, account: account, email: 'test@example.com', name: 'John Doe')
        contact_with_phone = create(:contact, account: account, phone_number: '+1234567890', name: 'Jane Smith')
        contact_with_identifier = create(:contact, account: account, identifier: 'user123', name: 'Bob Wilson')
        contact_without_details = create(:contact, account: account, name: 'Alice Johnson', email: nil, phone_number: nil, identifier: nil)

        resolved = account.contacts.resolved_contacts(use_crm_v2: false)

        expect(resolved).to include(contact_with_email, contact_with_phone, contact_with_identifier)
        expect(resolved).not_to include(contact_without_details)
      end

      it 'returns CRM leads without email, phone_number, or identifier' do
        social_lead = create(:contact, account: account, name: 'Telegram Lead', email: nil, phone_number: nil, identifier: nil,
                                       additional_attributes: { social_telegram_user_id: '8269484707' })
        visitor = create(:contact, account: account, name: 'Anonymous Visitor', email: nil, phone_number: nil, identifier: nil)

        resolved = account.contacts.resolved_contacts(use_crm_v2: false)

        expect(social_lead.contact_type).to eq('lead')
        expect(resolved).to include(social_lead)
        expect(resolved).not_to include(visitor)
      end
    end

    context 'when crm_v2 feature flag is enabled' do
      it 'returns only contacts with contact_type lead' do
        # Contact with email and phone - should be marked as lead
        contact_with_details = create(:contact, account: account, email: 'customer@example.com', phone_number: '+1234567890', name: 'Customer One')
        expect(contact_with_details.contact_type).to eq('lead')

        # Contact without email/phone - should be marked as visitor
        contact_without_details = create(:contact, account: account, name: 'Lead', email: nil, phone_number: nil)
        expect(contact_without_details.contact_type).to eq('visitor')

        # Force set contact_type to lead for testing
        contact_without_details.update!(contact_type: 'lead')

        resolved = account.contacts.resolved_contacts(use_crm_v2: true)

        expect(resolved).to include(contact_with_details)
        expect(resolved).to include(contact_without_details)
      end

      it 'includes all lead contacts regardless of email/phone presence' do
        # Create a lead contact with only name
        lead_contact = create(:contact, account: account, name: 'Test Lead')
        lead_contact.update!(contact_type: 'lead')

        # Create a customer contact
        customer_contact = create(:contact, account: account, email: 'customer@test.com')
        customer_contact.update!(contact_type: 'customer')

        # Create a visitor contact
        visitor_contact = create(:contact, account: account, name: 'Visitor')
        expect(visitor_contact.contact_type).to eq('visitor')

        resolved = account.contacts.resolved_contacts(use_crm_v2: true)

        expect(resolved).to include(lead_contact)
        expect(resolved).not_to include(customer_contact)
        expect(resolved).not_to include(visitor_contact)
      end

      it 'returns contacts with email, phone_number, or identifier when explicitly passing use_crm_v2: false' do
        # Even though feature flag is enabled, we're explicitly passing false
        contact_with_email = create(:contact, account: account, email: 'test@example.com', name: 'John Doe')
        contact_with_phone = create(:contact, account: account, phone_number: '+1234567890', name: 'Jane Smith')
        contact_without_details = create(:contact, account: account, name: 'Alice Johnson', email: nil, phone_number: nil, identifier: nil)

        resolved = account.contacts.resolved_contacts(use_crm_v2: false)

        # Should use the old logic despite feature flag being enabled
        expect(resolved).to include(contact_with_email, contact_with_phone)
        expect(resolved).not_to include(contact_without_details)
      end
    end

    context 'with mixed contact types' do
      it 'correctly filters based on use_crm_v2 parameter regardless of feature flag' do
        # Create different types of contacts
        visitor_contact = create(:contact, account: account, name: 'Visitor')
        lead_with_email = create(:contact, account: account, email: 'lead@example.com', name: 'Lead')
        lead_without_email = create(:contact, account: account, name: 'Lead Only')
        lead_without_email.update!(contact_type: 'lead')
        customer_contact = create(:contact, account: account, email: 'customer@example.com', name: 'Customer')
        customer_contact.update!(contact_type: 'customer')

        # Test with use_crm_v2: false
        resolved_old = account.contacts.resolved_contacts(use_crm_v2: false)
        expect(resolved_old).to include(lead_with_email, lead_without_email, customer_contact)
        expect(resolved_old).not_to include(visitor_contact)

        # Test with use_crm_v2: true
        resolved_new = account.contacts.resolved_contacts(use_crm_v2: true)
        expect(resolved_new).to include(lead_with_email, lead_without_email)
        expect(resolved_new).not_to include(visitor_contact, customer_contact)
      end
    end
  end

  describe 'display source preferences' do
    around do |example|
      with_modified_env(
        'EVOLUTION_API_URL' => 'https://evolution.example.com',
        'EVOLUTION_API_KEY' => 'test-api-key',
        'FRONTEND_URL' => 'https://app.example.com'
      ) do
        example.run
      end
    end

    let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
    let(:contact) { create(:contact, account: account, name: 'Arman', phone_number: '+77757770014') }
    let(:telegram_channel) { create(:channel_telegram_personal, account: account) }
    let(:whatsapp_channel) { create(:channel_whatsapp_web, account: account) }
    let!(:telegram_contact_inbox) do
      create(:contact_inbox, contact: contact, inbox: telegram_channel.inbox, source_id: '435536951')
    end
    let!(:whatsapp_contact_inbox) do
      create(:contact_inbox, contact: contact, inbox: whatsapp_channel.inbox, source_id: '77757770014')
    end
    let(:telegram_profile) do
      create(
        :contact_channel_profile,
        contact: contact,
        contact_inbox: telegram_contact_inbox,
        inbox: telegram_channel.inbox,
        provider: 'telegram_personal',
        source_id: '435536951',
        display_name: 'Arman',
        avatar_url: 'https://cdn.example.com/tg-avatar.jpg'
      )
    end
    let(:whatsapp_profile) do
      create(
        :contact_channel_profile,
        contact: contact,
        contact_inbox: whatsapp_contact_inbox,
        inbox: whatsapp_channel.inbox,
        provider: 'whatsapp_web',
        source_id: '77757770014',
        display_name: 'Akhan',
        avatar_url: 'https://cdn.example.com/wa-avatar.jpg'
      )
    end

    before do
      telegram_profile
      whatsapp_profile
    end

    it 'blocks cross-channel name overwrites when another source is primary' do
      contact.update!(
        additional_attributes: contact.merge_display_source(
          additional_attributes: contact.additional_attributes,
          key: Contact::PRIMARY_NAME_SOURCE_KEY,
          source: contact.display_source_for_contact_inbox(telegram_contact_inbox)
        )
      )

      expect(
        contact.name_updates_allowed_for?(
          contact_inbox: whatsapp_contact_inbox,
          replaceable_current_name: false
        )
      ).to be(false)
      expect(
        contact.name_updates_allowed_for?(
          contact_inbox: telegram_contact_inbox,
          replaceable_current_name: false
        )
      ).to be(true)
    end

    it 'resolves the contact thumbnail from the selected source avatar' do
      contact.update!(
        additional_attributes: contact.merge_display_source(
          additional_attributes: contact.additional_attributes,
          key: Contact::PRIMARY_AVATAR_SOURCE_KEY,
          source: contact.display_source_for_contact_inbox(telegram_contact_inbox)
        )
      )

      expect(contact.resolved_avatar_url).to eq('https://cdn.example.com/tg-avatar.jpg')
      expect(contact.resolved_primary_avatar_source).to include(
        'kind' => 'channel_profile',
        'contact_inbox_id' => telegram_contact_inbox.id
      )
    end
  end
end
