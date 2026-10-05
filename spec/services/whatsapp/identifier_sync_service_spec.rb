require 'rails_helper'

RSpec.describe Whatsapp::IdentifierSyncService do
  it 'continues after a real duplicate source-id insert inside the caller transaction' do
    inbox = create(:inbox)
    contact = create(:contact, account: inbox.account)
    source_id = '77000000001'
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: source_id)
    contact_inboxes = inbox.contact_inboxes
    lookups = 0
    allow(contact_inbox).to receive(:inbox).and_return(inbox)
    allow(inbox).to receive(:contact_inboxes).and_return(contact_inboxes)
    allow(contact_inboxes).to receive(:exists?).and_wrap_original do |original, *args, **kwargs|
      attributes = kwargs.presence || args.first
      if attributes&.[](:source_id) == source_id && lookups.zero?
        lookups += 1
        false
      else
        original.call(*args, **kwargs)
      end
    end

    ActiveRecord::Base.transaction do
      described_class.new(contact_inbox: contact_inbox, contact: contact).perform(
        source_ids: [source_id, 'IN.2081978709342942']
      )

      expect(inbox.contact_inboxes.pluck(:source_id)).to contain_exactly(source_id, 'IN.2081978709342942')
      expect(ActiveRecord::Base.connection.select_value('SELECT 1')).to eq(1)
    end

    expect(lookups).to eq(1)
  end
end
