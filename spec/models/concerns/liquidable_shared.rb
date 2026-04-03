require 'rails_helper'

shared_examples_for 'liqudable' do
  context 'when liquid is present in content' do
    let(:contact) { create(:contact, name: 'john', phone_number: '+912883', custom_attributes: { customer_type: 'platinum' }) }
    let(:conversation) { create(:conversation, id: 1, contact: contact, custom_attributes: { priority: 'high' }) }

    context 'when message is incoming' do
      let(:message) { build(:message, conversation: conversation, message_type: 'incoming') }

      it 'will not process liquid in content' do
        message.content = 'hey {{contact.name}} how are you?'
        message.save!
        expect(message.content).to eq 'hey {{contact.name}} how are you?'
      end
    end

    context 'when message is outgoing' do
      let(:message) { build(:message, conversation: conversation, message_type: 'outgoing') }

      it 'set replaces liquid variables in message' do
        message.content = 'hey {{contact.name}} how are you?'
        message.save!
        expect(message.content).to eq 'hey John how are you?'
      end

      it 'set replaces liquid custom attributes in message' do
        message.content = 'Are you a {{contact.custom_attribute.customer_type}} customer,
        If yes then the priority is {{conversation.custom_attribute.priority}}'
        message.save!
        expect(message.content).to eq 'Are you a platinum customer,
        If yes then the priority is high'
      end

      it 'process liquid operators like default value' do
        message.content = 'Can we send you an email at {{ contact.email | default: "default"  }} ?'
        message.save!
        expect(message.content).to eq 'Can we send you an email at default ?'
      end

      it 'return empty string when value is not available' do
        message.content = 'Can we send you an email at {{contact.email}}?'
        message.save!
        expect(message.content).to eq 'Can we send you an email at ?'
      end

      it 'will skip processing broken liquid tags' do
        message.content = 'Can we send you an email at {{contact.email}  {{hi}} ?'
        message.save!
        expect(message.content).to eq 'Can we send you an email at {{contact.email}  {{hi}} ?'
      end

      it 'will not process liquid tags in multiple code blocks' do
        message.content = 'hey {{contact.name}} how are you? ```code: {{contact.name}}``` ``` code: {{contact.name}} ``` test `{{contact.name}}`'
        message.save!
        expect(message.content).to eq 'hey John how are you? ```code: {{contact.name}}``` ``` code: {{contact.name}} ``` test `{{contact.name}}`'
      end

      it 'will not process liquid tags in single ticks' do
        message.content = 'hey {{contact.name}} how are you? ` code: {{contact.name}} ` ` code: {{contact.name}} ` test'
        message.save!
        expect(message.content).to eq 'hey John how are you? ` code: {{contact.name}} ` ` code: {{contact.name}} ` test'
      end

      it 'will not throw error for broken quotes' do
        message.content = 'hey {{contact.name}} how are you? ` code: {{contact.name}} ` ` code: {{contact.name}} test'
        message.save!
        expect(message.content).to eq 'hey John how are you? ` code: {{contact.name}} ` ` code: John test'
      end
    end
  end

  context 'when liquid is present in template_params' do
    let(:contact) do
      create(:contact, name: 'john', email: 'john@example.com', phone_number: '+912883', custom_attributes: { customer_type: 'platinum' })
    end
    let(:conversation) { create(:conversation, id: 1, contact: contact, custom_attributes: { priority: 'high' }) }

    context 'when message is outgoing with template_params' do
      let(:message) { build(:message, conversation: conversation, message_type: 'outgoing') }

      it 'replaces liquid variables in template_params body' do
        message.additional_attributes = {
          'template_params' => {
            'name' => 'greet',
            'category' => 'MARKETING',
            'language' => 'en',
            'processed_params' => {
              'body' => {
                'customer_name' => '{{contact.name}}',
                'customer_email' => '{{contact.email}}'
              }
            }
          }
        }
        message.save!

        body_params = message.additional_attributes['template_params']['processed_params']['body']
        expect(body_params['customer_name']).to eq 'John'
        expect(body_params['customer_email']).to eq 'john@example.com'
      end

      it 'replaces liquid variables in nested template_params' do
        message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'header' => {
                'media_url' => 'https://example.com/{{contact.name}}.jpg'
              },
              'body' => {
                'customer_name' => '{{contact.name}}',
                'priority' => '{{conversation.custom_attribute.priority}}'
              },
              'footer' => {
                'company' => '{{account.name}}'
              }
            }
          }
        }
        message.save!

        processed = message.additional_attributes['template_params']['processed_params']
        expect(processed['header']['media_url']).to eq 'https://example.com/John.jpg'
        expect(processed['body']['customer_name']).to eq 'John'
        expect(processed['body']['priority']).to eq 'high'
        expect(processed['footer']['company']).to eq conversation.account.name
      end

      it 'handles arrays in template_params' do
        message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'buttons' => [
                { 'type' => 'url', 'parameter' => 'https://example.com/{{contact.name}}' },
                { 'type' => 'text', 'parameter' => 'Hello {{contact.name}}' }
              ]
            }
          }
        }
        message.save!

        buttons = message.additional_attributes['template_params']['processed_params']['buttons']
        expect(buttons[0]['parameter']).to eq 'https://example.com/John'
        expect(buttons[1]['parameter']).to eq 'Hello John'
      end

      it 'handles custom attributes in template_params' do
        message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'body' => {
                'customer_type' => '{{contact.custom_attribute.customer_type}}',
                'priority' => '{{conversation.custom_attribute.priority}}'
              }
            }
          }
        }
        message.save!

        body_params = message.additional_attributes['template_params']['processed_params']['body']
        expect(body_params['customer_type']).to eq 'platinum'
        expect(body_params['priority']).to eq 'high'
      end

      it 'resolves field references in content and template params' do
        conversation.update!(custom_attributes: { 'priority.v2' => 'urgent' })
        message.content = 'Hello [Name](field://contact.name)'
        message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'body' => {
                'customer_name' => '[Name](field://contact.name)',
                'priority' => '[Priority](field://conversation.custom_attributes.priority.v2)'
              }
            }
          }
        }

        message.save!

        expect(message.content).to eq 'Hello John'
        body_params = message.additional_attributes['template_params']['processed_params']['body']
        expect(body_params['customer_name']).to eq 'John'
        expect(body_params['priority']).to eq 'urgent'
      end

      it 'does not resolve field references inside code blocks' do
        message.content = 'Hello [Name](field://contact.name) `example [Name](field://contact.name)`'

        message.save!

        expect(message.content).to eq 'Hello John `example [Name](field://contact.name)`'
      end

      it 'resolves enterprise field references in template params' do
        skip 'Captain context fields are not available' unless defined?(Captain::ContextFields)

        account = conversation.account
        account.enable_features!('crm_deals', 'crm_tasks', 'scheduling')
        crm_role = create(
          :custom_role,
          account: account,
          permissions: %w[crm_deal_view crm_task_view]
        )
        message.sender.account_users.find_by(account_id: account.id)&.update!(
          custom_role: crm_role
        )

        deal = create(
          :crm_deal,
          account: account,
          title: 'Expansion',
          originating_conversation_id: conversation.id,
          custom_attributes: { 'deal-stage.v2' => 'proposal' }
        )
        task = create(
          :crm_task,
          account: account,
          title: 'Call back',
          originating_conversation_id: conversation.id,
          custom_attributes: { 'task-kind.v2' => 'callback' }
        )
        appointment = create(
          :scheduling_appointment,
          account: account,
          contact: contact,
          conversation: conversation,
          client_name: 'John Patient',
          custom_attributes: { 'visit-kind.v2' => 'follow_up' }
        )

        message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'body' => {
                'deal_title' => '[Deal Title](field://deal.title)',
                'deal_stage' => '[Deal Stage](field://deal.custom_attributes.deal-stage.v2)',
                'task_title' => '[Task Title](field://task.title)',
                'task_kind' => '[Task Kind](field://task.custom_attributes.task-kind.v2)',
                'appointment_name' => '[Client Name](field://appointment.client_name)',
                'appointment_kind' => '[Visit Kind](field://appointment.custom_attributes.visit-kind.v2)'
              }
            }
          }
        }

        message.save!

        body_params = message.additional_attributes['template_params']['processed_params']['body']
        expect(body_params['deal_title']).to eq deal.title
        expect(body_params['deal_stage']).to eq 'proposal'
        expect(body_params['task_title']).to eq task.title
        expect(body_params['task_kind']).to eq 'callback'
        expect(body_params['appointment_name']).to eq appointment.client_name
        expect(body_params['appointment_kind']).to eq 'follow_up'
      end

      it 'does not resolve unauthorized crm field references' do
        skip 'Captain context fields are not available' unless defined?(Captain::ContextFields)

        account = conversation.account
        account.enable_features!('crm_deals', 'crm_tasks')

        create(
          :crm_deal,
          account: account,
          title: 'Expansion',
          originating_conversation_id: conversation.id
        )
        create(
          :crm_task,
          account: account,
          title: 'Call back',
          originating_conversation_id: conversation.id
        )

        message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'body' => {
                'deal_title' => '[Deal Title](field://deal.title)',
                'task_title' => '[Task Title](field://task.title)'
              }
            }
          }
        }

        message.save!

        body_params = message.additional_attributes['template_params']['processed_params']['body']
        expect(body_params['deal_title']).to eq ''
        expect(body_params['task_title']).to eq ''
      end

      it 'handles missing email with default filter in template_params' do
        contact.update!(email: nil)
        message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'body' => {
                'customer_email' => '{{ contact.email | default: "no-email@example.com" }}'
              }
            }
          }
        }
        message.save!

        body_params = message.additional_attributes['template_params']['processed_params']['body']
        expect(body_params['customer_email']).to eq 'no-email@example.com'
      end

      it 'handles broken liquid syntax in template_params gracefully' do
        message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'body' => {
                'broken_liquid' => '{{contact.name}  {{invalid}}'
              }
            }
          }
        }
        message.save!

        body_params = message.additional_attributes['template_params']['processed_params']['body']
        expect(body_params['broken_liquid']).to eq '{{contact.name}  {{invalid}}'
      end

      it 'does not process template_params when message is incoming' do
        incoming_message = build(:message, conversation: conversation, message_type: 'incoming')
        incoming_message.additional_attributes = {
          'template_params' => {
            'name' => 'test_template',
            'processed_params' => {
              'body' => {
                'customer_name' => '{{contact.name}}'
              }
            }
          }
        }
        incoming_message.save!

        body_params = incoming_message.additional_attributes['template_params']['processed_params']['body']
        expect(body_params['customer_name']).to eq '{{contact.name}}'
      end

      it 'does not process template_params when not present' do
        message.additional_attributes = { 'other_data' => 'test' }
        expect { message.save! }.not_to raise_error
      end
    end
  end
end
