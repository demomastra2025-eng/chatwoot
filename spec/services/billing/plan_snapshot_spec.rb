require 'rails_helper'

RSpec.describe Billing::PlanSnapshot do
  def compile(**)
    described_class.compile(tariff: 'text_call', defaults: Accounts::Plans::LIMIT_KEYS.index_with(nil), **)
  end

  it 'uses the sole catalogue and explicit resolved defaults without touching a workspace' do
    result = compile(overrides: { agents: 17, storage_bytes: 'unlimited' })
    plan, price = result.values_at(:plan_snapshot, :price_snapshot)

    expect(plan).to include('catalog_version' => Accounts::Plans.version, 'modules' => Accounts::Plans.tariff_modules('text_call'))
    expect(plan['limits']).to include('agents' => 17, 'storage_bytes' => Accounts::Plans.unlimited_value('storage_bytes'))
    expect(plan['limit_sources']).to include('agents' => 'custom', 'storage_bytes' => 'unlimited', 'captain_tokens' => 'default')
    expect(price['pricing']['monthly_kzt']).to eq(Accounts::Plans.tariff_pricing('text_call')['monthly_kzt'])
    expect(described_class.valid?(plan, price)).to be(true)
  end

  it 'does not fill unknown monetary or missing limit terms with a new default' do
    expect { described_class.compile(tariff: 'text_call') }.to raise_error(ArgumentError, /unresolved default/)
    expect { described_class.compile(tariff: 'enterprise') }.to raise_error(ArgumentError, /custom monetary terms/)
    expect { compile(overrides: { invented_seat_unit: 1 }) }.to raise_error(ArgumentError, /unknown limit/)
    expect { compile(overrides: { agents: -1 }) }.to raise_error(ArgumentError, /invalid override/)
  end

  it 'does not reread current catalogue values to validate an already compiled historical snapshot' do
    result = compile
    replacement = instance_double(Accounts::Plans, version: 999)
    allow(Accounts::Plans).to receive(:current).and_return(replacement)

    expect(described_class.valid_historical?(*result.values_at(:plan_snapshot, :price_snapshot))).to be(true)
  end

  it 'rejects incomplete, mismatched, malformed and privately extended contracts' do
    result = compile
    plan, price = result.values_at(:plan_snapshot, :price_snapshot)
    expect(described_class.valid?(plan.except('limit_sources'), price)).to be(false)
    expect(described_class.valid?(plan, price.merge('tariff' => 'voice_ai'))).to be(false)
    expect(described_class.valid?(plan.merge('limits' => { 'agents' => -1 }), price)).to be(false)
    expect(described_class.valid?(plan.merge('private_data' => 'not contract data'), price)).to be(false)
  end
end
