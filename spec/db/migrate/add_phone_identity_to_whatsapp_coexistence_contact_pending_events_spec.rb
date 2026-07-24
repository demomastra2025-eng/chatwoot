require 'rails_helper'
require Rails.root.join('db/migrate/20260723023333_add_phone_identity_to_whatsapp_coexistence_contact_pending_events')

RSpec.describe AddPhoneIdentityToWhatsappCoexistenceContactPendingEvents do
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let!(:pending_event) do
    Whatsapp::CoexistenceContactPendingEvent.create!(
      account_id: channel.account_id,
      channel_id: channel.id,
      event_key: 'legacy-brazil-remove',
      reason: 'missing_contact_identity',
      phone_identity: nil,
      entry: {
        action: 'remove',
        contact: { phone_number: '554188887777' },
        metadata: { timestamp: '1700000001' }
      }
    )
  end

  it 'backfills canonical identities and keeps the scoped lookup index available' do
    described_class.new.up

    expect(pending_event.reload.phone_identity).to eq('5541988887777')
    expect(
      ActiveRecord::Base.connection.index_exists?(
        :whatsapp_coexistence_contact_pending_events,
        described_class::INDEX_COLUMNS,
        name: described_class::INDEX_NAME
      )
    ).to be(true)
  end
end
