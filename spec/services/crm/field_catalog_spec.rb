require 'rails_helper'

RSpec.describe Crm::FieldCatalog do
  let(:account) { create(:account) }

  describe '#definitions' do
    it 'excludes contextual appointment fields when no explicit context is provided' do
      shared_definition = create(
        :crm_field_definition,
        account: account,
        entity_kind: 'appointment',
        key: 'visit_reason',
        label: 'Visit reason'
      )
      intake_definition = create(
        :crm_field_definition,
        account: account,
        entity_kind: 'appointment',
        key: 'triage_note',
        label: 'Triage note',
        rules: { contexts: ['booking_intake'] }
      )

      catalog = described_class.new(account: account, entity_kind: 'appointment')

      expect(catalog.definitions.map(&:id)).to contain_exactly(shared_definition.id)
    end

    it 'filters contextual appointment fields when an explicit context is provided' do
      shared_definition = create(
        :crm_field_definition,
        account: account,
        entity_kind: 'appointment',
        key: 'visit_reason',
        label: 'Visit reason'
      )
      intake_definition = create(
        :crm_field_definition,
        account: account,
        entity_kind: 'appointment',
        key: 'triage_note',
        label: 'Triage note',
        rules: { contexts: ['booking_intake'] }
      )

      catalog = described_class.new(
        account: account,
        entity_kind: 'appointment',
        context: 'booking_intake'
      )

      expect(catalog.definitions.map(&:id)).to contain_exactly(
        shared_definition.id,
        intake_definition.id
      )
    end

    it 'excludes appointment fields scoped to another context' do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'appointment',
        key: 'triage_note',
        label: 'Triage note',
        rules: { contexts: ['booking_intake'] }
      )

      catalog = described_class.new(
        account: account,
        entity_kind: 'appointment',
        context: 'internal_only'
      )

      expect(catalog.definitions).to be_empty
    end
  end
end
