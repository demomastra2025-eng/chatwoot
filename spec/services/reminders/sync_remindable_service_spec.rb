require 'rails_helper'

RSpec.describe Reminders::SyncRemindableService do
  describe '#perform' do
    it 'recalculates open relative appointment touches while keeping the fixed time of day' do
      zone = Time.find_zone!('Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        starts_at: zone.parse('2026-07-10 15:00'),
        ends_at: zone.parse('2026-07-10 15:30')
      )
      touch = create(
        :reminder,
        account: appointment.account,
        remindable: appointment,
        timing_mode: :relative,
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.day.to_i,
        relative_time_mode: 'fixed_time_of_day',
        relative_time_of_day: '10:00',
        timezone: 'Asia/Almaty',
        scheduled_at: nil,
        body: 'Rescheduled appointment touch'
      )

      appointment.update!(
        starts_at: zone.parse('2026-07-12 18:00'),
        ends_at: zone.parse('2026-07-12 18:30')
      )

      described_class.new(remindable: appointment).perform

      expect(touch.reload.scheduled_at.to_i).to eq(zone.parse('2026-07-11 10:00').to_i)
      expect(touch.last_materialized_anchor_at.to_i).to eq(appointment.starts_at.to_i)
      expect(touch.schedule_revision).to be >= 2
    end

    it 'does not revise an unchanged relative schedule during processing sync' do
      appointment = create(:scheduling_appointment, starts_at: 1.day.from_now, ends_at: 1.day.from_now + 30.minutes)
      touch = create(
        :reminder,
        account: appointment.account,
        remindable: appointment,
        timing_mode: :relative,
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -10.minutes.to_i,
        scheduled_at: nil,
        body: 'Unchanged appointment touch'
      )
      described_class.new(remindable: appointment).perform_for(touch)
      touch.mark_processing!
      original_revision = touch.schedule_revision

      described_class.new(remindable: appointment, allow_processing: true).perform_for(touch)

      expect(touch.reload.schedule_revision).to eq(original_revision)
    end

    it 'does not mutate a processing touch after its message was materialized' do
      zone = Time.find_zone!('Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        starts_at: zone.parse('2026-07-10 15:00'),
        ends_at: zone.parse('2026-07-10 15:30')
      )
      touch = create(
        :reminder,
        account: appointment.account,
        remindable: appointment,
        timing_mode: :relative,
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.day.to_i,
        timezone: 'Asia/Almaty',
        body: 'Already materialized'
      )
      touch.mark_processing!
      touch.mark_delivery_materialized!(123)
      original_scheduled_at = touch.scheduled_at

      appointment.update!(
        starts_at: zone.parse('2026-07-12 18:00'),
        ends_at: zone.parse('2026-07-12 18:30')
      )
      described_class.new(remindable: appointment).perform

      expect(touch.reload).to be_processing
      expect(touch.scheduled_at).to eq(original_scheduled_at)
      expect(touch.metadata[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY]).to eq(123)
    end

    it 'does not recalculate manually overridden relative touches' do
      zone = Time.find_zone!('Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        starts_at: zone.parse('2026-07-10 15:00'),
        ends_at: zone.parse('2026-07-10 15:30')
      )
      manual_scheduled_at = zone.parse('2026-07-15 12:00')
      touch = create(
        :reminder,
        account: appointment.account,
        remindable: appointment,
        timing_mode: :relative,
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.day.to_i,
        relative_time_mode: 'fixed_time_of_day',
        relative_time_of_day: '10:00',
        manual_schedule_override: true,
        scheduled_at: manual_scheduled_at,
        body: 'Manual appointment touch'
      )

      appointment.update!(
        starts_at: zone.parse('2026-07-12 18:00'),
        ends_at: zone.parse('2026-07-12 18:30')
      )

      described_class.new(remindable: appointment).perform

      expect(touch.reload.scheduled_at.to_i).to eq(manual_scheduled_at.to_i)
      expect(touch.last_materialized_anchor_at).to be_nil
    end

    it 'drops a stale appointment conversation and routes to the current contact' do
      account = create(:account)
      inbox = create(:inbox, account: account)
      old_contact = create(:contact, account: account)
      current_contact = create(:contact, account: account)
      old_contact_inbox = create(:contact_inbox, contact: old_contact, inbox: inbox)
      current_contact_inbox = create(:contact_inbox, contact: current_contact, inbox: inbox)
      stale_conversation = create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: old_contact,
        contact_inbox: old_contact_inbox
      )
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: old_contact,
        conversation: stale_conversation
      )
      touch = create(
        :reminder,
        account: account,
        remindable: appointment,
        conversation: stale_conversation,
        target_conversation: stale_conversation,
        target_contact: old_contact,
        target_contact_inbox: old_contact_inbox,
        target_inbox: inbox,
        status: :pending
      )

      appointment.update!(contact: current_contact)
      described_class.new(remindable: appointment).perform

      expect(touch.reload).to have_attributes(
        target_contact_id: current_contact.id,
        target_contact_inbox_id: current_contact_inbox.id,
        target_conversation_id: nil,
        conversation_id: nil
      )
    end

    it 'routes deal touches to the explicit primary contact instead of association order' do
      account = create(:account)
      inbox = create(:inbox, account: account)
      first_contact = create(:contact, account: account)
      primary_contact = create(:contact, account: account)
      first_contact_inbox = create(:contact_inbox, contact: first_contact, inbox: inbox)
      create(:contact_inbox, contact: primary_contact, inbox: inbox)
      deal = create(:crm_deal, account: account)
      create(:crm_deal_contact, account: account, deal: deal, contact: first_contact, primary: false)
      create(:crm_deal_contact, account: account, deal: deal, contact: primary_contact, primary: true)
      deal.reload
      touch = create(
        :reminder,
        account: account,
        remindable: deal,
        target_contact: first_contact,
        target_contact_inbox: first_contact_inbox,
        target_inbox: inbox,
        status: :pending
      )

      described_class.new(remindable: deal).perform

      expect(touch.reload.target_contact_id).to eq(primary_contact.id)
    end

    it 'clears a no-route error and approves the draft after the target route appears' do
      account = create(:account)
      source_inbox = create(:inbox, account: account)
      channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      contact = create(:contact, account: account, phone_number: nil, email: nil)
      source_contact_inbox = create(:contact_inbox, contact: contact, inbox: source_inbox)
      conversation = create(
        :conversation,
        account: account,
        inbox: source_inbox,
        contact: contact,
        contact_inbox: source_contact_inbox
      )
      touch = Reminders::CreateService.new(
        account: account,
        remindable: conversation,
        attributes: {
          body: 'Retry after route assignment',
          scheduled_at: 1.hour.from_now,
          target_inbox_id: channel.inbox.id
        }
      ).perform

      expect(touch).to be_draft
      expect(touch).to be_route_reassignment_required

      contact.update!(phone_number: '+77001232233')
      expect { touch.approve! }.to raise_error(ActiveRecord::RecordInvalid)

      target_contact_inbox = create(
        :contact_inbox,
        contact: contact,
        inbox: channel.inbox,
        source_id: contact.phone_number.delete('+')
      )
      target_conversation = create(
        :conversation,
        account: account,
        inbox: channel.inbox,
        contact: contact,
        contact_inbox: target_contact_inbox
      )
      create(:message, account: account, inbox: channel.inbox, conversation: target_conversation, message_type: :incoming)
      described_class.new(remindable: conversation).perform_for(touch, raise_errors: true)

      expect(touch.reload).to be_pending
      expect(touch.metadata).not_to have_key(Reminder::ROUTE_ERROR_CODE_KEY)
      expect(touch.last_error).to be_nil
      expect(touch.target_contact_inbox).to have_attributes(
        contact_id: contact.id,
        inbox_id: channel.inbox.id
      )
    end
  end
end
