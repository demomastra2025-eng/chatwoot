require 'rails_helper'

RSpec.describe Integrations::Medelement::CleanupService do
  let(:account) { create(:account) }

  it 'takes the MedElement grid attributes off a specialist that stays because it has local visits' do
    resource = create(:scheduling_resource, account: account, custom_attributes: {
                        'medelement_specialist_code' => 'sp-1', 'medelement_reception_time' => 30, 'slot_grid_min' => 10,
                        'slot_grid_checked_at' => '2026-04-20T00:00:00Z', 'note' => 'keep'
                      })
    create(:scheduling_appointment, account: account, resource: resource, source: 'manual')

    described_class.new(account: account).perform

    attributes = resource.reload.custom_attributes
    expect(attributes).to include('note' => 'keep')
    expect(attributes.keys).not_to include('medelement_specialist_code', 'medelement_reception_time', 'slot_grid_min', 'slot_grid_checked_at')
    expect(Scheduling::SlotGrid.provider?(resource)).to be(false)
  end
end
