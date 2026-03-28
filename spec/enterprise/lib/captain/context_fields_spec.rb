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
      }
    }
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
        expect(prompt_state.dig(:contact, :additional_attributes)).to be_nil
      end
    end

    context 'when the assistant has not configured context access yet' do
      it 'preserves legacy additional attributes in the prompt state' do
        assistant.update_column(:config, {})

        prompt_state = described_class.prompt_state_for(
          assistant: assistant,
          runtime_state: runtime_state
        )

        expect(prompt_state.dig(:contact, :additional_attributes)).to eq('locale' => 'en')
        expect(prompt_state.dig(:conversation, :additional_attributes)).to eq('source' => 'whatsapp')
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
      end
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
        and [$Order ID](field://conversation.custom_attributes.order_id).
      TEXT

      rendered_text = described_class.render_references(
        text,
        prompt_state: prompt_state,
        allowed_fields: described_class.allowed_definitions_for(assistant)
      )

      expect(rendered_text).to include('Phone Number (contact.phone_number: +123456789)')
      expect(rendered_text).to include('VIP Level (contact.custom_attributes.vip_level: gold)')
      expect(rendered_text).to include('Order ID (conversation.custom_attributes.order_id: ORD-1)')
    end
  end
end
