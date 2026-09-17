require 'rails_helper'

RSpec.describe Scheduling::CalendarViewService do
  let(:account) { create(:account) }
  let(:base_options) do
    {
      account: account,
      view: 'day',
      from: Time.zone.parse('2026-09-14 09:00:00'),
      to: Time.zone.parse('2026-09-14 18:00:00')
    }
  end

  it 'rejects malformed resource IDs at the service boundary' do
    ['abc', 42, { id: 42 }, [[42]], true].each do |value|
      expect do
        described_class.new(**base_options, resource_ids: value)
      end.to raise_error(ArgumentError, /resource_ids must contain positive integer IDs/)
    end
  end

  it 'normalizes valid resource IDs before querying the account scope' do
    first_resource = create(:scheduling_resource, account: account)
    second_resource = create(:scheduling_resource, account: account)

    result = described_class.new(**base_options, resource_ids: "#{first_resource.id},#{second_resource.id}").perform

    expect(result.fetch(:resources).map(&:id)).to contain_exactly(first_resource.id, second_resource.id)
  end
end
