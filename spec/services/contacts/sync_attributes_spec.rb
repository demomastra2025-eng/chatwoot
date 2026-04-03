# spec/services/contacts/sync_attributes_spec.rb

require 'rails_helper'

RSpec.describe Contacts::SyncAttributes do
  describe '#perform' do
    let(:contact) do
      create(
        :contact,
        additional_attributes: {
          'city' => 'New York',
          'country' => 'United States',
          'country_code' => 'US'
        }
      )
    end

    context 'when contact has neither email/phone number nor social details' do
      it 'does not change contact type' do
        described_class.new(contact).perform
        expect(contact.reload.contact_type).to eq('visitor')
      end
    end

    context 'when contact has email or phone number' do
      it 'sets contact type to lead' do
        contact.email = 'test@test.com'
        contact.save
        described_class.new(contact).perform

        expect(contact.reload.contact_type).to eq('lead')
      end
    end

    context 'when contact has social details' do
      it 'sets contact type to lead' do
        contact.additional_attributes['social_facebook_user_id'] = '123456789'
        contact.save
        described_class.new(contact).perform

        expect(contact.reload.contact_type).to eq('lead')
      end
    end

    context 'when location and country code are updated from additional attributes' do
      it 'updates location and country code' do
        described_class.new(contact).perform

        # Expect location and country code to be updated
        expect(contact.reload.location).to eq('New York')
        expect(contact.reload.country_code).to eq('US')
      end
    end

    context 'when only legacy country code is present in country' do
      let(:contact) do
        create(:contact, additional_attributes: { 'city' => 'New York', 'country' => 'us' })
      end

      it 'falls back to the legacy two-letter country value' do
        described_class.new(contact).perform

        expect(contact.reload.country_code).to eq('US')
      end
    end

    context 'when country contains a country name without country_code' do
      let(:contact) do
        create(:contact, country_code: 'KZ', additional_attributes: { 'city' => 'Almaty', 'country' => 'Kazakhstan' })
      end

      it 'does not overwrite country_code with a country name' do
        described_class.new(contact).perform

        expect(contact.reload.location).to eq('Almaty')
        expect(contact.reload.country_code).to eq('KZ')
      end
    end
  end
end
