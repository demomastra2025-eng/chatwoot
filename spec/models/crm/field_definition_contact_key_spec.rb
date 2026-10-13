require 'rails_helper'

# The "Contact" automation condition of deals and tasks is called contact_id, so no custom field may take that key.
RSpec.describe Crm::FieldDefinition do
  %w[deal task].each do |entity_kind|
    it "reserves contact_id for the #{entity_kind} contact condition" do
      definition = build(:crm_field_definition, entity_kind: entity_kind, key: 'contact_id', label: 'Contact')

      expect(definition).not_to be_valid
      expect(definition.errors[:key]).to include('conflicts with a built-in field')
    end
  end

  it 'still allows other keys' do
    expect(build(:crm_field_definition, entity_kind: 'deal', key: 'contact_note', label: 'Contact note')).to be_valid
  end
end
