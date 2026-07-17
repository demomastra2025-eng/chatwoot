require 'rails_helper'

RSpec.describe Reminder do
  describe '#renderable_body' do
    it 'renders manual touch field references across contact, conversation, deal, task, appointment, and custom fields' do
      account = create(:account)
      account.enable_features!('crm_deals', 'crm_tasks', 'scheduling', 'communication_threads')
      owner = create(:user, :administrator, account: account, name: 'Olivia Owner')
      creator = create(:user, :administrator, account: account, name: 'Chris Creator')
      assignee = create(:user, :administrator, account: account, name: 'Alex Assignee')
      team = create(:team, account: account, name: 'Sales Team')
      company = create(:company, account: account, name: 'Acme Clinic')
      pipeline = create(:crm_pipeline, account: account, name: 'Primary Pipeline')
      stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified')

      create(
        :custom_attribute_definition,
        account: account,
        attribute_model: :contact_attribute,
        attribute_key: 'vip_level',
        attribute_display_name: 'VIP Level'
      )
      create(
        :custom_attribute_definition,
        account: account,
        attribute_model: :conversation_attribute,
        attribute_key: 'order_id',
        attribute_display_name: 'Order ID'
      )
      create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'sales_region', label: 'Sales Region')
      create(:crm_field_definition, account: account, entity_kind: 'task', key: 'follow_up_channel', label: 'Follow Up Channel')
      create(:crm_field_definition, account: account, entity_kind: 'appointment', key: 'visit_room', label: 'Visit Room')

      contact = create(
        :contact,
        account: account,
        name: 'Jane Patient',
        email: 'jane.patient@example.com',
        phone_number: '+77005550101',
        identifier: 'CRM-42',
        contact_type: 'customer',
        custom_attributes: { 'vip_level' => 'gold' }
      )
      inbox = create(:inbox, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: contact.phone_number)
      conversation = create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        assignee: assignee,
        status: 'pending',
        priority: 'urgent',
        custom_attributes: { 'order_id' => 'ORD-1' }
      )
      conversation.label_list.add('sales')
      conversation.label_list.add('vip')
      conversation.save!

      communication_thread = conversation.reload.communication_thread || conversation.refresh_communication_thread!

      deal = create(
        :crm_deal,
        account: account,
        title: 'Apartment Purchase',
        description: 'Client wants a two-room apartment',
        amount_minor: 1_500_000,
        currency: 'KZT',
        expected_close_on: Date.new(2026, 7, 30),
        win_probability: 80,
        closed_at: Time.zone.parse('2026-07-20 12:00'),
        external_ref: 'DEAL-1',
        pipeline: pipeline,
        stage: stage,
        owner: owner,
        creator: creator,
        team: team,
        company: company,
        originating_conversation: conversation,
        originating_communication_thread: communication_thread,
        custom_attributes: { 'sales_region' => 'Almaty' }
      )
      status = create(:crm_task_status, account: account, name: 'In Progress')
      task = create(
        :crm_task,
        account: account,
        title: 'Call client',
        description: 'Clarify preferred district',
        due_at: Time.zone.parse('2026-07-21 15:00'),
        start_at: Time.zone.parse('2026-07-21 14:00'),
        priority: 'high',
        completed_at: Time.zone.parse('2026-07-21 16:00'),
        external_ref: 'TASK-1',
        status: status,
        assignee: assignee,
        creator: creator,
        team: team,
        deal: deal,
        originating_conversation: conversation,
        custom_attributes: { 'follow_up_channel' => 'telegram' }
      )
      service = create(
        :scheduling_service,
        account: account,
        name: 'Consultation',
        base_price: 20_000,
        duration_min: 45,
        service_type: 'consultation'
      )
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        company: company,
        conversation: conversation,
        created_by: creator,
        owner: owner,
        service: service,
        starts_at: Time.zone.parse('2026-07-22 10:00'),
        ends_at: Time.zone.parse('2026-07-22 10:45'),
        duration_min: 45,
        status: 'scheduled',
        appointment_type: 'primary',
        client_name: 'Jane Patient',
        client_phone: '+77005550101',
        client_identifier: 'IIN-1',
        client_birth_date: Date.new(1990, 1, 2),
        client_gender: 'female',
        client_comment: 'Prefers morning',
        source: 'manual',
        external_ref: 'APPT-1',
        payment_status: 'paid',
        service_name_snapshot: 'Consultation',
        service_type_snapshot: 'consultation',
        service_duration_min_snapshot: 45,
        service_amount: 20_000,
        compensation_type_snapshot: 'fixed',
        compensation_value_snapshot: 5_000,
        compensation_percent_snapshot: 0,
        prepaid_amount: 10_000,
        prepaid_payment_method: 'card',
        settlement_amount: 10_000,
        settlement_payment_method: 'cash',
        custom_attributes: { 'visit_room' => 'B12' }
      )

      deal.reload
      task.reload
      appointment.reload

      field_values = {
        'contact.id' => contact.id,
        'contact.name' => contact.name,
        'contact.email' => contact.email,
        'contact.phone_number' => contact.phone_number,
        'contact.identifier' => contact.identifier,
        'contact.contact_type' => contact.contact_type,
        'contact.custom_attributes.vip_level' => 'gold',
        'conversation.id' => conversation.id,
        'conversation.display_id' => conversation.display_id,
        'conversation.inbox_id' => conversation.inbox_id,
        'conversation.contact_id' => conversation.contact_id,
        'conversation.status' => conversation.status,
        'conversation.priority' => conversation.priority,
        'conversation.label_list' => conversation.label_list.join(', '),
        'conversation.custom_attributes.order_id' => 'ORD-1',
        'deal.id' => deal.id,
        'deal.title' => deal.title,
        'deal.description' => deal.description,
        'deal.amount' => '15000',
        'deal.currency' => deal.currency,
        'deal.expected_close_on' => deal.expected_close_on,
        'deal.win_probability' => deal.win_probability,
        'deal.closed_at' => deal.closed_at,
        'deal.external_ref' => deal.external_ref,
        'deal.pipeline_id' => pipeline.id,
        'deal.pipeline_name' => pipeline.name,
        'deal.stage_id' => stage.id,
        'deal.stage_name' => stage.name,
        'deal.owner_id' => owner.id,
        'deal.owner_name' => owner.name,
        'deal.creator_id' => creator.id,
        'deal.creator_name' => creator.name,
        'deal.team_id' => team.id,
        'deal.team_name' => team.name,
        'deal.company_id' => company.id,
        'deal.company_name' => company.name,
        'deal.originating_conversation_id' => conversation.id,
        'deal.custom_attributes.sales_region' => 'Almaty',
        'task.id' => task.id,
        'task.title' => task.title,
        'task.description' => task.description,
        'task.due_at' => task.due_at,
        'task.start_at' => task.start_at,
        'task.priority' => task.priority,
        'task.completed_at' => task.completed_at,
        'task.external_ref' => task.external_ref,
        'task.status_id' => status.id,
        'task.status_name' => status.name,
        'task.assignee_id' => task.assignee_id,
        'task.assignee_name' => task.assignee&.name,
        'task.creator_id' => creator.id,
        'task.creator_name' => creator.name,
        'task.team_id' => team.id,
        'task.team_name' => team.name,
        'task.deal_id' => deal.id,
        'task.deal_title' => deal.title,
        'task.originating_conversation_id' => conversation.id,
        'task.custom_attributes.follow_up_channel' => 'telegram',
        'appointment.id' => appointment.id,
        'appointment.resource_id' => appointment.resource_id,
        'appointment.contact_id' => contact.id,
        'appointment.service_id' => service.id,
        'appointment.company_id' => company.id,
        'appointment.conversation_id' => conversation.id,
        'appointment.created_by_id' => creator.id,
        'appointment.starts_at' => appointment.starts_at,
        'appointment.ends_at' => appointment.ends_at,
        'appointment.duration_min' => appointment.duration_min,
        'appointment.status' => appointment.status,
        'appointment.appointment_type' => appointment.appointment_type,
        'appointment.client_name' => appointment.client_name,
        'appointment.client_phone' => appointment.client_phone,
        'appointment.client_identifier' => appointment.client_identifier,
        'appointment.client_birth_date' => appointment.client_birth_date,
        'appointment.client_gender' => appointment.client_gender,
        'appointment.client_comment' => appointment.client_comment,
        'appointment.source' => appointment.source,
        'appointment.external_ref' => appointment.external_ref,
        'appointment.payment_status' => appointment.payment_status,
        'appointment.service_name_snapshot' => appointment.service_name_snapshot,
        'appointment.service_type_snapshot' => appointment.service_type_snapshot,
        'appointment.service_duration_min_snapshot' => appointment.service_duration_min_snapshot,
        'appointment.service_amount' => appointment.service_amount,
        'appointment.compensation_type_snapshot' => appointment.compensation_type_snapshot,
        'appointment.compensation_value_snapshot' => appointment.compensation_value_snapshot,
        'appointment.compensation_percent_snapshot' => appointment.compensation_percent_snapshot,
        'appointment.prepaid_amount' => appointment.prepaid_amount,
        'appointment.prepaid_payment_method' => appointment.prepaid_payment_method,
        'appointment.settlement_amount' => appointment.settlement_amount,
        'appointment.settlement_payment_method' => appointment.settlement_payment_method,
        'appointment.custom_attributes.visit_room' => 'B12'
      }
      body = field_values.keys.map { |field_id| "#{field_id}: [#{field_id}](field://#{field_id})" }.join("\n")
      reminder = build(
        :reminder,
        account: account,
        creator: creator,
        owner: owner,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        body: body
      )

      rendered = reminder.renderable_body(conversation: conversation, sender: owner)

      field_values.each do |field_id, value|
        expect(rendered).to include("#{field_id}: #{value}")
      end
    end
  end

  describe 'relative scheduling' do
    it 'materializes scheduled_at from the relative anchor' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.created_at',
        relative_offset_seconds: 3600,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq((conversation.created_at + 1.hour).to_i)
    end

    it 'materializes relative scheduling on the calculated date with a fixed time of day' do
      zone = Time.find_zone!('Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        starts_at: zone.parse('2026-07-10 15:00'),
        ends_at: zone.parse('2026-07-10 15:30')
      )
      reminder = build(
        :reminder,
        account: appointment.account,
        remindable: appointment,
        timing_mode: :relative,
        relative_anchor: 'appointment.starts_at',
        relative_offset_seconds: -1.day.to_i,
        relative_time_mode: 'fixed_time_of_day',
        relative_time_of_day: '10:00',
        timezone: 'Asia/Almaty',
        body: 'Fixed time reminder',
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq(zone.parse('2026-07-09 10:00').to_i)
      expect(reminder.last_materialized_anchor_at.to_i).to eq(appointment.starts_at.to_i)
    end

    it 'requires HH:MM time when relative scheduling uses fixed time of day' do
      reminder = build(
        :reminder,
        timing_mode: :relative,
        relative_anchor: 'touch.created_at',
        relative_offset_seconds: 1.hour.to_i,
        relative_time_mode: 'fixed_time_of_day',
        relative_time_of_day: nil,
        scheduled_at: nil
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:relative_time_of_day]).to include(
        'must be present for fixed time of day relative touches'
      )
    end

    it 'does not rematerialize scheduled_at when manual schedule override is enabled' do
      appointment = create(:scheduling_appointment, starts_at: 2.days.from_now)
      manual_scheduled_at = 3.days.from_now.change(sec: 0)
      reminder = build(
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
        body: 'Manual override reminder'
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq(manual_scheduled_at.to_i)
      expect(reminder.last_materialized_anchor_at).to be_nil
    end

    it 'materializes touch.created_at relative scheduling from current time for new touches' do
      freeze_time do
        conversation = create(:conversation)
        reminder = build(
          :reminder,
          account: conversation.account,
          touch_conversation: conversation,
          conversation: conversation,
          remindable: conversation,
          timing_mode: :relative,
          relative_anchor: 'touch.created_at',
          relative_offset_seconds: 180,
          scheduled_at: nil
        )

        reminder.validate

        expect(reminder.scheduled_at).to eq(3.minutes.from_now)
        expect(reminder).to be_pending
      end
    end

    it 'does not materialize missing last incoming message anchors' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.last_incoming_message_at',
        relative_offset_seconds: 180,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at).to be_nil
      expect(reminder).to be_draft
    end

    it 'materializes scheduled_at from the last outgoing conversation message' do
      conversation = create(:conversation)
      outgoing_message = create(
        :message,
        account: conversation.account,
        conversation: conversation,
        inbox: conversation.inbox,
        message_type: :outgoing,
        private: false
      )
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.last_outgoing_message_at',
        relative_offset_seconds: 1800,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq(
        (outgoing_message.created_at + 30.minutes).to_i
      )
    end

    it 'materializes scheduled_at from waiting since when the conversation is awaiting a reply' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.waiting_since',
        relative_offset_seconds: 900,
        scheduled_at: nil
      )

      reminder.validate

      expect(reminder.scheduled_at.to_i).to eq(
        (conversation.waiting_since + 15.minutes).to_i
      )
    end
  end

  describe 'duplicate protection' do
    it 'blocks duplicate open touches with the same fingerprint' do
      conversation = create(:conversation)
      scheduled_at = 1.hour.from_now.change(usec: 0)
      create(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        body: 'Same touch',
        scheduled_at: scheduled_at
      )
      duplicate = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        body: 'Same touch',
        scheduled_at: scheduled_at
      )

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:base]).to include('An open touch with the same content already exists')
    end
  end

  describe 'official WhatsApp delivery policy' do
    it 'rejects manual free-text touches when the scheduled delivery is outside the 24-hour window' do
      account = create(:account)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

      reminder = build(
        :reminder,
        account: account,
        touch_conversation: conversation,
        scheduled_at: 25.hours.from_now,
        body: 'Future free text'
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:base]).to include(Outbound::DeliveryPolicy::WHATSAPP_TEMPLATE_REQUIRED_REASON)
    end

    it 'treats AI-generated touch instructions as free text for the official WhatsApp window policy' do
      account = create(:account)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

      reminder = build(
        :reminder,
        account: account,
        touch_conversation: conversation,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a friendly follow-up',
        scheduled_at: 25.hours.from_now
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:base]).to include(Outbound::DeliveryPolicy::WHATSAPP_TEMPLATE_REQUIRED_REASON)
    end

    it 'rejects channel templates with missing required parameters before execution' do
      account = create(:account)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_channel.update!(
        message_templates: [
          {
            'name' => 'ticket_status_updated',
            'status' => 'approved',
            'category' => 'MARKETING',
            'language' => 'en',
            'components' => [{ 'type' => 'BODY', 'text' => 'Hi {{name}}, ticket {{ticket_id}} is updated' }]
          }
        ]
      )
      whatsapp_inbox = whatsapp_channel.inbox
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
      conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox)
      reminder = build(
        :reminder,
        account: account,
        touch_conversation: conversation,
        content_kind: :channel_template,
        body: nil,
        template_params: {
          name: 'ticket_status_updated',
          language: 'en',
          processed_params: { body: { name: 'John' } }
        }
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:base]).to include('Template params missing required values: body.ticket_id')
    end
  end

  describe 'auto-cancel defaults' do
    it 'defaults direct reminder creation to not auto-cancel on incoming replies' do
      reminder = create(:reminder)

      expect(reminder.auto_cancel_on_incoming).to be(false)
    end
  end

  describe 'status defaults' do
    it 'falls back to draft when routing is incomplete' do
      account = create(:account)
      creator = create(:user, account: account, role: :administrator)
      reminder = described_class.new(
        account: account,
        creator: creator,
        owner: creator,
        action_type: :send_message,
        content_kind: :free_text,
        text_mode: :static,
        timing_mode: :absolute,
        scheduled_at: 1.hour.from_now,
        timezone: 'UTC',
        body: 'Draft me'
      )

      reminder.validate

      expect(reminder).to be_draft
    end

    it 'does not treat a contact without a channel route as resolved' do
      account = create(:account)
      creator = create(:user, account: account, role: :administrator)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      contact = create(:contact, account: account, phone_number: nil, email: nil)
      reminder = described_class.new(
        account: account,
        creator: creator,
        owner: creator,
        action_type: :send_message,
        content_kind: :free_text,
        text_mode: :static,
        timing_mode: :absolute,
        target_inbox: whatsapp_inbox,
        target_contact: contact,
        scheduled_at: 1.hour.from_now,
        timezone: 'UTC',
        body: 'Unroutable touch'
      )

      reminder.validate

      expect(reminder).to be_draft
      expect(reminder).not_to be_ready_for_pending
    end

    it 'rejects a target contact inbox that belongs to another target contact' do
      account = create(:account)
      creator = create(:user, account: account, role: :administrator)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      target_contact = create(:contact, account: account, phone_number: '+77001112233')
      other_contact = create(:contact, account: account, phone_number: '+77004445566')
      target_contact_inbox = create(:contact_inbox, contact: target_contact, inbox: whatsapp_inbox)
      reminder = described_class.new(
        account: account,
        creator: creator,
        owner: creator,
        action_type: :send_message,
        content_kind: :free_text,
        text_mode: :static,
        timing_mode: :absolute,
        target_inbox: whatsapp_inbox,
        target_contact: other_contact,
        target_contact_inbox: target_contact_inbox,
        scheduled_at: 1.hour.from_now,
        timezone: 'UTC',
        body: 'Mismatched touch'
      )

      reminder.validate

      expect(reminder.errors[:target_contact]).to include('must match the other target associations')
    end

    it 'rejects a target conversation that belongs to another target contact' do
      account = create(:account)
      creator = create(:user, account: account, role: :administrator)
      whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      whatsapp_inbox = whatsapp_channel.inbox
      target_contact = create(:contact, account: account, phone_number: '+77001112233')
      other_contact = create(:contact, account: account, phone_number: '+77004445566')
      target_contact_inbox = create(:contact_inbox, contact: target_contact, inbox: whatsapp_inbox)
      target_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: target_contact, contact_inbox: target_contact_inbox)
      reminder = described_class.new(
        account: account,
        creator: creator,
        owner: creator,
        action_type: :send_message,
        content_kind: :free_text,
        text_mode: :static,
        timing_mode: :absolute,
        target_inbox: whatsapp_inbox,
        target_contact: other_contact,
        target_conversation: target_conversation,
        scheduled_at: 1.hour.from_now,
        timezone: 'UTC',
        body: 'Mismatched conversation touch'
      )

      reminder.validate

      expect(reminder.errors[:target_contact]).to include('must match the other target associations')
    end

    it 'keeps agent touches pending when route and instructions are ready' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        text_mode: :agent,
        body: nil,
        instructions: 'Write a short and helpful follow-up'
      )

      reminder.validate

      expect(reminder).to be_pending
      expect(reminder).to be_ready_for_pending
    end
  end

  describe 'text mode normalization' do
    it 'detects Liquid syntax as dynamic automatically' do
      reminder = build(:reminder, body: 'Hello {{contact.name}}', text_mode: :static)

      reminder.validate

      expect(reminder.text_mode).to eq('dynamic')
    end

    it 'detects field references as dynamic automatically' do
      reminder = build(:reminder, body: 'Hello [Name](field://contact.name)')

      reminder.validate

      expect(reminder.text_mode).to eq('dynamic')
    end

    it 'ignores Liquid syntax inside code blocks for detection' do
      reminder = build(:reminder, body: 'Use `{{contact.name}}` as an example')

      reminder.validate

      expect(reminder.text_mode).to eq('static')
    end
  end

  describe 'processing claim integrity' do
    it 'strips reserved internal metadata during ordinary creation' do
      reminder = create(
        :reminder,
        metadata: {
          'visible' => 'kept',
          'processing_claim_token' => 'forged-claim',
          'delivery_materialized_message_id' => 123,
          'delivery_dispatched_message_id' => 123,
          'post_delivery_automation_rule_id' => 456,
          'post_delivery_audit_source' => 'automation'
        }
      )

      expect(reminder.reload.metadata).to eq('visible' => 'kept')
    end

    it 'preserves the reserved claim token when metadata is replaced during processing' do
      reminder = create(:reminder, status: :pending, metadata: { 'visible' => 'old' })
      active_claim = reminder.mark_processing!

      reminder.update!(
        metadata: { 'processing_claim_token' => 'attacker-claim', 'visible' => 'updated' }
      )

      expect(reminder.reload.metadata).to include(
        'processing_claim_token' => active_claim,
        'visible' => 'updated'
      )
    end
  end

  describe '#approve!' do
    it 'does not reopen a completed touch' do
      reminder = create(:reminder, status: :completed, completed_at: Time.current)

      reminder.approve!

      expect(reminder.reload).to be_completed
    end

    it 'clears old delivery state when retrying a failed touch' do
      reminder = create(:reminder, status: :pending)
      reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)
      reminder.mark_delivery_dispatched!(123)
      reminder.fail!('retry me')

      reminder.approve!

      expect(reminder.reload).to be_pending
      expect(reminder.metadata.keys & Reminder::INTERNAL_METADATA_KEYS).to be_empty
    end

    it 'preserves trusted automation provenance while clearing transient retry state' do
      reminder = create(:reminder, status: :pending)
      rule = create(:automation_rule, account: reminder.account)
      reminder.mark_automation_provenance!(rule)
      reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)
      reminder.fail!('retry me')

      reminder.approve!

      expect(reminder.reload.metadata).to include(
        Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule.id,
        Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY => 'automation'
      )
      expect(reminder.metadata.keys & Reminder::TRANSIENT_METADATA_KEYS).to be_empty
    end

    it 'rejects automation provenance from another account' do
      reminder = create(:reminder)
      foreign_rule = create(:automation_rule)

      expect { reminder.mark_automation_provenance!(foreign_rule) }
        .to raise_error(ArgumentError, 'Automation rule must belong to the reminder account')
      expect(reminder.reload.metadata).not_to include(
        Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY,
        Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY
      )
    end
  end

  describe '#cancel!' do
    it 'does not overwrite a completed touch' do
      reminder = create(:reminder, status: :completed, completed_at: Time.current, last_error: nil)

      reminder.cancel!('too late')

      expect(reminder.reload).to be_completed
      expect(reminder.last_error).to be_nil
    end

    it 'does not cancel a processing touch after its message was materialized' do
      reminder = create(:reminder, status: :pending)
      reminder.mark_processing!
      reminder.mark_delivery_materialized!(123)

      reminder.cancel!('too late')

      expect(reminder.reload).to be_processing
      expect(reminder.last_error).to be_nil
    end
  end

  describe 'post-delivery action validation' do
    it 'allows conversation resolution only for one-time message touches' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        post_delivery_action: Reminder::POST_DELIVERY_ACTION_RESOLVE_CONVERSATION
      )

      expect(reminder).to be_valid

      reminder.repeat_mode = :daily
      expect(reminder).not_to be_valid
      expect(reminder.errors[:post_delivery_action]).to include('is only supported for one-time touches')

      reminder.repeat_mode = :once
      reminder.action_type = :ai_agent_wakeup
      expect(reminder).not_to be_valid
      expect(reminder.errors[:post_delivery_action]).to include('is only supported for message touches')
    end

    it 'requires a canonical conversation remindable and matching conversation references' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        post_delivery_action: Reminder::POST_DELIVERY_ACTION_RESOLVE_CONVERSATION
      )

      reminder.target_conversation = create(:conversation, account: conversation.account)
      expect(reminder).not_to be_valid
      expect(reminder.errors[:post_delivery_action]).to include('requires matching conversation references')

      reminder.target_conversation = conversation
      reminder.remindable = create(:scheduling_appointment, account: conversation.account, conversation: conversation)
      expect(reminder).not_to be_valid
      expect(reminder.errors[:post_delivery_action]).to include('is only supported for conversation touches')
    end

    it 'rejects unsupported actions and normalizes blank actions to nil' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        post_delivery_action: 'send_webhook'
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:post_delivery_action]).to be_present

      reminder.post_delivery_action = ''
      expect(reminder).to be_valid
      reminder.save!
      expect(reminder.reload.post_delivery_action).to be_nil
    end
  end

  describe 'repeat validation' do
    it 'rejects recurring relative touches' do
      conversation = create(:conversation)
      reminder = build(
        :reminder,
        account: conversation.account,
        touch_conversation: conversation,
        conversation: conversation,
        remindable: conversation,
        timing_mode: :relative,
        relative_anchor: 'conversation.created_at',
        relative_offset_seconds: 3600,
        scheduled_at: nil,
        repeat_mode: :weekly
      )

      expect(reminder).not_to be_valid
      expect(reminder.errors[:repeat_mode]).to include('is only supported for absolute touches')
    end
  end
end
