require 'rails_helper'

RSpec.describe Whatsapp::UsageCostEstimator do
  let(:month) { Time.utc(2026, 10, 1) }
  let(:exchange_rate) { instance_double(WhatsappUsageExchangeRate, rate_per_usd: BigDecimal(500)) }

  def estimate(groups, exchange_rate: self.exchange_rate, at: month)
    described_class.new(groups: groups, month: at, exchange_rate: exchange_rate).perform
  end

  it 'includes paid service and all four template categories at published Kazakhstan USD base rates' do
    groups = %w[service marketing utility authentication authentication-international].to_h do |category|
      [[category, true, 'KZ'], 1]
    end

    expect(estimate(groups)).to include(
      chargeable_message_count: 5, chargeable_service_count: 1, chargeable_template_count: 4,
      estimated_service_amount_kzt: BigDecimal(9), estimated_template_amount_kzt: BigDecimal('128.2'),
      estimated_amount_kzt: BigDecimal('137.2'), cost_complete: true
    )
  end

  it 'does not subtract a quota again or charge Meta nonbillable messages with unknown country and category' do
    groups = { ['service', true, 'KZ'] => 1, ['marketing', false, nil] => 1_000, [nil, false, nil] => 1 }

    expect(estimate(groups)).to include(chargeable_message_count: 1, estimated_amount_kzt: BigDecimal(9), cost_complete: true)
  end

  it 'reports the known subtotal and unknown pricing without inventing a cost' do
    groups = { ['marketing', true, 'KZ'] => 1, ['utility', true, nil] => 2, ['service', nil, 'KZ'] => 3 }

    expect(estimate(groups)).to include(estimated_amount_kzt: BigDecimal('30.2'), unknown_billable_count: 3,
                                        unpriced_billable_count: 2, chargeable_message_count: 3, cost_complete: false)
  end

  it 'leaves only unpriced paid messages unavailable instead of reporting zero' do
    expect(estimate({ ['future_category', true, 'KZ'] => 1 })).to include(
      estimated_amount_kzt: nil, unpriced_billable_count: 1, cost_complete: false
    )
  end

  it 'does not reuse expired catalog rates for another quarter' do
    expect(estimate({ ['utility', true, 'KZ'] => 1 }, at: Time.utc(2027, 1, 1))).to include(
      estimated_amount_kzt: nil, unpriced_billable_count: 1, cost_complete: false
    )
  end

  it 'retains zero for known free messages even when no FX is available' do
    expect(estimate({ ['service', false, 'KZ'] => 1 }, exchange_rate: nil)).to include(
      estimated_amount_kzt: BigDecimal(0), cost_complete: true
    )
  end

  it 'leaves paid amounts unavailable when the monthly FX is missing' do
    expect(estimate({ ['service', true, 'KZ'] => 1 }, exchange_rate: nil)).to include(
      estimated_amount_kzt: nil, chargeable_service_count: 1, cost_complete: false
    )
  end

  it 'rounds after multiplication instead of rounding each message first' do
    allow(exchange_rate).to receive(:rate_per_usd).and_return(BigDecimal(1))

    expect(estimate({ ['service', true, 'KZ'] => 3 })[:estimated_amount_kzt]).to eq(BigDecimal('0.05'))
  end
end
