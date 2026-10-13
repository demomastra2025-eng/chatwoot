require 'rails_helper'

RSpec.describe Captain::Runtime::PartSchema do
  it 'tells a part to ask for everything that is still missing in one message' do
    description = described_class::STATUS_DESCRIPTION

    expect(description).to include('needs_information (you asked the patient, in one message, for everything still missing, and wait)')
    expect(description).not_to include('one precise question')
  end
end
