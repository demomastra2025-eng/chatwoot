require 'rails_helper'

describe ContactInboxBuilder do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, email: 'xyc@example.com', phone_number: '+23423424123', account: account) }

  describe '#perform' do
    describe 'twilio sms inbox' do
      let!(:twilio_sms) { create(:channel_twilio_sms, account: account) }
      let!(:twilio_inbox) { create(:inbox, channel: twilio_sms, account: account) }

      it 'does not create contact inbox when contact inbox already exists with the source id provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: twilio_inbox, source_id: contact.phone_number)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: twilio_inbox,
          source_id: contact.phone_number
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'does not create contact inbox when contact inbox already exists with phone number and source id is not provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: twilio_inbox, source_id: contact.phone_number)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: twilio_inbox
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'creates a new contact inbox when different source id is provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: twilio_inbox, source_id: contact.phone_number)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: twilio_inbox,
          source_id: '+224213223422'
        ).perform

        expect(contact_inbox.id).not_to eq(existing_contact_inbox.id)
        expect(contact_inbox.source_id).to eq('+224213223422')
      end

      it 'creates a contact inbox with contact phone number when source id not provided and no contact inbox exists' do
        contact_inbox = described_class.new(
          contact: contact,
          inbox: twilio_inbox
        ).perform

        expect(contact_inbox.source_id).to eq(contact.phone_number)
      end

      it 'raises error when contact phone number is not present and no source id is provided' do
        contact.update!(phone_number: nil)

        expect do
          described_class.new(
            contact: contact,
            inbox: twilio_inbox
          ).perform
        end.to raise_error(ActionController::ParameterMissing, 'param is missing or the value is empty: contact phone number')
      end
    end

    describe 'twilio whatsapp inbox' do
      let!(:twilio_whatsapp) { create(:channel_twilio_sms, medium: :whatsapp, account: account) }
      let!(:twilio_inbox) { create(:inbox, channel: twilio_whatsapp, account: account) }

      it 'does not create contact inbox when contact inbox already exists with the source id provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: twilio_inbox, source_id: "whatsapp:#{contact.phone_number}")
        contact_inbox = described_class.new(
          contact: contact,
          inbox: twilio_inbox,
          source_id: "whatsapp:#{contact.phone_number}"
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'does not create contact inbox when contact inbox already exists with phone number and source id is not provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: twilio_inbox, source_id: "whatsapp:#{contact.phone_number}")
        contact_inbox = described_class.new(
          contact: contact,
          inbox: twilio_inbox
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'creates a new contact inbox when different source id is provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: twilio_inbox, source_id: "whatsapp:#{contact.phone_number}")
        contact_inbox = described_class.new(
          contact: contact,
          inbox: twilio_inbox,
          source_id: 'whatsapp:+555555'
        ).perform

        expect(contact_inbox.id).not_to eq(existing_contact_inbox.id)
        expect(contact_inbox.source_id).to eq('whatsapp:+555555')
      end

      it 'creates a contact inbox with contact phone number when source id not provided and no contact inbox exists' do
        contact_inbox = described_class.new(
          contact: contact,
          inbox: twilio_inbox
        ).perform

        expect(contact_inbox.source_id).to eq("whatsapp:#{contact.phone_number}")
      end

      it 'raises error when contact phone number is not present and no source id is provided' do
        contact.update!(phone_number: nil)

        expect do
          described_class.new(
            contact: contact,
            inbox: twilio_inbox
          ).perform
        end.to raise_error(ActionController::ParameterMissing, 'param is missing or the value is empty: contact phone number')
      end
    end

    describe 'whatsapp inbox' do
      let(:whatsapp_inbox) { create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox }

      it 'does not create contact inbox when contact inbox already exists with the source id provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox, source_id: contact.phone_number&.delete('+'))
        contact_inbox = described_class.new(
          contact: contact,
          inbox: whatsapp_inbox,
          source_id: contact.phone_number&.delete('+')
        ).perform

        expect(contact_inbox.id).to be(existing_contact_inbox.id)
      end

      it 'does not create contact inbox when contact inbox already exists with phone number and source id is not provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox, source_id: contact.phone_number&.delete('+'))
        contact_inbox = described_class.new(
          contact: contact,
          inbox: whatsapp_inbox
        ).perform

        expect(contact_inbox.id).to be(existing_contact_inbox.id)
      end

      it 'creates a new contact inbox when different source id is provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox, source_id: contact.phone_number&.delete('+'))
        contact_inbox = described_class.new(
          contact: contact,
          inbox: whatsapp_inbox,
          source_id: '555555'
        ).perform

        expect(contact_inbox.id).not_to be(existing_contact_inbox.id)
        expect(contact_inbox.source_id).not_to be('555555')
      end

      it 'creates a contact inbox with contact phone number when source id not provided and no contact inbox exists' do
        contact_inbox = described_class.new(
          contact: contact,
          inbox: whatsapp_inbox
        ).perform

        expect(contact_inbox.source_id).to eq(contact.phone_number&.delete('+'))
      end

      it 'raises error when contact phone number is not present and no source id is provided' do
        contact.update!(phone_number: nil)

        expect do
          described_class.new(
            contact: contact,
            inbox: whatsapp_inbox
          ).perform
        end.to raise_error(ActionController::ParameterMissing, 'param is missing or the value is empty: contact phone number')
      end
    end

    describe 'sms inbox' do
      let!(:sms_channel) { create(:channel_sms, account: account) }
      let!(:sms_inbox) { create(:inbox, channel: sms_channel, account: account) }

      it 'does not create contact inbox when contact inbox already exists with the source id provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: sms_inbox, source_id: contact.phone_number)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: sms_inbox,
          source_id: contact.phone_number
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'does not create contact inbox when contact inbox already exists with phone number and source id is not provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: sms_inbox, source_id: contact.phone_number)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: sms_inbox
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'creates a new contact inbox when different source id is provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: sms_inbox, source_id: contact.phone_number)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: sms_inbox,
          source_id: '+224213223422'
        ).perform

        expect(contact_inbox.id).not_to eq(existing_contact_inbox.id)
        expect(contact_inbox.source_id).to eq('+224213223422')
      end

      it 'creates a contact inbox with contact phone number when source id not provided and no contact inbox exists' do
        contact_inbox = described_class.new(
          contact: contact,
          inbox: sms_inbox
        ).perform

        expect(contact_inbox.source_id).to eq(contact.phone_number)
      end

      it 'raises error when contact phone number is not present and no source id is provided' do
        contact.update!(phone_number: nil)

        expect do
          described_class.new(
            contact: contact,
            inbox: sms_inbox
          ).perform
        end.to raise_error(ActionController::ParameterMissing, 'param is missing or the value is empty: contact phone number')
      end
    end

    describe 'email inbox' do
      let!(:email_channel) { create(:channel_email, account: account) }
      let!(:email_inbox) { create(:inbox, channel: email_channel, account: account) }

      it 'does not create contact inbox when contact inbox already exists with the source id provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: email_inbox, source_id: contact.email)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: email_inbox,
          source_id: contact.email
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'does not create contact inbox when contact inbox already exists with email and source id is not provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: email_inbox, source_id: contact.email)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: email_inbox
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'creates a new contact inbox when different source id is provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: email_inbox, source_id: contact.email)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: email_inbox,
          source_id: 'xyc@xyc.com'
        ).perform

        expect(contact_inbox.id).not_to eq(existing_contact_inbox.id)
        expect(contact_inbox.source_id).to eq('xyc@xyc.com')
      end

      it 'creates a contact inbox with contact email when source id not provided and no contact inbox exists' do
        contact_inbox = described_class.new(
          contact: contact,
          inbox: email_inbox
        ).perform

        expect(contact_inbox.source_id).to eq(contact.email)
      end

      it 'raises error when contact email is not present and no source id is provided' do
        contact.update!(email: nil)

        expect do
          described_class.new(
            contact: contact,
            inbox: email_inbox
          ).perform
        end.to raise_error(ActionController::ParameterMissing, 'param is missing or the value is empty: contact email')
      end
    end

    describe 'api inbox' do
      let!(:api_channel) { create(:channel_api, account: account) }
      let!(:api_inbox) { create(:inbox, channel: api_channel, account: account) }

      it 'does not create contact inbox when contact inbox already exists with the source id provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: api_inbox, source_id: 'test')
        contact_inbox = described_class.new(
          contact: contact,
          inbox: api_inbox,
          source_id: 'test'
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
      end

      it 'creates a new contact inbox when different source id is provided' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: api_inbox, source_id: SecureRandom.uuid)
        contact_inbox = described_class.new(
          contact: contact,
          inbox: api_inbox,
          source_id: 'test'
        ).perform

        expect(contact_inbox.id).not_to eq(existing_contact_inbox.id)
        expect(contact_inbox.source_id).to eq('test')
      end

      it 'creates a contact inbox with SecureRandom.uuid when source id not provided and no contact inbox exists' do
        contact_inbox = described_class.new(
          contact: contact,
          inbox: api_inbox
        ).perform

        expect(contact_inbox.source_id).not_to be_nil
      end

      it 'creates a baseline channel profile for new contact inboxes' do
        contact_inbox = described_class.new(
          contact: contact,
          inbox: api_inbox,
          source_id: 'api-source-1'
        ).perform

        expect(contact_inbox.channel_profile).to have_attributes(
          display_name: contact.name,
          email: contact.email,
          phone_number: contact.phone_number,
          identifier: contact.identifier,
          provider: 'api',
          source_id: 'api-source-1'
        )
      end

      it 'backfills a missing baseline channel profile for existing contact inboxes' do
        existing_contact_inbox = create(
          :contact_inbox,
          contact: contact,
          inbox: api_inbox,
          source_id: 'api-source-1'
        )

        expect(existing_contact_inbox.channel_profile).to be_nil

        contact_inbox = described_class.new(
          contact: contact,
          inbox: api_inbox,
          source_id: 'api-source-1'
        ).perform

        expect(contact_inbox.id).to eq(existing_contact_inbox.id)
        expect(contact_inbox.reload.channel_profile).to have_attributes(
          display_name: contact.name,
          email: contact.email,
          phone_number: contact.phone_number
        )
      end

      it 'does not override an existing channel profile' do
        existing_contact_inbox = create(
          :contact_inbox,
          contact: contact,
          inbox: api_inbox,
          source_id: 'api-source-1'
        )
        create(
          :contact_channel_profile,
          contact_inbox: existing_contact_inbox,
          display_name: 'Channel Name',
          username: 'channel_user'
        )

        contact_inbox = described_class.new(
          contact: contact,
          inbox: api_inbox,
          source_id: 'api-source-1'
        ).perform

        expect(contact_inbox.reload.channel_profile).to have_attributes(
          display_name: 'Channel Name',
          username: 'channel_user'
        )
      end
    end

    context 'when there is a race condition' do
      let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
      let(:contact) { create(:contact, account: account) }
      let(:contact2) { create(:contact, account: account) }
      let(:channel) { create(:channel_email, account: account) }
      let(:channel_api) { create(:channel_api, account: account) }
      let(:source_id) { 'source_123' }

      it 'handles RecordNotUnique error by updating source_id and retrying' do
        existing_contact_inbox = create(:contact_inbox, contact: contact2, inbox: channel.inbox, source_id: source_id)

        described_class.new(
          contact: contact,
          inbox: channel.inbox,
          source_id: source_id
        ).perform

        expect(ContactInbox.last.source_id).to eq(source_id)
        expect(ContactInbox.last.contact_id).to eq(contact.id)
        expect(ContactInbox.last.inbox_id).to eq(channel.inbox.id)
        expect(existing_contact_inbox.reload.source_id).to include(source_id)
        expect(existing_contact_inbox.reload.source_id).not_to eq(source_id)
      end

      it 'reuses a route created concurrently for the same WhatsApp contact' do
        whatsapp_account = create(:account, limits: { non_web_inboxes: 10 })
        whatsapp_contact = create(:contact, account: whatsapp_account, phone_number: '+77001234567')
        whatsapp_inbox = create(
          :channel_whatsapp,
          account: whatsapp_account,
          provider: 'whatsapp_cloud',
          sync_templates: false,
          validate_provider_config: false
        ).inbox
        whatsapp_source_id = '77001234567'
        existing_contact_inbox = create(
          :contact_inbox,
          contact: whatsapp_contact,
          inbox: whatsapp_inbox,
          source_id: whatsapp_source_id
        )
        attrs = {
          contact_id: whatsapp_contact.id,
          inbox_id: whatsapp_inbox.id,
          source_id: whatsapp_source_id
        }
        relation = ContactInbox.where(attrs)
        allow(ContactInbox).to receive(:where).and_call_original
        allow(ContactInbox).to receive(:where).with(attrs).and_return(relation)
        allow(relation).to receive(:first_or_create!).and_raise(ActiveRecord::RecordNotUnique, 'same-contact race')

        contact_inbox = described_class.new(
          contact: whatsapp_contact,
          inbox: whatsapp_inbox,
          source_id: whatsapp_source_id
        ).perform

        expect(contact_inbox).to eq(existing_contact_inbox)
        expect(existing_contact_inbox.reload.source_id).to eq(whatsapp_source_id)
      end

      it 'does not update source_id for channels other than email or phone number' do
        create(:contact_inbox, contact: contact2, inbox: channel_api.inbox, source_id: source_id)

        expect do
          described_class.new(
            contact: contact,
            inbox: channel_api.inbox,
            source_id: source_id
          ).perform
        end.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end
  end
end
