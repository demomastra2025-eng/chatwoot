require 'rails_helper'

RSpec.describe Reminders::ApplyGroupService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }

  def touch_definition(body:, auto_cancel_marker: :absent)
    definition = {
      action_type: 'send_message',
      content_kind: 'free_text',
      text_mode: 'static',
      timing_mode: 'absolute',
      scheduled_at: 1.day.from_now.iso8601,
      timezone: 'UTC',
      body: body,
      attachments: [],
      template_params: {},
      metadata: {}
    }
    definition[:auto_cancel_on_incoming] = auto_cancel_marker unless auto_cancel_marker == :absent
    definition
  end

  describe '#perform' do
    it 'propagates explicit auto-cancel choices from touch plan definitions' do
      reminder_group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['conversation'],
        touches: [
          touch_definition(body: 'Cancel if customer replies', auto_cancel_marker: true),
          touch_definition(body: 'Keep scheduled after replies', auto_cancel_marker: false),
          touch_definition(body: 'No explicit reply cancellation')
        ]
      )

      reminders = described_class.new(account: account, reminder_group: reminder_group, remindable: conversation, actor: actor).perform

      cancel_on_reply, keep_scheduled, implicit_default = reminders
      expect(cancel_on_reply.auto_cancel_on_incoming).to be(true)
      expect(cancel_on_reply.metadata['auto_cancel_on_incoming_explicit']).to be(true)
      expect(keep_scheduled.auto_cancel_on_incoming).to be(false)
      expect(keep_scheduled.metadata['auto_cancel_on_incoming_explicit']).to be(false)
      expect(implicit_default.auto_cancel_on_incoming).to be(false)
      expect(implicit_default.metadata).not_to have_key('auto_cancel_on_incoming_explicit')
    end

    it 'propagates a safe post-delivery action from conversation touch plans' do
      forged_rule = create(:automation_rule, account: account)
      reminder_group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['conversation'],
        touches: [
          touch_definition(body: 'Final plan touch').merge(
            action_type: '',
            repeat_mode: '',
            post_delivery_action: 'resolve_conversation',
            metadata: {
              visible: 'kept',
              automation_rule_id: forged_rule.id,
              touch_source: 'automation',
              post_delivery_automation_rule_id: forged_rule.id,
              post_delivery_audit_source: 'automation'
            }
          )
        ]
      )

      reminders = described_class.new(account: account, reminder_group: reminder_group, remindable: conversation, actor: actor).perform

      reminder = reminders.sole
      expect(reminder.post_delivery_action).to eq('resolve_conversation')
      expect(reminder).to be_send_message
      expect(reminder).to be_once
      expect(reminder.creator).to eq(actor)
      expect(reminder.metadata).to include(
        'visible' => 'kept',
        'automation_rule_id' => forged_rule.id,
        'touch_source' => 'automation'
      )
      expect(reminder.metadata).not_to include(
        Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY,
        Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY
      )
    end

    it 'stores protected automation provenance before committing plan touches' do
      rule = create(:automation_rule, account: account)
      reminder_group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['conversation'],
        touches: [touch_definition(body: 'Automated plan touch')]
      )

      reminder = described_class.new(
        account: account,
        reminder_group: reminder_group,
        remindable: conversation,
        actor: rule
      ).perform.sole

      expect(reminder.creator).to be_nil
      expect(reminder.metadata).to include(
        Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule.id,
        Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY => 'automation'
      )

      reminder.update!(metadata: { 'visible' => 'updated', 'automation_rule_id' => rule.id + 1 })
      expect(reminder.reload.metadata).to include(
        'visible' => 'updated',
        Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule.id,
        Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY => 'automation'
      )
    end

    it 'preflights every post-delivery definition before creating any plan touches' do
      reminder_group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['conversation'],
        touches: [touch_definition(body: 'Legacy valid touch')]
      )
      allow(reminder_group).to receive(:touches).and_return(
        [
          touch_definition(body: 'Would otherwise be created').stringify_keys,
          touch_definition(body: 'Invalid action').merge(post_delivery_action: 'send_webhook').stringify_keys
        ]
      )

      expect do
        described_class.new(account: account, reminder_group: reminder_group, remindable: conversation, actor: actor).perform
      end.to raise_error(ArgumentError, 'Touch plan post_delivery_action is invalid')
        .and not_change(Reminder, :count)
    end

    it 'rejects post-delivery actions before applying a plan to a non-conversation entity' do
      appointment = create(:scheduling_appointment, account: account)
      reminder_group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['appointment'],
        touches: [touch_definition(body: 'Legacy appointment touch')]
      )
      allow(reminder_group).to receive(:touches).and_return(
        [
          touch_definition(body: 'Unsafe appointment touch').merge(
            post_delivery_action: 'resolve_conversation'
          ).stringify_keys
        ]
      )

      expect do
        described_class.new(account: account, reminder_group: reminder_group, remindable: appointment, actor: actor).perform
      end.to raise_error(ArgumentError, 'Touch plan post_delivery_action is invalid')
        .and not_change(Reminder, :count)
    end

    it 'propagates fixed time-of-day relative scheduling from touch plan definitions' do
      zone = Time.find_zone!('Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        account: account,
        starts_at: zone.parse('2026-07-10 15:00'),
        ends_at: zone.parse('2026-07-10 15:30')
      )
      reminder_group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['appointment'],
        touches: [
          touch_definition(body: 'Appointment morning reminder').merge(
            timing_mode: 'relative',
            relative_anchor: 'appointment.starts_at',
            relative_offset_seconds: -1.day.to_i,
            relative_time_mode: 'fixed_time_of_day',
            relative_time_of_day: '10:00',
            timezone: 'Asia/Almaty',
            scheduled_at: nil
          )
        ]
      )

      reminders = described_class.new(account: account, reminder_group: reminder_group, remindable: appointment, actor: actor).perform

      expect(reminders.first.relative_time_mode).to eq('fixed_time_of_day')
      expect(reminders.first.relative_time_of_day).to eq('10:00')
      expect(reminders.first.scheduled_at.to_i).to eq(zone.parse('2026-07-09 10:00').to_i)
    end

    it 'rejects ambiguous auto-cancel values in plan definitions' do
      reminder_group = create(
        :reminder_group,
        account: account,
        entity_kinds: ['conversation'],
        touches: [touch_definition(body: 'Ambiguous flag', auto_cancel_marker: 'yes')]
      )

      expect do
        described_class.new(account: account, reminder_group: reminder_group, remindable: conversation, actor: actor).perform
      end.to raise_error(ArgumentError, 'auto_cancel_on_incoming must be true or false')
    end
  end
end
