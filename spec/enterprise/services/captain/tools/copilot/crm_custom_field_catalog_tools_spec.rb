require 'rails_helper'

RSpec.describe 'Captain CRM custom field catalog tools' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  before do
    account.enable_features!('crm_deals', 'crm_tasks', 'scheduling')
  end

  shared_examples 'a CRM custom field catalog tool' do |entity_kind, copilot_class, public_class, action|
    before do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: entity_kind,
        key: 'acquisition_channel',
        label: 'Acquisition channel',
        field_type: 'select',
        options: [{ 'label' => 'Instagram', 'value' => 'instagram' }]
      )
      create(:crm_field_definition, account: account, entity_kind: entity_kind, key: 'internal_note', active: false)
    end

    it "returns #{entity_kind} field metadata from the copilot service" do
      result = JSON.parse(copilot_class.new(assistant, user: user).execute)

      expect(result).to include(
        'action' => action,
        'entity_kind' => entity_kind,
        'returned_count' => 1
      )
      expect(result.fetch('fields')).to contain_exactly(
        include(
          'key' => 'acquisition_channel',
          'label' => 'Acquisition channel',
          'type' => 'select',
          'required' => false,
          'options' => [{ 'label' => 'Instagram', 'value' => 'instagram' }]
        )
      )
    end

    it "returns #{entity_kind} field metadata from the public agent tool" do
      result = JSON.parse(public_class.new(assistant).perform(nil))

      expect(result).to include(
        'action' => action,
        'entity_kind' => entity_kind,
        'returned_count' => 1
      )
      expect(result.fetch('fields').first).to include(
        'key' => 'acquisition_channel',
        'type' => 'select'
      )
    end
  end

  it_behaves_like(
    'a CRM custom field catalog tool',
    'deal',
    Captain::Tools::Copilot::ListDealCustomFieldsService,
    Captain::Tools::ListDealCustomFieldsTool,
    'list_deal_custom_fields'
  )

  it_behaves_like(
    'a CRM custom field catalog tool',
    'task',
    Captain::Tools::Copilot::ListTaskCustomFieldsService,
    Captain::Tools::ListTaskCustomFieldsTool,
    'list_task_custom_fields'
  )

  it_behaves_like(
    'a CRM custom field catalog tool',
    'appointment',
    Captain::Tools::Copilot::ListAppointmentCustomFieldsService,
    Captain::Tools::ListAppointmentCustomFieldsTool,
    'list_appointment_custom_fields'
  )

  it 'lists task custom fields for the deal_task context when a current deal exists' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    deal = create(:crm_deal, account: account, originating_conversation_id: conversation.id)
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'deal_task_channel',
      label: 'Deal task channel',
      field_type: 'text',
      rules: { 'contexts' => ['deal_task'] }
    )
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'standalone_channel',
      label: 'Standalone channel',
      field_type: 'text',
      rules: { 'contexts' => ['standalone_task'] }
    )

    copilot_result = JSON.parse(
      Captain::Tools::Copilot::ListTaskCustomFieldsService.new(assistant, user: user, conversation: conversation).execute
    )
    public_result = JSON.parse(
      Captain::Tools::ListTaskCustomFieldsTool.new(assistant).perform(Struct.new(:state).new({ deal: { id: deal.id } }))
    )

    expect(copilot_result.fetch('fields')).to include(include('key' => 'deal_task_channel'))
    expect(copilot_result.fetch('fields')).not_to include(include('key' => 'standalone_channel'))
    expect(public_result.fetch('fields')).to include(include('key' => 'deal_task_channel'))
    expect(public_result.fetch('fields')).not_to include(include('key' => 'standalone_channel'))
  end

  it 'uses an explicit personal task context even when a current deal exists' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    deal = create(:crm_deal, account: account, originating_conversation_id: conversation.id)
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'personal_channel',
      rules: { 'contexts' => ['standalone_task'] }
    )
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'sales_channel',
      rules: { 'contexts' => ['deal_task'] }
    )

    copilot_result = JSON.parse(
      Captain::Tools::Copilot::ListTaskCustomFieldsService
        .new(assistant, user: user, conversation: conversation)
        .execute(context_kind: 'personal')
    )
    public_result = JSON.parse(
      Captain::Tools::ListTaskCustomFieldsTool
        .new(assistant)
        .perform(Struct.new(:state).new({ deal: { id: deal.id } }), context_kind: 'personal')
    )

    expect(copilot_result.fetch('fields')).to include(include('key' => 'personal_channel'))
    expect(copilot_result.fetch('fields')).not_to include(include('key' => 'sales_channel'))
    expect(public_result.fetch('fields')).to include(include('key' => 'personal_channel'))
    expect(public_result.fetch('fields')).not_to include(include('key' => 'sales_channel'))
  end

  it 'lists appointment custom fields for the booking_intake write context' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'booking_reason',
      label: 'Booking reason',
      field_type: 'text',
      rules: { 'contexts' => ['booking_intake'] }
    )

    result = JSON.parse(Captain::Tools::Copilot::ListAppointmentCustomFieldsService.new(assistant, user: user).execute)

    expect(result.fetch('fields')).to include(include('key' => 'booking_reason'))
  end
end
