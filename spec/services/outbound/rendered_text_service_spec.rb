require 'rails_helper'

RSpec.describe Outbound::RenderedTextService do
  describe '#render' do
    let(:account) { create(:account) }
    let(:agent) { create(:user, :administrator, account: account, name: 'Agent Smith') }
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

    it 'uses the same compact summaries for outbound field references as Captain and excludes another patient' do
      account.enable_features!('crm_deals', 'scheduling')
      conversation = create(:conversation, account: account, contact: contact)
      deal = create(:crm_deal, account: account, title: 'Requested deal')
      create(:crm_deal_contact, account: account, deal: deal, contact: contact)
      own = create(:scheduling_appointment, account: account, contact: contact, starts_at: 1.hour.from_now)
      child = create(:contact, account: account)
      create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, starts_at: 2.hours.from_now)

      appointment_json = described_class.new(content: '[Сводка](field://appointment.summary)', conversation: conversation, sender: agent).render
      deal_json = described_class.new(content: '[Сводка](field://deal.summary)', conversation: conversation, sender: agent).render

      expect(JSON.parse(appointment_json)).to include('shown' => 1, 'total' => 1)
      expect(JSON.parse(appointment_json)['groups'].flat_map { |group| group['items'].pluck('id') }).to eq([own.id])
      expect(JSON.parse(deal_json)).to eq(JSON.parse(Captain::DealContext.new(account: account, conversation: conversation).summary.to_json))
      liquid_json = described_class.new(content: '{{ deal.summary }}', conversation: conversation, sender: agent).render
      expect(JSON.parse(liquid_json)).to eq(JSON.parse(deal_json))
      expect(described_class.new(content: '[ID](field://deal.id)', conversation: conversation, sender: agent).render).to eq('')
    end

    it 'preserves a saved scalar deal template when the deal was explicitly supplied' do
      account.enable_features!('crm_deals')
      deal = create(:crm_deal, account: account, title: 'Exact event deal')
      rendered = described_class.new(content: '[Title](field://deal.title) / {{ deal.title }}', deal: deal, account: account,
                                    contact: contact, sender: agent).render

      expect(rendered).to eq('Exact event deal / Exact event deal')
    end

    it 'keeps deal summaries and explicit legacy fields hidden from a sender without CRM permissions' do
      account.enable_features!('crm_deals')
      unauthorized = create(:user, account: account)
      conversation = create(:conversation, account: account, contact: contact)
      deal = create(:crm_deal, account: account, title: 'Private deal')
      create(:crm_deal_contact, account: account, deal: deal, contact: contact)

      rendered = described_class.new(
        content: '[Summary](field://deal.summary)|[Title](field://deal.title)|{{ deal.summary }}|{{ deal.title }}',
        conversation: conversation, deal: deal, sender: unauthorized
      ).render

      expect(rendered).to eq('|||')
    end

    it 'renders an explicit deal reminder without selecting a newer conversation deal' do
      account.enable_features!('crm_deals')
      conversation = create(:conversation, account: account, contact: contact)
      event_deal = create(:crm_deal, account: account, title: 'Exact event deal', originating_conversation: conversation, updated_at: 1.day.ago)
      create(:crm_deal_contact, account: account, deal: event_deal, contact: contact, primary: true)
      create(:crm_deal, account: account, title: 'Newer unrelated deal', originating_conversation: conversation)
      reminder = build(:reminder, account: account, remindable: event_deal, body: '[Title](field://deal.title)')

      expect(reminder.renderable_body(conversation: conversation, sender: agent)).to eq('Exact event deal')
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
