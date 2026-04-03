require 'rails_helper'

RSpec.describe CustomAttributes::MutationService do
  describe '.merge' do
    it 'normalizes nil current attributes and stringifies incoming keys' do
      merged_attributes = described_class.merge(nil, { customer_id: 42, order_state: 'paid' })

      expect(merged_attributes).to eq(
        {
          'customer_id' => 42,
          'order_state' => 'paid'
        }
      )
    end

    it 'returns current attributes unchanged when incoming payload is blank' do
      current_attributes = { 'existing_key' => 'existing value' }

      expect(described_class.merge(current_attributes, nil)).to eq(current_attributes)
    end
  end

  describe '.destroy' do
    it 'removes the requested keys and keeps the rest' do
      current_attributes = {
        'removable_key' => 'remove me',
        'second_removable_key' => 'remove me too',
        'retained_key' => 'keep me'
      }

      expect(described_class.destroy(current_attributes, [:removable_key, 'second_removable_key'])).to eq(
        { 'retained_key' => 'keep me' }
      )
    end
  end
end
