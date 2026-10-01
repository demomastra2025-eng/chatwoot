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

    it 'moves an open separate-patient touch to the patient own primary number and back to the shared route' do
      account = create(:account, limits: { non_web_inboxes: 10 })
      inbox = create(:channel_whatsapp_web, account: account).inbox
      owner = create(:contact, account: account, phone_number: '+77000000001')
      owner_contact_inbox = create(:contact_inbox, contact: owner, inbox: inbox, source_id: '77000000001')
      conversation = create(:conversation, account: account, inbox: inbox, contact: owner, contact_inbox: owner_contact_inbox)
      patient = create(:contact, account: account, name: 'Relative', phone_number: nil)
      appointment = create(:scheduling_appointment, account: account, contact: owner, patient_contact: patient, conversation: conversation)
      touch = create(:reminder, account: account, remindable: appointment, conversation: conversation, status: :pending)
      expect(touch).to have_attributes(target_contact_id: owner.id, target_contact_inbox_id: owner_contact_inbox.id)

      patient.update!(phone_number: '+77000000002')
      described_class.new(remindable: appointment.reload).perform

      own_contact_inbox = patient.contact_inboxes.find_by!(inbox: inbox, source_id: '77000000002')
      expect(touch.reload).to be_pending
      expect(touch).to have_attributes(target_contact_id: patient.id, target_inbox_id: inbox.id, target_contact_inbox_id: own_contact_inbox.id,
                                       target_conversation_id: nil, conversation_id: nil)
      expect(ContactInbox.where(contact: patient, source_id: owner_contact_inbox.source_id)).to be_empty

      patient.update!(phone_number: nil)
      described_class.new(remindable: appointment.reload).perform

      expect(touch.reload).to have_attributes(target_contact_id: owner.id, target_contact_inbox_id: owner_contact_inbox.id,
                                              target_conversation_id: conversation.id, conversation_id: conversation.id)
      expect(appointment.reload).to have_attributes(contact_id: owner.id, conversation_id: conversation.id)
    end

    context 'when the separate patient number is already a chat identity in the inbox' do
      let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
      let(:inbox) { create(:channel_whatsapp_web, account: account).inbox }
      let(:owner) { create(:contact, account: account, phone_number: '+77000000001') }
      let(:owner_contact_inbox) { create(:contact_inbox, contact: owner, inbox: inbox, source_id: '77000000001') }
      let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: owner, contact_inbox: owner_contact_inbox) }
      let(:patient) { create(:contact, account: account, name: 'Relative', phone_number: nil) }
      let(:appointment) { create(:scheduling_appointment, account: account, contact: owner, patient_contact: patient, conversation: conversation) }
      let!(:open_touch) { create(:reminder, account: account, remindable: appointment, conversation: conversation, status: :pending) }

      it 'keeps the shared route when the owner already chats from that number' do
        cloud_inbox = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false).inbox
        family_contact_inbox = create(:contact_inbox, contact: owner, inbox: cloud_inbox, source_id: '77000000009')
        patient.update!(phone_number: '+77000000009')

        described_class.new(remindable: appointment.reload).perform_for(open_touch, raise_errors: true)

        expect(open_touch.reload).to have_attributes(status: 'pending', target_contact_id: owner.id, target_contact_inbox_id: owner_contact_inbox.id)
        expect(family_contact_inbox.reload).to have_attributes(contact_id: owner.id, source_id: '77000000009')
        expect(patient.contact_inboxes).to be_empty
      end

      it 'asks for reassignment instead of taking over the chat of another contact' do
        stranger = create(:contact, account: account, name: 'Stranger', phone_number: nil)
        stranger_contact_inbox = create(:contact_inbox, contact: stranger, inbox: inbox, source_id: '77000000009')
        patient.update!(phone_number: '+77000000009')

        described_class.new(remindable: appointment.reload).perform_for(open_touch, raise_errors: true)

        expect(open_touch.reload).to have_attributes(status: 'draft', target_contact_id: patient.id, target_contact_inbox_id: nil)
        expect(open_touch).to be_route_reassignment_required
        expect(stranger_contact_inbox.reload).to have_attributes(contact_id: stranger.id, source_id: '77000000009')
        expect(patient.contact_inboxes).to be_empty
      end

      it 'keeps the appointment edit working when the patient number is another contact chat' do
        stranger = create(:contact, account: account, name: 'Stranger', phone_number: nil)
        stranger_contact_inbox = create(:contact_inbox, contact: stranger, inbox: inbox, source_id: '77000000009')
        patient.update!(phone_number: '+77000000009')
        allow_any_instance_of(Scheduling::Appointments::UpsertService).to receive(:validate_availability!) # rubocop:disable RSpec/AnyInstance

        expect do
          Scheduling::Appointments::UpsertService.new(account: account, appointment: appointment.reload,
                                                      params: { client_comment: 'Edited visit' }).perform
        end.not_to raise_error

        expect(appointment.reload.client_comment).to eq('Edited visit')
        expect(open_touch.reload).to have_attributes(status: 'draft', target_contact_id: patient.id, target_contact_inbox_id: nil)
        expect(open_touch).to be_route_reassignment_required
        expect(stranger_contact_inbox.reload).to have_attributes(contact_id: stranger.id, source_id: '77000000009')
      end

      it 'rolls back only the touch savepoint when the patient contact inbox insert loses a race' do
        stranger = create(:contact, account: account, name: 'Stranger', phone_number: nil)
        stranger_contact_inbox = create(:contact_inbox, contact: stranger, inbox: inbox, source_id: '77000000009')
        patient.update!(phone_number: '+77000000009')
        # The holder check misses the concurrently created chat, so the insert itself collides inside the outer transaction.
        allow(Reminders::PatientSubjectGuard).to receive(:foreign_chat_identity?).and_return(false)

        ActiveRecord::Base.transaction do
          described_class.new(remindable: appointment.reload).perform
          appointment.update!(client_comment: 'Edited in the same transaction')
        end

        expect(appointment.reload.client_comment).to eq('Edited in the same transaction')
        expect(open_touch.reload).to have_attributes(status: 'draft', target_contact_id: patient.id, target_contact_inbox_id: nil)
        expect(open_touch).to be_route_reassignment_required
        expect(stranger_contact_inbox.reload).to have_attributes(contact_id: stranger.id, source_id: '77000000009')
      end

      it 'isolates a database error of one touch sync from the surrounding transaction' do
        allow(Reminders::TargetRouteResolver).to receive(:new).and_wrap_original do |original, **kwargs|
          ActiveRecord::Base.connection.execute('SELECT 1 / 0')
        rescue ActiveRecord::StatementInvalid
          original.call(**kwargs)
        end

        ActiveRecord::Base.transaction do
          described_class.new(remindable: appointment.reload).perform
          appointment.update!(client_comment: 'Edited after a failed touch sync')
        end

        expect(appointment.reload.client_comment).to eq('Edited after a failed touch sync')
        expect(open_touch.reload).to have_attributes(status: 'pending', target_contact_id: owner.id)
      end
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
