require 'rails_helper'

RSpec.describe Captain::Tools::CrmCustomFieldCatalog do
  let(:account) { create(:account) }

  it 'returns active CRM custom field metadata with normalized select options' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'acquisition_channel',
      label: 'Источник',
      field_type: 'select',
      required: true,
      options: [
        { 'label' => 'Инстаграм', 'value' => 'instagram' },
        { 'label' => 'Сайт', 'value' => 'site' }
      ]
    )
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'inactive_note', active: false)
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'task_source')

    fields = described_class.new(account: account, entity_kind: 'deal').fields

    expect(fields).to contain_exactly(
      include(
        key: 'acquisition_channel',
        label: 'Источник',
        type: 'select',
        required: true,
        options: [
          { label: 'Инстаграм', value: 'instagram' },
          { label: 'Сайт', value: 'site' }
        ]
      )
    )
  end

  it 'returns empty options for non-select fields' do
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'note', label: 'Note', field_type: 'text')

    fields = described_class.new(account: account, entity_kind: 'task').fields

    expect(fields).to contain_exactly(
      include(key: 'note', label: 'Note', type: 'text', options: [])
    )
  end

  it 'returns fields scoped to the same CRM field context as write services' do
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

    fields = described_class.new(account: account, entity_kind: 'task', context: 'deal_task').fields

    expect(fields).to contain_exactly(
      include(key: 'deal_task_channel')
    )
  end
end
