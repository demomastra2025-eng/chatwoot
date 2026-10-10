# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ContextFields do
  let(:account) { create(:account) }
  let!(:contact_attribute_definition) do
    create(
      :custom_attribute_definition,
      account: account,
      attribute_model: :contact_attribute,
      attribute_key: 'vip_level',
      attribute_display_name: 'VIP Level'
    )
  end
  let!(:conversation_attribute_definition) do
    create(
      :custom_attribute_definition,
      account: account,
      attribute_model: :conversation_attribute,
      attribute_key: 'order_id',
      attribute_display_name: 'Order ID'
    )
  end
  let!(:appointment_field_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_room',
      label: 'Visit Room'
    )
  end
  let!(:deal_field_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'sales_region',
      label: 'Sales Region',
      field_type: 'select',
      required: true,
      default_value: 'EMEA',
      options: [
        { label: 'EMEA', value: 'EMEA' },
        { label: 'APAC', value: 'APAC' }
      ]
    )
  end
  let!(:task_field_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'follow_up_channel',
      label: 'Follow Up Channel'
    )
  end
  let(:assistant) { create(:captain_assistant, account: account, config: assistant_config) }
  let(:assistant_config) { {} }
  let(:runtime_state) do
    {
      contact: {
        id: 10,
        name: 'John Doe',
        email: 'john@example.com',
        phone_number: '+123456789',
        identifier: 'crm_42',
        contact_type: 'lead',
        custom_attributes: { vip_level: 'gold' },
        additional_attributes: { locale: 'en' }
      },
      conversation: {
        id: 20,
        display_id: 333,
        inbox_id: 4,
        contact_id: 10,
        status: 'pending',
        priority: 'high',
        label_list: ['sales'],
        custom_attributes: { order_id: 'ORD-1' },
        additional_attributes: { source: 'whatsapp' }
      },
      deal: {
        id: 25,
        title: 'Enterprise renewal',
        stage_name: 'Negotiation',
        custom_attributes: { sales_region: 'EMEA' }
      },
      task: {
        id: 26,
        title: 'Follow up call',
        status_name: 'In progress',
        custom_attributes: { follow_up_channel: 'phone' }
      },
      appointment: {
        id: 30,
        resource_id: 4,
        contact_id: 10,
        service_id: 8,
        company_id: 12,
        conversation_id: 20,
        starts_at: '2026-03-29T10:00:00Z',
        ends_at: '2026-03-29T10:30:00Z',
        status: 'scheduled',
        payment_status: 'awaiting_payment',
        service_name_snapshot: 'Consultation',
        custom_attributes: { visit_room: 'B12' }
      }
    }
  end

  before do
    account.enable_features!('crm_deals', 'crm_tasks', 'scheduling')
  end

  describe '.prompt_state_for' do
    context 'when the assistant has an explicit access configuration' do
      let(:assistant_config) do
        {
          'context_access' => {
            'contact' => {
              'enabled' => true,
              'field_ids' => [
                'contact.phone_number',
                'contact.custom_attributes.vip_level'
              ]
            },
            'conversation' => {
              'enabled' => false,
              'field_ids' => ['conversation.display_id']
            },
            'deal' => {
              'enabled' => true,
              'field_ids' => [
                'deal.stage_name',
                'deal.custom_attributes.sales_region'
              ]
            },
            'task' => {
              'enabled' => true,
              'field_ids' => [
                'task.status_name',
                'task.custom_attributes.follow_up_channel'
              ]
            },
            'appointment' => {
              'enabled' => true,
              'field_ids' => [
                'appointment.status',
                'appointment.custom_attributes.visit_room'
              ]
            }
          }
        }
      end

      it 'keeps only the selected prompt-facing fields' do
        prompt_state = described_class.prompt_state_for(
          assistant: assistant,
          runtime_state: runtime_state,
          field_ids: [
            'contact.phone_number',
            'contact.custom_attributes.vip_level',
            'deal.stage_name',
            'deal.custom_attributes.sales_region',
            'task.status_name',
            'task.custom_attributes.follow_up_channel',
            'appointment.status',
            'appointment.custom_attributes.visit_room'
          ]
        )

        expect(prompt_state[:contact]['id']).to eq(10)
        expect(prompt_state[:contact]['name']).to eq('John Doe')
        expect(prompt_state[:contact]['email']).to eq('john@example.com')
        expect(prompt_state[:contact]['phone_number'].to_s).to include('+123')
        expect(prompt_state[:contact]['identifier']).to eq('crm_42')
        expect(prompt_state[:contact]['contact_type']).to eq('lead')
        expect(prompt_state[:contact][:custom_attributes]).to eq('vip_level' => 'gold')
        expect(prompt_state.dig(:visible_fields, :contact)).to include('phone_number')
        expect(prompt_state[:conversation]).to include(
          'id' => 20,
          'display_id' => 333,
          'inbox_id' => 4,
          'contact_id' => 10,
          'status' => 'pending',
          'priority' => 'high',
          'label_list' => ['sales'],
          :custom_attributes => { 'order_id' => 'ORD-1' }
        )
        expect(prompt_state[:deal]).to eq(
          'stage_name' => 'Negotiation',
          :custom_attributes => { 'sales_region' => 'EMEA' }
        )
        expect(prompt_state.dig(:visible_fields, :deal)).to eq(['stage_name'])
        expect(prompt_state[:task]).to eq(
          'status_name' => 'In progress',
          :custom_attributes => { 'follow_up_channel' => 'phone' }
        )
        expect(prompt_state.dig(:visible_fields, :task)).to eq(['status_name'])
        expect(prompt_state[:appointment]).to eq(
          'status' => 'scheduled',
          :custom_attributes => { 'visit_room' => 'B12' }
        )
        expect(prompt_state.dig(:visible_fields, :appointment)).to eq(['status'])
        expect(prompt_state[:contact_custom_attribute_labels]).to eq('vip_level' => 'VIP Level')
        expect(prompt_state[:deal_custom_attribute_labels]).to eq('sales_region' => 'Sales Region')
        expect(prompt_state[:task_custom_attribute_labels]).to eq('follow_up_channel' => 'Follow Up Channel')
        expect(prompt_state[:appointment_custom_attribute_labels]).to eq('visit_room' => 'Visit Room')
        expect(prompt_state.dig(:contact, :additional_attributes)).to be_nil
      end
    end

    context 'when the assistant has not configured context access yet' do
      it 'still excludes additional attributes from the prompt state' do
        assistant.update_column(:config, {})

        prompt_state = described_class.prompt_state_for(
          assistant: assistant,
          runtime_state: runtime_state
        )

        expect(prompt_state.dig(:contact, :additional_attributes)).to be_nil
        expect(prompt_state.dig(:conversation, :additional_attributes)).to be_nil
        expect(prompt_state[:appointment]).to be_nil
      end
    end

    context 'when the assistant has an explicit empty access configuration' do
      let(:assistant_config) do
        {
          'context_access' => {}
        }
      end

      it 'treats the access configuration as explicit and excludes additional attributes' do
        prompt_state = described_class.prompt_state_for(
          assistant: assistant,
          runtime_state: runtime_state,
          field_ids: ['contact.phone_number', 'conversation.display_id']
        )

        expect(prompt_state.dig(:contact, :additional_attributes)).to be_nil
        expect(prompt_state.dig(:conversation, :additional_attributes)).to be_nil
        expect(prompt_state.dig(:contact, 'phone_number').to_s).to include('+123')
        expect(prompt_state.dig(:conversation, 'display_id')).to eq(333)
        expect(prompt_state[:appointment]).to be_nil
      end
    end
  end

  describe '.custom_attribute_label_maps_for_definitions' do
    it 'builds per-scope label maps for custom attributes' do
      definitions = described_class.definitions_for(account)

      expect(described_class.custom_attribute_label_maps_for_definitions(definitions)).to eq(
        contact: { 'vip_level' => 'VIP Level' },
        conversation: { 'order_id' => 'Order ID' },
        deal: { 'sales_region' => 'Sales Region' },
        task: { 'follow_up_channel' => 'Follow Up Channel' },
        appointment: { 'visit_room' => 'Visit Room' }
      )
    end
  end

  describe '.definitions_for' do
    it 'enriches managed CRM custom fields with type, required flag, options, and defaults' do
      field = described_class.definitions_for(account).find do |definition|
        definition[:id] == 'deal.custom_attributes.sales_region'
      end

      expect(field).to include(
        field_key: 'sales_region',
        field_type: 'custom_attribute',
        value_type: 'select',
        required: true,
        default_value: 'EMEA',
        crm_managed: true,
        options: [
          { label: 'EMEA', value: 'EMEA' },
          { label: 'APAC', value: 'APAC' }
        ]
      )
    end
  end

  describe '.deal_state_for' do
    let(:conversation_record) { create(:conversation, account: account) }
    let!(:older_open_deal) do
      create(
        :crm_deal,
        account: account,
        originating_conversation: conversation_record,
        updated_at: 2.days.ago
      )
    end
    let!(:latest_open_deal) do
      create(
        :crm_deal,
        account: account,
        originating_conversation: conversation_record,
        amount_minor: 20_000,
        currency: 'USD',
        updated_at: 1.day.ago
      )
    end
    let!(:closed_deal) do
      create(
        :crm_deal,
        account: account,
        originating_conversation: conversation_record,
        closed_at: Time.current,
        updated_at: Time.current
      )
    end

    it 'does not select a current deal from the conversation' do
      state = described_class.deal_state_for(account: account, conversation: conversation_record)

      expect(state).not_to include(:id, :title, :amount)
      expect(state[:summary][:selection][:current_record]).to be_nil
      expect(described_class.deal_for(account: account, conversation: conversation_record)).to be_nil
    end

    it 'preserves scalar types for an explicitly supplied deal and reports legacy references' do
      state = described_class.deal_state_for(account: account, conversation: conversation_record, deal: latest_open_deal)

      expect(state[:id]).to eq(latest_open_deal.id)
      expect(state[:stage_name]).to eq(latest_open_deal.stage.name)
      expect(state[:amount]).to eq('200')
      expect(state).not_to have_key(:amount_minor)
    end

    it 'keeps a thread deal scalar only when explicitly supplied' do
      communication_thread = create(:communication_thread, account: account, contact: conversation_record.contact)
      create(
        :communication_thread_conversation,
        account: account,
        communication_thread: communication_thread,
        conversation: conversation_record,
        inbox: conversation_record.inbox,
        contact_inbox: conversation_record.contact_inbox
      )
      thread_deal = create(
        :crm_deal,
        account: account,
        originating_communication_thread: communication_thread,
        originating_conversation: nil,
        amount_minor: 150_000,
        currency: 'KZT',
        updated_at: Time.current
      )

      state = described_class.deal_state_for(account: account, conversation: conversation_record, deal: thread_deal)

      expect(state[:id]).to eq(thread_deal.id)
      expect(state[:amount]).to eq('1500')
      expect(state[:currency]).to eq('KZT')
    end

    it 'marks old catalog entries without substituting JSON into a saved scalar reference' do
      definition = described_class.definitions_for(account).find { |field| field[:id] == 'deal.title' }
      expect(definition).to include(deprecated: true, selectable: false, replacement_field_id: 'deal.summary')
      state = { deal: { title: 'Exact event title' } }
      prompt = described_class.prompt_state_for(assistant: assistant, runtime_state: state, field_ids: ['deal.title'])
      rendered = described_class.render_references('[Title](field://deal.title)', prompt_state: prompt, allowed_fields: [definition])

      expect(rendered).to eq('Title (deal.title: Exact event title)')
      expect(prompt[:context_warnings]).to include(include(field_id: 'deal.title', replacement_field_id: 'deal.summary'))
      expect(prompt.dig(:deal, 'summary')).to be_nil
    end

    it 'keeps a saved enabled scope without field IDs on its old scalar whitelist' do
      assistant.update!(config: { context_access: { deal: { enabled: true } } })
      access = described_class.normalized_access_for(assistant)[:deal]
      expect(access[:field_ids]).to include('deal.id', 'deal.title')
      expect(access[:field_ids]).not_to include('deal.summary')
    end
  end

  describe '.appointment_state_for' do
    let(:conversation_record) { create(:conversation, account: account) }
    let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }

    around do |example|
      travel_to(Time.zone.parse('2026-03-28 12:00:00')) { example.run }
    end

    let!(:appointment_record) do
      create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        contact: conversation_record.contact,
        conversation: conversation_record,
        starts_at: '2026-03-29T10:00:00Z',
        ends_at: '2026-03-29T10:30:00Z'
      )
    end

    it 'formats start/end date and time in the appointment timezone' do
      Time.use_zone('UTC') do
        state = described_class.appointment_state_for(account: account, conversation: conversation_record)

        expect(state[:starts_at]).to be_present
        expect(state[:resource_name]).to eq(resource.name)
        expect(state[:start_time]).to eq('15:00')
        expect(state[:start_date]).to eq('29.03.2026')
        expect(state[:end_time]).to eq('15:30')
        expect(state[:end_date]).to eq('29.03.2026')
      end
    end

    it 'keeps the dialog appointment for shared fields and selects the contact future appointment for the agent' do
      appointment_record.update!(starts_at: 2.days.ago, ends_at: 2.days.ago + 30.minutes, status: 'completed')
      other_conversation = create(:conversation, account: account, contact: conversation_record.contact)
      upcoming = create(:scheduling_appointment, account: account, contact: conversation_record.contact,
                                                 conversation: other_conversation,
                                                 starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)

      shared_state = described_class.appointment_state_for(account: account, conversation: conversation_record)
      agent_state = described_class.appointment_state_for(account: account, conversation: conversation_record, patient_scope: true)

      expect(shared_state).to include(id: appointment_record.id, status: 'completed')
      expect(agent_state[:id]).to eq(upcoming.id)
    end

    it 'uses an explicit appointment without a conversation context' do
      appointment_record.update!(conversation: nil)

      state = described_class.appointment_state_for(account: account, conversation: nil, appointment: appointment_record)

      expect(state[:start_date]).to eq('29.03.2026')
      expect(state[:start_time]).to eq('15:00')
    end

    it 'keeps selected clinic fields but omits provider and payment data from patient context' do
      account.enable_features!('scheduling')
      create(:crm_field_definition, account: account, entity_kind: 'appointment',
                                    key: 'provider_receipt', label: 'Provider Receipt')
      create(:crm_field_definition, account: account, entity_kind: 'appointment',
                                    key: 'payment_reference', label: 'Payment Reference')
      appointment_record.update!(external_ref: 'medelement:reception:example',
                                 custom_attributes: {
                                   'visit_room' => 'B12', 'medelement_reception_code' => 'example',
                                   'provider_receipt' => 'private-receipt', 'payment_reference' => 'private-payment'
                                 })
      assistant = create(:captain_assistant, account: account)

      state = described_class.runtime_state_for(account: account, conversation: conversation_record, assistant: assistant)
      expect(state.fetch(:appointment)).to include(custom_attributes: { 'visit_room' => 'B12' })
      expect(state.to_json).not_to include(
        'medelement_reception_code', 'medelement:reception:example', 'private-receipt', 'private-payment'
      )

      prompt = described_class.prompt_state_for(
        assistant: assistant, runtime_state: state,
        field_ids: %w[
          appointment.id appointment.external_ref appointment.payment_status appointment.custom_attributes.visit_room
          appointment.custom_attributes.provider_receipt appointment.custom_attributes.payment_reference
        ]
      )
      expect(prompt.dig(:visible_fields, :appointment)).to include('id')
      expect(prompt.dig(:visible_fields, :appointment)).not_to include('external_ref', 'payment_status')
      expect(prompt.dig(:appointment, :custom_attributes)).to eq('visit_room' => 'B12')
      expect(prompt.to_json).not_to include('medelement', 'payment_status', 'provider_receipt', 'payment_reference')

      assistant.update!(config: {
        'context_access' => { 'appointment' => { 'enabled' => true, 'field_ids' => %w[
          appointment.custom_attributes.visit_room appointment.custom_attributes.provider_receipt
          appointment.custom_attributes.payment_reference
        ] } }
      })
      configured_prompt = described_class.prompt_state_for(assistant: assistant, runtime_state: state)
      expect(configured_prompt.dig(:appointment, :custom_attributes)).to eq('visit_room' => 'B12')
    end

    it 'exposes the formatted fields in the field definitions picker' do
      definitions = described_class.definitions_for(account)
      ids = definitions.pluck(:id)

      expect(ids).to include(
        'appointment.start_date', 'appointment.start_time',
        'appointment.end_date', 'appointment.end_time',
        'appointment.nearest', 'appointment.last_past', 'appointment.last_cancelled', 'appointment.all'
      )
      expect(definitions.find { |field| field[:id] == 'appointment.nearest' })
        .to include(group_name: 'Записи пациента', title: 'Ближайшая запись')
    end
  end

  describe '.task_state_for' do
    let(:conversation_record) { create(:conversation, account: account) }
    let!(:older_open_task) do
      create(
        :crm_task,
        account: account,
        originating_conversation: conversation_record,
        updated_at: 2.days.ago
      )
    end
    let!(:latest_open_task) do
      create(
        :crm_task,
        account: account,
        originating_conversation: conversation_record,
        updated_at: 1.day.ago
      )
    end
    let!(:completed_task) do
      create(
        :crm_task,
        account: account,
        originating_conversation: conversation_record,
        completed_at: Time.current,
        updated_at: Time.current
      )
    end

    it 'prefers the most recently updated incomplete kept task' do
      state = described_class.task_state_for(account: account, conversation: conversation_record)

      expect(state[:id]).to eq(latest_open_task.id)
      expect(state[:status_name]).to eq(latest_open_task.status.name)
    end
  end

  describe '.runtime_state_for' do
    let(:conversation_record) { create(:conversation, account: account) }

    before do
      account.enable_features!('communication_threads')
    end

    it 'renders the two summaries with identical envelopes and no global current deal ID' do
      deal = create(:crm_deal, account: account, title: 'Own deal')
      create(:crm_deal_contact, account: account, deal: deal, contact: conversation_record.contact)
      own = create(:scheduling_appointment, account: account, contact: conversation_record.contact, starts_at: 1.hour.from_now)
      child = create(:contact, account: account)
      create(:scheduling_appointment, account: account, contact: conversation_record.contact, patient_contact: child, starts_at: 2.hours.from_now)
      state = described_class.runtime_state_for(account: account, conversation: conversation_record, assistant: assistant)
      prompt = described_class.prompt_state_for(assistant: assistant, runtime_state: state, field_ids: %w[deal.summary appointment.summary])

      expect(state[:deal]).not_to include(:id, :title)
      expect(prompt[:deal].keys).to eq(['summary'])
      expect(prompt[:appointment].keys).to eq(['summary'])
      expect(prompt[:context_summaries].keys).to contain_exactly(:deal, :appointment)
      expect(prompt[:context_summaries][:deal][:groups].first[:items].pluck(:id)).to eq([deal.id])
      expect(prompt[:context_summaries][:appointment][:groups].first[:items].pluck(:id)).to eq([own.id])
    end

    it 'uses precomputed trial envelopes without fetching a conversation or patient records' do
      summary = Captain::ContextSummary.from_snapshots(kind: 'deals', records: [{ id: 501, contact_id: 101, title: 'Synthetic deal' }],
                                                     contact_id: 101) { |record| Captain::ContextSummary.deal_card(record) }
      state = { deal: { summary: summary }, conversation: { id: -201 }, playground: { mode: 'trial' } }
      expect(account).not_to receive(:conversations)
      prompt = described_class.prompt_state_for(assistant: assistant, runtime_state: state, field_ids: ['deal.summary'])

      expect(prompt[:context_summaries][:deal]).to eq(summary)
    end

    it 'uses synthetic workspace blocks and summaries with negative session IDs without fetching a real conversation' do
      summary = Captain::ContextSummary.from_snapshots(
        kind: 'appointments', records: [{ id: -601, contact_id: -101, starts_at: 1.hour.from_now.iso8601, ends_at: 2.hours.from_now.iso8601 }],
        contact_id: -101
      ) { |record| record.slice(:id, :starts_at, :ends_at) }
      nearest = JSON.generate(id: -601, doctor: 'Synthetic doctor')
      state = { appointment: { summary: summary }, appointment_context_blocks: { nearest: nearest },
                conversation: { id: -201 }, playground: { mode: 'workspace' } }
      expect(account).not_to receive(:conversations)
      expect(account).not_to receive(:scheduling_appointments)

      prompt = described_class.prompt_state_for(assistant: assistant, runtime_state: state, field_ids: %w[appointment.summary appointment.nearest])

      expect(prompt[:context_summaries][:appointment]).to eq(summary)
      expect(prompt[:appointment_context_blocks]['nearest']).to eq(nearest)
    end

    it 'builds reusable Captain runtime state from a conversation' do
      thread = conversation_record.reload.communication_thread
      state = described_class.runtime_state_for(
        account: account,
        conversation: conversation_record,
        channel_type: conversation_record.inbox.channel_type
      )

      expect(state[:conversation]).to include(
        id: conversation_record.id,
        display_id: conversation_record.display_id,
        inbox_id: conversation_record.inbox_id,
        contact_id: conversation_record.contact_id,
        status: conversation_record.status
      )
      expect(state[:contact]).to include(
        id: conversation_record.contact.id,
        name: conversation_record.contact.name,
        email: conversation_record.contact.email
      )
      expect(state[:communication_thread]).to include(
        id: thread.id,
        display_id: thread.display_id,
        current_conversation_id: conversation_record.display_id,
        current_channel_key: "conversation:#{conversation_record.display_id}"
      )
      expect(state[:communication_thread][:conversation_ids]).to include(conversation_record.display_id)
      expect(state[:communication_thread][:current_channel]).to include(
        conversation_id: conversation_record.display_id,
        inbox_id: conversation_record.inbox_id,
        channel_key: "conversation:#{conversation_record.display_id}"
      )
      expect(state[:communication_thread][:channels].first).to include(:can_send_text, :requires_template, :disabled_reason)
      expect(state[:channel_type]).to eq(conversation_record.inbox.channel_type)
    end

    it 'filters communication-thread channels to the assistant connected inboxes' do
      second_inbox = create(:inbox, account: account)
      second_contact_inbox = create(:contact_inbox, contact: conversation_record.contact, inbox: second_inbox)
      second_conversation = create(
        :conversation,
        account: account,
        contact: conversation_record.contact,
        inbox: second_inbox,
        contact_inbox: second_contact_inbox
      )
      captain_assistant = create(:captain_assistant, account: account)
      create(:captain_inbox, captain_assistant: captain_assistant, inbox: conversation_record.inbox)

      state = described_class.runtime_state_for(
        account: account,
        conversation: conversation_record,
        assistant: captain_assistant
      )

      expect(state[:communication_thread][:conversation_ids]).to contain_exactly(conversation_record.display_id)
      expect(state[:communication_thread][:conversation_ids]).not_to include(second_conversation.display_id)
      expect(state[:communication_thread][:channels].pluck(:inbox_id)).to contain_exactly(conversation_record.inbox_id)
    end

    it 'filters communication-thread channels to the actor accessible inboxes' do
      second_inbox = create(:inbox, account: account)
      second_contact_inbox = create(:contact_inbox, contact: conversation_record.contact, inbox: second_inbox)
      second_conversation = create(
        :conversation,
        account: account,
        contact: conversation_record.contact,
        inbox: second_inbox,
        contact_inbox: second_contact_inbox
      )
      actor = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: conversation_record.inbox, user: actor)
      InboxMember.where(inbox: second_inbox, user: actor).delete_all

      state = described_class.communication_thread_state_for(
        account: account,
        conversation: conversation_record,
        actor: actor
      )

      expect(state[:conversation_ids]).to contain_exactly(conversation_record.display_id)
      expect(state[:conversation_ids]).not_to include(second_conversation.display_id)
      expect(state[:channels].pluck(:inbox_id)).to contain_exactly(conversation_record.inbox_id)
    end

    it 'returns an empty state without a conversation' do
      expect(described_class.runtime_state_for(account: account, conversation: nil)).to eq({})
    end

    it 'does not expose communication-thread state when the feature is disabled' do
      disabled_account = create(:account)
      disabled_conversation = create(:conversation, account: disabled_account)

      state = described_class.runtime_state_for(
        account: disabled_account,
        conversation: disabled_conversation,
        channel_type: disabled_conversation.inbox.channel_type
      )

      expect(state).not_to include(:communication_thread)
      expect(
        described_class.communication_thread_state_for(account: disabled_account, conversation: disabled_conversation)
      ).to be_nil
    end

    it 'preserves related state only when related records are present' do
      allow(described_class).to receive(:deal_state_for).and_return({ id: 10 })
      allow(described_class).to receive(:task_state_for).and_return({})
      allow(described_class).to receive(:appointment_state_for).and_return(nil)

      state = described_class.runtime_state_for(account: account, conversation: conversation_record)

      expect(state[:deal]).to eq({ id: 10 })
      expect(state).not_to have_key(:task)
      expect(state).not_to have_key(:appointment)
    end
  end

  describe '.effective_definitions_for' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }

    it 'returns only explicitly referenced fields for runtime access' do
      assistant.update!(
        config: {
          'context_access' => {
            'contact' => {
              'enabled' => true,
              'field_ids' => %w[contact.name contact.email]
            }
          }
        }
      )

      expect(described_class.effective_definitions_for(assistant).pluck(:id)).to eq([])
      expect(described_class.effective_definitions_for(assistant, field_ids: ['contact.email']).pluck(:id)).to eq(['contact.email'])
    end
  end

  describe '.render_references' do
    let(:assistant_config) do
      {
        'context_access' => {
          'contact' => {
            'enabled' => true,
            'field_ids' => [
              'contact.phone_number',
              'contact.custom_attributes.vip_level'
            ]
          },
          'conversation' => {
            'enabled' => true,
            'field_ids' => ['conversation.custom_attributes.order_id']
          },
          'deal' => {
            'enabled' => true,
            'field_ids' => ['deal.custom_attributes.sales_region']
          },
          'task' => {
            'enabled' => true,
            'field_ids' => ['task.custom_attributes.follow_up_channel']
          },
          'appointment' => {
            'enabled' => true,
            'field_ids' => ['appointment.custom_attributes.visit_room']
          }
        }
      }
    end

    it 'replaces field links with readable values from the prompt state' do
      field_ids = [
        'contact.phone_number',
        'contact.custom_attributes.vip_level',
        'conversation.custom_attributes.order_id',
        'deal.custom_attributes.sales_region',
        'task.custom_attributes.follow_up_channel',
        'appointment.custom_attributes.visit_room'
      ]

      prompt_state = described_class.prompt_state_for(
        assistant: assistant,
        runtime_state: runtime_state,
        field_ids: field_ids
      )
      text = <<~TEXT.squish
        Use [$Phone Number](field://contact.phone_number),
        [$VIP Level](field://contact.custom_attributes.vip_level),
        [$Order ID](field://conversation.custom_attributes.order_id),
        [$Sales Region](field://deal.custom_attributes.sales_region),
        [$Follow Up Channel](field://task.custom_attributes.follow_up_channel),
        and [$Visit Room](field://appointment.custom_attributes.visit_room).
      TEXT

      rendered_text = described_class.render_references(
        text,
        prompt_state: prompt_state,
        allowed_fields: described_class.effective_definitions_for(assistant, field_ids: field_ids)
      )

      expect(rendered_text).to include('Phone Number (contact.phone_number: +123456789)')
      expect(rendered_text).to include('VIP Level (contact.custom_attributes.vip_level: gold)')
      expect(rendered_text).to include('Order ID (conversation.custom_attributes.order_id: ORD-1)')
      expect(rendered_text).to include('Sales Region (deal.custom_attributes.sales_region: EMEA)')
      expect(rendered_text).to include('Follow Up Channel (task.custom_attributes.follow_up_channel: phone)')
      expect(rendered_text).to include('Visit Room (appointment.custom_attributes.visit_room: B12)')
    end
  end
end
