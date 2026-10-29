require 'rails_helper'

RSpec.describe Reminders::SuppressedContactPolicy do
  let(:account) do
    create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap do |record|
      record.enable_features!('scheduling', 'deferred_touch_materialization')
    end
  end
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:inbox) { shared_phone_cloud_inbox(account) }

  def status_condition
    { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['scheduled'], 'query_operator' => nil }
  end

  def build_immediate_rule
    create(
      :automation_rule,
      account: account,
      event_name: 'appointment_rescheduled',
      conditions: [status_condition],
      actions: [{
        action_name: 'create_touch',
        action_params: { body: 'Ваша запись создана', delay_minutes: 5, target_inbox_id: inbox.id }
      }]
    )
  end

  def build_deferred_rule
    create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      conditions: [status_condition],
      actions: [{
        action_name: 'create_touch',
        action_params: {
          body: 'Напоминание о визите завтра',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.day.to_i,
          target_inbox_id: inbox.id,
          timezone: 'UTC'
        }
      }]
    )
  end

  def touch_messages(touch)
    Message.outgoing.where(account_id: account.id).where("additional_attributes ->> 'touch_id' = ?", touch.id.to_s)
  end

  describe 'Contact suppression helpers' do
    it 'detects suppression across Contact, Conversation, Appointment, Deal, and Task', :aggregate_failures do
      normal = create(:contact, account: account, name: 'Normal')
      muted = create(:contact, account: account, name: 'Пмсп', notifications_muted: true)
      blocked = create(:contact, account: account, name: 'Blocked', blocked: true)

      expect(normal.automation_notifications_suppressed?).to be(false)
      expect(muted.automation_notifications_suppressed?).to be(true)
      expect(blocked.automation_notifications_suppressed?).to be(true)

      _, muted_conv = shared_phone_chat(account, muted, inbox, '77001112201')
      _, normal_conv = shared_phone_chat(account, normal, inbox, '77001112202')
      expect(Contact.automation_notifications_suppressed_for?(muted_conv, account_id: account.id)).to be(true)
      expect(Contact.automation_notifications_suppressed_for?(normal_conv, account_id: account.id)).to be(false)

      appt = create(:scheduling_appointment, account: account, resource: resource, contact: normal,
                                             patient_contact: muted, starts_at: 2.days.from_now,
                                             ends_at: 2.days.from_now + 30.minutes)
      expect(Contact.automation_notifications_suppressed_for?(appt, account_id: account.id)).to be(true)

      deal = create(:crm_deal, account: account)
      create(:crm_deal_contact, account: account, deal: deal, contact: blocked)
      task = create(:crm_task, account: account, deal: deal)
      expect(Contact.automation_notifications_suppressed_for?(deal, account_id: account.id)).to be(true)
      expect(Contact.automation_notifications_suppressed_for?(task, account_id: account.id)).to be(true)
    end
  end

  describe 'SharedPhone technical placeholder isolation (Пмсп / Стационар / Бронь)' do
    let(:holder) { create(:contact, account: account, name: 'Holder WhatsApp', phone_number: SharedPhoneHelpers::FAMILY_PHONE) }
    let(:holder_conversation) { shared_phone_chat(account, holder, inbox, SharedPhoneHelpers::FAMILY_PHONE.delete('+')).last }
    let(:real_patient) { shared_phone_card(account, holder, name: 'Алия Пациент', code: 'aliya-real-1') }

    before do
      enable_shared_phone_switches!
      holder_conversation
    end

    def build_shared_appointment(patient_card)
      create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        contact: holder,
        patient_contact: patient_card,
        conversation: holder_conversation,
        status: 'scheduled',
        starts_at: 3.days.from_now,
        ends_at: 3.days.from_now + 30.minutes
      )
    end

    def run_appointment_rules(rules, appointment)
      rules.each { |rule| AutomationRules::AppointmentActionService.new(rule, account, appointment).perform }
    end

    def build_processing_touch(appointment, body:)
      create(
        :reminder,
        account: account,
        remindable: appointment,
        conversation: holder_conversation,
        touch_conversation: holder_conversation,
        target_contact: holder,
        status: :processing,
        body: body,
        scheduled_at: 1.minute.ago
      )
    end

    it 'skips touch, enrollment, and backfill for a muted placeholder while creating them for real patients',
       :aggregate_failures do
      placeholder = shared_phone_card(account, holder, name: 'Пмсп', code: 'pmsp-tech-1')
      placeholder.update!(notifications_muted: true)
      muted_appt = build_shared_appointment(placeholder)
      real_appt = build_shared_appointment(real_patient)
      rules = [build_immediate_rule, build_deferred_rule]

      run_appointment_rules(rules, muted_appt)
      run_appointment_rules(rules, real_appt)

      expect(account.reminders.where(remindable: muted_appt)).to be_empty
      expect(account.touch_plan_enrollments.where(remindable: muted_appt)).to be_empty
      expect(account.reminders.where(remindable: real_appt).count).to eq(1)
      expect(account.touch_plan_enrollments.where(remindable: real_appt).count).to eq(1)

      plan_ids = Reminders::BackfillAutomationRuleEnrollmentsService
                 .new(rule: rules.last, activation_time: Time.current).plan.pluck(:appointment_id)
      expect(plan_ids).not_to include(muted_appt.id)
    end

    it 'cancels a pre-existing processing touch at ExecuteService without sending, while delivering for real patients',
       :aggregate_failures do
      placeholder = shared_phone_card(account, holder, name: 'Стационар', code: 'stac-1')
      placeholder_touch = build_processing_touch(build_shared_appointment(placeholder), body: 'Для Стационар')
      real_touch = build_processing_touch(build_shared_appointment(real_patient), body: 'Для Алии')

      placeholder.update_columns(notifications_muted: true) # rubocop:disable Rails/SkipsModelValidations
      Reminders::ExecuteService.new(reminder: placeholder_touch).perform
      Reminders::ExecuteService.new(reminder: real_touch).perform

      expect(placeholder_touch.reload).to have_attributes(
        status: 'cancelled',
        last_error: described_class::MUTED_CANCEL_REASON
      )
      expect(placeholder_touch.metadata).to include(
        'cancelled_via' => described_class::MUTED_CANCELLED_VIA,
        'suppressed_contact_id' => placeholder.id
      )
      expect(touch_messages(placeholder_touch)).to be_empty
      expect(real_touch.reload).to be_completed
      expect(touch_messages(real_touch).count).to eq(1)
    end

    it 'cancels only the muted placeholder open reminders and enrollments on mute transition',
       :aggregate_failures do
      card = shared_phone_card(account, holder, name: 'Бронь', code: 'bron-1')
      card_appt = build_shared_appointment(card)
      real_appt = build_shared_appointment(real_patient)
      holder_appt = create(:scheduling_appointment, account: account, resource: resource, contact: holder,
                                                    conversation: holder_conversation, status: 'scheduled',
                                                    starts_at: 3.days.from_now, ends_at: 3.days.from_now + 30.minutes)
      rules = [build_immediate_rule, build_deferred_rule]
      [card_appt, real_appt, holder_appt].each { |appt| run_appointment_rules(rules, appt) }

      already_sent = build_processing_touch(card_appt, body: 'Already materialized')
      already_sent.mark_delivery_materialized!(999_999)

      card.update!(notifications_muted: true)

      card_touch = account.reminders.where(remindable: card_appt).where.not(id: already_sent.id).sole
      expect(card_touch).to have_attributes(status: 'cancelled', last_error: described_class::MUTED_CANCEL_REASON)
      expect(account.touch_plan_enrollments.find_by!(remindable: card_appt)).to be_cancelled
      expect(already_sent.reload).to be_processing
      expect(account.reminders.find_by!(remindable: real_appt)).to be_pending
      expect(account.touch_plan_enrollments.find_by!(remindable: real_appt)).to be_active
      expect(account.reminders.find_by!(remindable: holder_appt)).to be_pending
      expect(account.touch_plan_enrollments.find_by!(remindable: holder_appt)).to be_active
    end

    it 'cancels an active enrollment at MaterializeEnrollmentStepService if muted without callback',
       :aggregate_failures do
      card = shared_phone_card(account, holder, name: 'Пмсп 2', code: 'pmsp-2')
      appt = build_shared_appointment(card)
      AutomationRules::AppointmentActionService.new(build_deferred_rule, account, appt).perform
      enrollment = account.touch_plan_enrollments.find_by!(remindable: appt)

      card.update_columns(notifications_muted: true) # rubocop:disable Rails/SkipsModelValidations
      Reminders::MaterializeEnrollmentStepService.new(
        enrollment: enrollment,
        now: enrollment.next_due_at + 1.minute
      ).perform

      expect(account.reminders.where(remindable: appt)).to be_empty
      expect(enrollment.reload).to be_cancelled
      expect(enrollment.metadata).to include(
        'cancelled_via' => described_class::MUTED_CANCELLED_VIA,
        'suppressed_contact_id' => card.id
      )
    end
  end

  describe 'blocked contact suppression and manual operator replies' do
    it 'cancels pending touches on block and suppresses automation send_message while allowing private notes and manual replies',
       :aggregate_failures do
      user = create(:user, account: account, role: :administrator)
      contact = create(:contact, account: account, name: 'Client', phone_number: '+77005556677')
      _, conversation = shared_phone_chat(account, contact, inbox, '77005556677')

      follow_up = AutomationRules::TouchActionService.new(
        rule: build_immediate_rule, account: account, record: conversation, entity_kind: 'conversation'
      ).create_touch(body: 'Delayed follow-up', delay_minutes: 30)
      contact.update!(blocked: true)

      expect(follow_up.reload).to have_attributes(status: 'cancelled', last_error: described_class::BLOCKED_CANCEL_REASON)
      expect(follow_up.metadata).to include('cancelled_via' => described_class::BLOCKED_CANCELLED_VIA)

      conv_rule = create(
        :automation_rule,
        account: account,
        event_name: 'conversation_updated',
        conditions: [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['open'], 'query_operator' => nil }],
        actions: [
          { action_name: 'send_message', action_params: ['Automated outbound'] },
          { action_name: 'add_private_note', action_params: ['Internal note still works'] }
        ]
      )
      expect { AutomationRules::ActionService.new(conv_rule, account, conversation).perform }
        .to change { conversation.messages.where(private: true).count }.by(1)
      expect(conversation.messages.where(private: false, message_type: :outgoing)).to be_empty

      contact.update!(blocked: false, notifications_muted: true)
      manual_msg = Messages::MessageBuilder.new(
        user, conversation, ActionController::Parameters.new(content: 'Manual reply from operator', private: false)
      ).perform
      expect(manual_msg).to be_persisted
    end
  end
end
