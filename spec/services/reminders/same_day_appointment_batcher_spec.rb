# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reminders::SameDayAppointmentBatcher do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, name: 'Анна', phone_number: '+77015550101') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77015550101') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:doctor_1) { create(:scheduling_resource, account: account, name: 'Д-р Иванова') }
  let(:doctor_2) { create(:scheduling_resource, account: account, name: 'Д-р Петров') }
  let(:service_1) { create(:scheduling_service, account: account, name: 'УЗИ брюшной полости') }
  let(:service_2) { create(:scheduling_service, account: account, name: 'Прием терапевта') }

  let(:visit_day) { 1.day.from_now.in_time_zone('Asia/Almaty').change(hour: 10, min: 0, sec: 0) }

  let!(:apt_1) do
    create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      conversation: conversation,
      resource: doctor_1,
      service: service_1,
      status: 'scheduled',
      starts_at: visit_day,
      ends_at: visit_day + 30.minutes
    )
  end

  let!(:apt_2) do
    create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      conversation: conversation,
      resource: doctor_2,
      service: service_2,
      status: 'scheduled',
      starts_at: visit_day + 1.hour,
      ends_at: visit_day + 90.minutes
    )
  end

  before do
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: contact,
      message_type: :incoming,
      content: 'Здравствуйте',
      created_at: 1.hour.ago
    )
  end

  describe 'Smart same-day reminder grouping (selective opt-in only)' do
    it 'does NOT combine same-day appointment reminders by default when batch_same_day_appointments is not enabled' do
      r1 = create(
        :reminder,
        account: account,
        conversation: conversation,
        target_conversation: conversation,
        target_inbox: inbox,
        target_contact: contact,
        target_contact_inbox: contact_inbox,
        remindable: apt_1,
        action_type: :send_message,
        content_kind: :free_text,
        body: 'Напоминаем о вашем визите завтра в 10:00.',
        timezone: 'Asia/Almaty',
        status: :pending,
        scheduled_at: 1.minute.ago
      )
      r2 = create(
        :reminder,
        account: account,
        conversation: conversation,
        target_conversation: conversation,
        target_inbox: inbox,
        target_contact: contact,
        target_contact_inbox: contact_inbox,
        remindable: apt_2,
        action_type: :send_message,
        content_kind: :free_text,
        body: 'Напоминаем о вашем визите завтра в 10:00.',
        timezone: 'Asia/Almaty',
        status: :pending,
        scheduled_at: 30.minutes.from_now
      )

      claim_1 = r1.mark_processing!
      message = Reminders::ExecuteService.new(reminder: r1, processing_claim: claim_1).perform

      expect(message).to be_a(Message)
      expect(message.content).to eq('Напоминаем о вашем визите завтра в 10:00.')
      expect(message.content).not_to include('Все ваши записи на')

      expect(r1.reload).to be_completed
      expect(r2.reload).to be_pending
      expect(r2.metadata['coalesced_into_reminder_id']).to be_nil
    end

    it 'combines multiple same-day appointment reminders into 1 message and coalesces siblings when selectively enabled' do
      r1 = create(
        :reminder,
        account: account,
        conversation: conversation,
        target_conversation: conversation,
        target_inbox: inbox,
        target_contact: contact,
        target_contact_inbox: contact_inbox,
        remindable: apt_1,
        action_type: :send_message,
        content_kind: :free_text,
        body: 'Напоминаем о вашем визите завтра в 10:00.',
        timezone: 'Asia/Almaty',
        status: :pending,
        scheduled_at: 1.minute.ago,
        metadata: { 'batch_same_day_appointments' => true }
      )
      r2 = create(
        :reminder,
        account: account,
        conversation: conversation,
        target_conversation: conversation,
        target_inbox: inbox,
        target_contact: contact,
        target_contact_inbox: contact_inbox,
        remindable: apt_2,
        action_type: :send_message,
        content_kind: :free_text,
        body: 'Напоминаем о вашем визите завтра в 10:00.',
        timezone: 'Asia/Almaty',
        status: :pending,
        scheduled_at: 30.minutes.from_now,
        metadata: { 'batch_same_day_appointments' => true }
      )

      claim_1 = r1.mark_processing!
      message = Reminders::ExecuteService.new(reminder: r1, processing_claim: claim_1).perform

      expect(message).to be_a(Message)
      expect(message.content).to include('Все ваши записи на')
      expect(message.content).to include('10:00 — Д-р Иванова — УЗИ брюшной полости')
      expect(message.content).to include('11:00 — Д-р Петров — Прием терапевта')

      expect(r1.reload).to be_completed
      expect(r2.reload).to be_completed
      expect(r2.metadata['coalesced_into_reminder_id']).to eq(r1.id)
      expect(r2.metadata['coalesced_delivery_message_id']).to eq(message.id)

      outgoing_count_before = conversation.messages.outgoing.count
      Reminders::ExecuteService.new(reminder: r2).perform
      expect(conversation.messages.outgoing.count).to eq(outgoing_count_before)
    end
  end

  describe 'Positive confirmation not only by button (text, emoji, and batched button)' do
    before do
      channel.update!(
        message_templates: [
          {
            'name' => 'appointment_confirmation',
            'language' => 'ru',
            'status' => 'APPROVED',
            'components' => [
              { 'type' => 'BODY', 'text' => 'Подтвердите запись' },
              { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' }] }
            ]
          }
        ]
      )
    end

    it 'confirms only the target appointment by default and confirms all same-day visits when batching is enabled' do
      delivery = create(:message, account: account, inbox: inbox, conversation: conversation,
                                  message_type: :outgoing, content: 'Подтвердите запись', source_id: 'wamid.conf.1')
      touch = create(
        :reminder,
        account: account,
        conversation: conversation,
        target_conversation: conversation,
        target_inbox: inbox,
        target_contact: contact,
        target_contact_inbox: contact_inbox,
        remindable: apt_1,
        content_kind: :channel_template,
        body: nil,
        template_params: { name: 'appointment_confirmation', language: 'ru' },
        response_action: 'confirm_appointment',
        response_button_index: 0,
        scheduled_at: 1.hour.from_now,
        metadata: { 'batch_same_day_appointments' => true }
      )
      req = create(
        :confirmation_request,
        account: account,
        inbox: inbox,
        contact: contact,
        conversation: conversation,
        delivery_message: delivery,
        subject: apt_1,
        reminder: touch
      )

      reply = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'Да, приду!'
      )

      result = Confirmations::WhatsappReplyResolver.new(
        account: account,
        conversation: conversation,
        message: reply
      ).perform

      expect(result).to include(handled: true, decision: 'confirmed')
      expect(req.reload).to be_confirmed
      expect(apt_1.reload.status).to eq('confirmed')
      expect(apt_2.reload.status).to eq('confirmed')
    end
  end
end
