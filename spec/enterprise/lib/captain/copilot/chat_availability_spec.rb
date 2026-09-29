require 'rails_helper'

RSpec.describe Captain::Copilot::ChatAvailability do
  it 'keeps the employee Copilot chat disabled' do
    expect(described_class.enabled?).to be(false)
  end
end
