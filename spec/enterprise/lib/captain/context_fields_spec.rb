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
      label: 'Sales Region'
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
          runtime_state: runtime_state
        )

        expect(prompt_state[:contact]).to eq(
          'phone_number' => '+123456789',
          custom_attributes: { 'vip_level' => 'gold' }
        )
        expect(prompt_state.dig(:visible_fields, :contact)).to eq(['phone_number'])
        expect(prompt_state[:conversation]).to be_nil
        expect(prompt_state[:deal]).to eq(
          'stage_name' => 'Negotiation',
          custom_attributes: { 'sales_region' => 'EMEA' }
        )
        expect(prompt_state.dig(:visible_fields, :deal)).to eq(['stage_name'])
        expect(prompt_state[:task]).to eq(
          'status_name' => 'In progress',
          custom_attributes: { 'follow_up_channel' => 'phone' }
        )
        expect(prompt_state.dig(:visible_fields, :task)).to eq(['status_name'])
        expect(prompt_state[:appointment]).to eq(
          'status' => 'scheduled',
          custom_attributes: { 'visit_room' => 'B12' }
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
          runtime_state: runtime_state
        )

        expect(prompt_state.dig(:contact, :additional_attributes)).to be_nil
        expect(prompt_state.dig(:conversation, :additional_attributes)).to be_nil
        expect(prompt_state.dig(:contact, 'phone_number')).to eq('+123456789')
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

    it 'prefers the most recently updated open kept deal' do
      state = described_class.deal_state_for(account: account, conversation: conversation_record)

      expect(state[:id]).to eq(latest_open_deal.id)
      expect(state[:stage_name]).to eq(latest_open_deal.stage.name)
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
      prompt_state = described_class.prompt_state_for(
        assistant: assistant,
        runtime_state: runtime_state
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
        allowed_fields: described_class.allowed_definitions_for(assistant)
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
