require 'rails_helper'

RSpec.describe Whatsapp::PhoneNumberNormalizationService do
  subject(:service) { described_class.new(instance_double(Inbox)) }

  it 'canonicalizes Brazil old and new mobile formats to the same Cloud identity' do
    expect(service.canonical_source_id('554188887777', :cloud)).to eq('5541988887777')
    expect(service.canonical_source_id('5541988887777', :cloud)).to eq('5541988887777')
  end

  it 'canonicalizes Argentina mobile formats without the provider mobile prefix' do
    expect(service.canonical_source_id('5491112345678', :cloud)).to eq('541112345678')
    expect(service.canonical_source_id('541112345678', :cloud)).to eq('541112345678')
  end

  it 'preserves non-normalized Cloud identities after stripping provider prefixes' do
    expect(service.canonical_source_id('whatsapp:+77001234567', :cloud)).to eq('77001234567')
  end
end
