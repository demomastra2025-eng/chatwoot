require 'rails_helper'

RSpec.describe Captain::Runtime::PartSchema do
  it 'tells a part to ask for everything that is still missing in one message' do
    description = described_class::STATUS_DESCRIPTION

    expect(description).to include('needs_information (you asked the patient, in one message, for everything still missing, and wait)')
    expect(description).not_to include('one precise question')
  end

  it 'offers the status as an enum of the statuses that the run of a part understands, so the provider offers no other value' do
    status = described_class.new.to_json_schema.with_indifferent_access.dig(:schema, :properties, :status)

    expect(status[:enum]).to eq(%w[answered needs_information out_of_scope unavailable])
    expect(status[:enum]).to eq(Captain::Runtime::Council::PartRun::STATUSES)
  end
end
