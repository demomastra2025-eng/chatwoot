require 'rails_helper'

RSpec.describe AutomationRules::TouchActionService do
  let(:account) { create(:account) }
  let(:rule) { create(:automation_rule, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Jane Patient') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:service) { described_class.new(rule: rule, account: account, record: conversation, entity_kind: 'conversation') }

  describe '#create_touch' do
    it 'defaults auto-cancel off unless the automation action explicitly enables it' do
      touch = service.create_touch([{ body: 'Follow up later', delay_minutes: 10 }])

      expect(touch).to be_pending
      expect(touch.auto_cancel_on_incoming).to be(false)
      expect(touch.metadata).to include(
        'touch_source' => 'automation',
        'automation_rule_id' => rule.id,
        Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY => 'automation',
        Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule.id
      )
    end

    it 'stores an explicit auto-cancel flag when enabled' do
      touch = service.create_touch([{ body: 'Follow up later', delay_minutes: 10, auto_cancel_on_incoming: true }])

      expect(touch.auto_cancel_on_incoming).to be(true)
      expect(touch.metadata).to include('auto_cancel_on_incoming_explicit' => true)
    end

    it 'accepts the direct hash payload emitted by the automation UI' do
      touch = service.create_touch({ body: 'UI payload follow up', delay_minutes: 5 })

      expect(touch).to be_pending
      expect(touch.body).to eq('UI payload follow up')
      expect(touch.scheduled_at).to be_within(2.seconds).of(5.minutes.from_now)
    end

    it 'returns an existing open touch when a delayed non-message event is dispatched again' do
      params = { body: 'Idempotent follow-up', delay_minutes: 10 }
      existing_touch = service.create_touch(params)

      travel 2.seconds do
        expect do
          expect(service.create_touch(params)).to eq(existing_touch)
        end.not_to change(Reminder, :count)
      end
    end

    it 'adopts an open touch created before action signatures were stored' do
      params = { body: 'Legacy follow-up', delay_minutes: 10 }
      existing_touch = service.create_touch(params, action_key: 'legacy-action')
      existing_touch.update_column(
        :metadata,
        existing_touch.metadata.except(Reminder::AUTOMATION_ACTION_SIGNATURE_KEY)
      )
      allow(rule).to receive(:with_lock).and_call_original

      travel 2.seconds do
        expect do
          expect(service.create_touch(params, action_key: 'legacy-action')).to eq(existing_touch)
        end.not_to change(Reminder, :count)
      end

      expect(existing_touch.reload.metadata[Reminder::AUTOMATION_ACTION_SIGNATURE_KEY]).to be_present
      expect(rule).to have_received(:with_lock)
    end

    it 'does not adopt a legacy touch after its automation rule was edited' do
      existing_touch = service.create_touch({ body: 'Old follow-up', delay_minutes: 10 }, action_key: 'legacy-action')
      existing_touch.update_column(
        :metadata,
        existing_touch.metadata.except(Reminder::AUTOMATION_ACTION_SIGNATURE_KEY)
      )

      travel 2.seconds do
        rule.touch

        expect do
          new_touch = service.create_touch({ body: 'Updated follow-up', delay_minutes: 10 }, action_key: 'legacy-action')
          expect(new_touch).not_to eq(existing_touch)
          expect(new_touch.body).to eq('Updated follow-up')
        end.to change(Reminder, :count).by(1)
      end

      expect(existing_touch.reload.metadata[Reminder::AUTOMATION_ACTION_SIGNATURE_KEY]).to be_blank
    end

    it 'keeps the legacy advisory lock source for message-trigger actions' do
      trigger_message = create(:message, account: account, inbox: inbox, conversation: conversation)
      message_service = described_class.new(
        rule: rule,
        account: account,
        record: conversation,
        entity_kind: 'conversation',
        trigger_message: trigger_message
      )
      expected_source = [account.id, rule.id, 'conversation', conversation.id, trigger_message.id, 'message-action'].join(':')
      expected_lock_key = Digest::SHA256.hexdigest("automation-touch-event:#{expected_source}").first(16).to_i(16) % ((2**63) - 1)

      allow(Reminder.connection).to receive(:execute).and_call_original

      message_service.create_touch({ body: 'Message follow-up', delay_minutes: 10 }, action_key: 'message-action')

      expect(Reminder.connection).to have_received(:execute)
        .with("SELECT pg_advisory_xact_lock(#{expected_lock_key})")
    end

    it 'does not absorb a duplicate validation failure that contains another error' do
      invalid_touch = build(:reminder, account: account, remindable: conversation)
      invalid_touch.errors.add(:base, 'An open touch with the same content already exists')
      invalid_touch.errors.add(:conversation, 'must belong to the current account')
      validation_error = ActiveRecord::RecordInvalid.new(invalid_touch)
      allow(service).to receive(:create_automation_touch).and_raise(validation_error)

      expect do
        service.create_touch(body: 'Invalid duplicate', delay_minutes: 10)
      end.to raise_error(validation_error)
    end

    it 'creates a new touch when the action parameters change but the action key stays the same' do
      existing_touch = service.create_touch({ body: 'Old follow-up', delay_minutes: 10 }, action_key: 'stable-action')

      expect do
        new_touch = service.create_touch({ body: 'Updated follow-up', delay_minutes: 10 }, action_key: 'stable-action')
        expect(new_touch).not_to eq(existing_touch)
        expect(new_touch.body).to eq('Updated follow-up')
      end.to change(Reminder, :count).by(1)
    end

    it 'creates a new touch after the matching touch reaches a terminal state' do
      params = { body: 'Reusable follow-up', delay_minutes: 10 }
      service.create_touch(params).cancel!

      expect { service.create_touch(params) }.to change(Reminder, :count).by(1)
    end

    it 'persists the safe post-delivery action for a one-time conversation touch' do
      touch = service.create_touch(
        body: 'Final follow-up',
        delay_minutes: 5,
        action_type: '',
        repeat_mode: '',
        post_delivery_action: 'resolve_conversation'
      )

      expect(touch.post_delivery_action).to eq('resolve_conversation')
      expect(touch).to be_send_message
      expect(touch).to be_once
    end

    it 'rejects unsupported or recurring post-delivery actions' do
      expect do
        service.create_touch(
          body: 'Unsafe follow-up',
          delay_minutes: 5,
          post_delivery_action: 'send_webhook'
        )
      end.to raise_error(ArgumentError, 'create_touch post_delivery_action is invalid')

      expect do
        service.create_touch(
          body: 'Recurring follow-up',
          scheduled_at: 1.day.from_now,
          repeat_mode: 'daily',
          post_delivery_action: 'resolve_conversation'
        )
      end.to raise_error(ArgumentError, 'create_touch post_delivery_action requires a one-time touch')

      expect do
        service.create_touch(
          action_type: 'ai_agent_wakeup',
          instructions: 'Wake the agent',
          delay_minutes: 5,
          post_delivery_action: 'resolve_conversation'
        )
      end.to raise_error(ArgumentError, 'create_touch post_delivery_action is invalid')
    end

    it 'rejects conversation resolution for a non-conversation automation entity' do
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        conversation: conversation,
        starts_at: 2.hours.from_now,
        ends_at: 3.hours.from_now
      )
      appointment_service = described_class.new(
        rule: rule,
        account: account,
        record: appointment,
        entity_kind: 'appointment'
      )

      expect do
        appointment_service.create_touch(
          body: 'Appointment follow-up',
          delay_minutes: 5,
          post_delivery_action: 'resolve_conversation'
        )
      end.to raise_error(ArgumentError, 'create_touch post_delivery_action is invalid')
    end

    it 'persists an exact quick-reply confirmation action for an appointment touch' do
      allow(Outbound::DeliveryPolicy).to receive(:ensure!).and_return(nil)
      channel = create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
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
      cloud_contact_inbox = create(:contact_inbox, contact: contact, inbox: channel.inbox)
      cloud_conversation = create(
        :conversation,
        account: account,
        inbox: channel.inbox,
        contact: contact,
        contact_inbox: cloud_contact_inbox
      )
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        conversation: cloud_conversation,
        starts_at: 2.hours.from_now,
        ends_at: 3.hours.from_now
      )
      appointment_service = described_class.new(
        rule: rule,
        account: account,
        record: appointment,
        entity_kind: 'appointment'
      )

      touch = appointment_service.create_touch(
        content_kind: 'channel_template',
        target_inbox_id: channel.inbox.id,
        template_params: { name: 'appointment_confirmation', language: 'ru' },
        delay_minutes: 5,
        response_action: 'confirm_appointment',
        response_button_index: 0
      )

      expect(touch.response_action).to eq('confirm_appointment')
      expect(touch.response_button_index).to eq(0)
      expect(touch).to be_once
      expect(touch.remindable).to eq(appointment)

      template_with_two_buttons = channel.message_templates.first.deep_dup
      template_with_two_buttons['components'].last['buttons'] << {
        'type' => 'QUICK_REPLY',
        'text' => 'Перенести'
      }
      channel.update!(message_templates: [template_with_two_buttons])

      expect do
        appointment_service.create_touch(
          content_kind: 'channel_template',
          target_inbox_id: channel.inbox.id,
          template_params: { name: 'appointment_confirmation', language: 'ru' },
          delay_minutes: 10,
          response_action: 'confirm_appointment',
          response_button_index: 0
        )
      end.to raise_error(ArgumentError, 'create_touch response_action is invalid')
    end

    it 'creates a relative AI-authored touch with full touch timing params' do
      create(:message, account: account, conversation: conversation, message_type: :incoming)

      touch = service.create_touch([
                                     {
                                       instructions: 'Write a warm follow-up from the AI agent',
                                       text_mode: 'agent',
                                       timing_mode: 'relative',
                                       relative_anchor: 'conversation.last_incoming_message_at',
                                       relative_offset_seconds: 2.hours.to_i,
                                       timezone: 'Asia/Almaty',
                                       auto_cancel_on_incoming: true,
                                       metadata: { source_note: 'automation-test' }
                                     }
                                   ])

      expect(touch).to be_pending
      expect(touch).to be_agent
      expect(touch.instructions).to eq('Write a warm follow-up from the AI agent')
      expect(touch.timing_mode).to eq('relative')
      expect(touch.relative_anchor).to eq('conversation.last_incoming_message_at')
      expect(touch.relative_offset_seconds).to eq(2.hours.to_i)
      expect(touch.timezone).to eq('Asia/Almaty')
      expect(touch.metadata).to include(
        'source_note' => 'automation-test',
        'touch_source' => 'automation',
        'automation_rule_id' => rule.id
      )
    end

    it 'creates an absolute recurring touch from full touch params' do
      scheduled_at = 2.days.from_now.change(usec: 0)
      repeat_until_at = 9.days.from_now.change(usec: 0)

      touch = service.create_touch([
                                     {
                                       body: 'Recurring follow up',
                                       scheduled_at: scheduled_at.iso8601,
                                       timing_mode: 'absolute',
                                       repeat_mode: 'weekly',
                                       repeat_until_at: repeat_until_at.iso8601,
                                       timezone: 'Asia/Almaty'
                                     }
                                   ])

      expect(touch).to be_pending
      expect(touch.scheduled_at.to_i).to eq(scheduled_at.to_i)
      expect(touch.repeat_mode).to eq('weekly')
      expect(touch.repeat_until_at.to_i).to eq(repeat_until_at.to_i)
      expect(touch.timezone).to eq('Asia/Almaty')
    end

    it 'creates a relative touch with a fixed time of day' do
      zone = Time.find_zone!('Asia/Almaty')

      travel_to zone.parse('2026-07-01 15:00') do
        touch = service.create_touch([
                                       {
                                         body: 'Morning reminder',
                                         timing_mode: 'relative',
                                         relative_anchor: 'touch.created_at',
                                         relative_offset_seconds: 1.day.to_i,
                                         relative_time_mode: 'fixed_time_of_day',
                                         relative_time_of_day: '09:30',
                                         timezone: 'Asia/Almaty'
                                       }
                                     ])

        expect(touch).to be_pending
        expect(touch.relative_time_mode).to eq('fixed_time_of_day')
        expect(touch.relative_time_of_day).to eq('09:30')
        expect(touch.scheduled_at.to_i).to eq(zone.parse('2026-07-02 09:30').to_i)
      end
    end

    it 'creates a channel-template touch and preserves template params' do
      allow(Outbound::DeliveryPolicy).to receive(:ensure!).and_return(nil)

      touch = service.create_touch([
                                     {
                                       content_kind: 'channel_template',
                                       template_params: {
                                         name: 'payment_reminder',
                                         language: 'ru',
                                         processed_params: { body: { '1' => 'Akhan' } }
                                       },
                                       timing_mode: 'relative',
                                       relative_anchor: 'touch.created_at',
                                       relative_offset_seconds: 30.minutes.to_i
                                     }
                                   ])

      expect(touch).to be_pending
      expect(touch).to be_channel_template
      expect(touch.template_params).to include(
        'name' => 'payment_reminder',
        'language' => 'ru',
        'processed_params' => { 'body' => { '1' => 'Akhan' } }
      )
    end

    it 'creates full touch payloads for conversation, deal, task, and appointment automation records' do
      travel_to Time.zone.parse('2026-07-01 09:00') do
        deal = create(
          :crm_deal,
          account: account,
          originating_conversation: conversation,
          expected_close_on: Date.new(2026, 7, 10)
        )
        create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)
        task = create(
          :crm_task,
          account: account,
          deal: deal,
          originating_conversation: conversation,
          due_at: Time.zone.parse('2026-07-05 12:00')
        )
        appointment = create(
          :scheduling_appointment,
          account: account,
          contact: contact,
          conversation: conversation,
          starts_at: Time.zone.parse('2026-07-04 10:00'),
          ends_at: Time.zone.parse('2026-07-04 10:30')
        )

        matrix = [
          ['conversation', conversation, 'conversation.created_at'],
          ['deal', deal, 'deal.expected_close_on'],
          ['task', task, 'task.due_at'],
          ['appointment', appointment, 'appointment.starts_at']
        ]

        matrix.each do |entity_kind, record, anchor|
          entity_service = described_class.new(
            rule: rule,
            account: account,
            record: record,
            entity_kind: entity_kind
          )
          touch = entity_service.create_touch([
                                                {
                                                  body: 'Hello [contact.name](field://contact.name)',
                                                  timing_mode: 'relative',
                                                  relative_anchor: anchor,
                                                  relative_offset_seconds: 1.hour.to_i,
                                                  relative_time_mode: 'inherit_anchor_time',
                                                  timezone: 'Asia/Almaty'
                                                }
                                              ])

          expect(touch).to be_pending
          expect(touch.remindable).to eq(record)
          expect(touch.target_contact).to eq(contact)
          expect(touch.target_inbox).to eq(inbox)
          expect(touch.relative_anchor).to eq(anchor)
          expect(touch.renderable_body(conversation: touch.target_conversation)).to include("Hello #{contact.name}")
        end
      end
    end

    it 'creates a pending appointment touch without a conversation when a target inbox is selected' do
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        conversation: nil,
        starts_at: 2.hours.from_now,
        ends_at: 2.hours.from_now + 30.minutes
      )
      appointment_service = described_class.new(
        rule: rule,
        account: account,
        record: appointment,
        entity_kind: 'appointment'
      )
      contact_inbox

      touch = appointment_service.create_touch([
                                                 {
                                                   body: 'Ваш визит запланирован',
                                                   target_inbox_id: inbox.id,
                                                   timing_mode: 'relative',
                                                   relative_anchor: 'appointment.starts_at',
                                                   relative_offset_seconds: 30.minutes.to_i,
                                                   timezone: 'Asia/Almaty'
                                                 }
                                               ])

      expect(touch).to be_pending
      expect(touch.remindable).to eq(appointment)
      expect(touch.conversation).to be_nil
      expect(touch.target_conversation).to be_nil
      expect(touch.target_inbox).to eq(inbox)
      expect(touch.target_contact).to eq(contact)
      expect(touch).to be_ready_for_pending
    end

    it 'rejects incomplete relative touch timing before creating the reminder' do
      expect do
        service.create_touch([{ body: 'Incomplete timing', timing_mode: 'relative', relative_anchor: 'touch.created_at' }])
      end.to raise_error(ArgumentError, 'create_touch timing is invalid')
    end

    it 'immediately cancels an automation touch when a same-contact campaign delivery is blocking' do
      campaign = create(:campaign, account: account, inbox: inbox)
      create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, contact: contact, status: :pending)

      touch = service.create_touch([{ body: 'Do not duplicate campaign', delay_minutes: 10 }])

      expect(touch.reload).to be_cancelled
      expect(touch.last_error).to eq('отменен из-за рассылки')
    end

    it 'defers appointment automation touches and reads the current action at materialization' do
      account.enable_features!('deferred_touch_materialization', 'scheduling')
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        conversation: conversation,
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 30.minutes
      )
      action_definition = {
        body: 'Original automation text',
        timing_mode: 'relative',
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.day.to_i,
        timezone: 'UTC'
      }
      appointment_rule = create(
        :automation_rule,
        account: account,
        event_name: 'appointment_created',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
        actions: [{ action_name: 'create_touch', action_params: action_definition }]
      )
      action = appointment_rule.actions.first
      appointment_service = described_class.new(
        rule: appointment_rule,
        account: account,
        record: appointment,
        entity_kind: 'appointment'
      )

      enrollment = appointment_service.create_touch(action['action_params'], action_id: action['action_id'])
      appointment_rule.update!(
        actions: [action.merge('action_params' => action_definition.merge(body: 'Current automation text'))]
      )
      claim = Reminders::MaterializeEnrollmentStepService.new(
        enrollment: enrollment,
        now: enrollment.reload.next_due_at + 1.minute
      ).perform

      expect(enrollment).to be_a(TouchPlanEnrollment)
      expect(claim.reminder.body).to eq('Current automation text')
      expect(claim.reminder.metadata).to include('post_delivery_automation_rule_id' => appointment_rule.id)
      expect(
        appointment_service.create_touch(action['action_params'], action_id: action['action_id']).id
      ).to eq(enrollment.id)
      expect(account.touch_plan_enrollments.where(automation_rule: appointment_rule, remindable: appointment).count).to eq(1)
    end

    it 'cancels a deferred automation enrollment when the source rule is disabled' do
      account.enable_features!('deferred_touch_materialization', 'scheduling')
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        conversation: conversation,
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 30.minutes
      )
      appointment_rule = create(
        :automation_rule,
        account: account,
        event_name: 'appointment_created',
        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
        actions: [
          {
            action_name: 'create_touch',
            action_params: {
              body: 'Deferred automation touch',
              timing_mode: 'relative',
              relative_anchor: 'appointment.starts_at',
              relative_offset_seconds: -1.day.to_i,
              timezone: 'UTC'
            }
          }
        ]
      )
      action = appointment_rule.actions.first
      enrollment = described_class.new(
        rule: appointment_rule,
        account: account,
        record: appointment,
        entity_kind: 'appointment'
      ).create_touch(action['action_params'], action_id: action['action_id'])

      appointment_rule.update!(active: false)
      Reminders::ReconcileEnrollmentService.new(enrollment: enrollment).perform

      expect(enrollment.reload).to be_cancelled
      expect(account.reminders.where(remindable: appointment)).to be_empty
    end

    it 'keeps a post-completion appointment action eligible at activation' do
      account.enable_features!('deferred_touch_materialization', 'scheduling')
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        conversation: conversation,
        status: 'completed'
      )
      appointment_rule = create(
        :automation_rule,
        account: account,
        event_name: 'appointment_completed',
        actions: [
          {
            action_name: 'create_touch',
            action_params: {
              body: 'Post-completion follow-up',
              timing_mode: 'relative',
              relative_anchor: 'touch.created_at',
              relative_offset_seconds: 0,
              timezone: 'UTC'
            }
          }
        ]
      )
      action = appointment_rule.actions.first
      enrollment = described_class.new(
        rule: appointment_rule,
        account: account,
        record: appointment,
        entity_kind: 'appointment'
      ).create_touch(action['action_params'], action_id: action['action_id'])

      claim = Reminders::MaterializeEnrollmentStepService.new(
        enrollment: enrollment,
        now: enrollment.next_due_at + 1.minute
      ).perform

      expect(claim).to be_materialized
      expect(claim.reminder.body).to eq('Post-completion follow-up')
      expect(enrollment.metadata['allow_terminal_at_activation']).to be(true)
    end
  end

  describe '#cancel_touches' do
    it 'cancels only automation-created open touches for the current entity' do
      draft_touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                                      status: :draft, metadata: { touch_source: 'automation' }, body: 'Draft touch')
      pending_touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                                        status: :pending, metadata: { touch_source: 'automation' }, body: 'Pending touch')
      completed_touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                                          status: :completed, metadata: { touch_source: 'automation' }, body: 'Completed touch')
      manual_touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: conversation,
                                       status: :pending, body: 'Manual touch')

      cancelled_count = service.cancel_touches([{}])

      expect(cancelled_count).to eq(2)
      expect(draft_touch.reload).to be_cancelled
      expect(pending_touch.reload).to be_cancelled
      expect(completed_touch.reload).to be_completed
      expect(manual_touch.reload).to be_pending
      expect(pending_touch.last_error).to eq('отменен автоматизацией')
      expect(pending_touch.metadata).to include('cancelled_via' => 'automation_cancel_touches', 'cancel_touches_entity_kind' => 'conversation')
    end

    it 'preserves legacy plan-scoped cancellation across touch sources' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      other_touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      automation_touch = create(:reminder, account: account, remindable: conversation, reminder_group: touch_plan,
                                           status: :pending, metadata: { touch_source: 'automation' })
      captain_touch = create(:reminder, account: account, remindable: conversation, reminder_group: touch_plan,
                                        status: :pending, metadata: { touch_source: 'captain' })
      manual_touch = create(:reminder, account: account, remindable: conversation, reminder_group: touch_plan, status: :pending)
      unrelated_touch = create(:reminder, account: account, remindable: conversation, reminder_group: other_touch_plan,
                                          status: :pending, metadata: { touch_source: 'automation' })

      cancelled_count = service.cancel_touches([{ reminder_group_id: touch_plan.id }])

      expect(cancelled_count).to eq(3)
      expect(automation_touch.reload).to be_cancelled
      expect(captain_touch.reload).to be_cancelled
      expect(manual_touch.reload).to be_cancelled
      expect(unrelated_touch.reload).to be_pending
    end
  end
end
