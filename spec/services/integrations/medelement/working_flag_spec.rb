require 'rails_helper'

RSpec.describe Integrations::Medelement::WorkingFlag do
  it 'normalizes boolean, integer and string working values consistently' do
    expect([true, 1, 'true', '1'].map { |value| described_class.working?(value) }).to all(be(true))
    expect([false, 0, 'false', '0', 'unknown', nil].map { |value| described_class.working?(value) }).to all(be(false))
  end
end
