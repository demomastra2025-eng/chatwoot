require 'rails_helper'

RSpec.describe Outbound::RenderedTextService do
  describe '#render' do
    let(:account) { create(:account) }
    let(:agent) { create(:user, account: account, name: 'Agent Smith') }
    let(:contact) do
      create(
        :contact,
        account: account,
        name: 'Jane Doe',
        email: 'jane@example.com',
        phone_number: '+77015550000'
      )
    end

    it 'renders liquid variables without a conversation context' do
      rendered = described_class.new(
        content: 'Hello {{ contact.name }} from {{ account.name }}',
        contact: contact,
        account: account,
        sender: agent
      ).render

      expect(rendered).to include('Hello Jane Doe')
      expect(rendered).to include(account.name)
    end

    it 'renders field references with a conversation context' do
      inbox = create(:inbox, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: contact.phone_number)
      conversation = create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )

      rendered = described_class.new(
        content: 'Contact: [Phone](field://contact.phone_number) / Conversation: [ID](field://conversation.display_id)',
        conversation: conversation,
        sender: agent
      ).render

      expect(rendered).to include(contact.phone_number)
      expect(rendered).to include(conversation.display_id.to_s)
    end

    it 'renders appointment fields without a conversation in the resource timezone' do
      account.enable_features!('scheduling')
      resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        contact: contact,
        conversation: nil,
        starts_at: Time.utc(2026, 7, 13, 4, 5),
        ends_at: Time.utc(2026, 7, 13, 4, 35)
      )

      rendered = described_class.new(
        content: '[Дата](field://appointment.start_date) [Время](field://appointment.start_time)',
        appointment: appointment,
        contact: contact,
        account: account,
        sender: agent
      ).render

      expect(rendered).to eq('13.07.2026 09:05')
    end

    it 'does not resolve field references inside code blocks' do
      inbox = create(:inbox, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: contact.phone_number)
      conversation = create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )

      rendered = described_class.new(
        content: "Use `[Phone](field://contact.phone_number)` as literal",
        conversation: conversation,
        sender: agent
      ).render

      expect(rendered).to include('[Phone](field://contact.phone_number)')
    end
  end
end
