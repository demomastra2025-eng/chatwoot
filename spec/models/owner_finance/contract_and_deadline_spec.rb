# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'OwnerFinance::Contract and OwnerFinance::Deadline', type: :model do
  describe 'Contract expiry auto-sync and MedElement 30% base rule' do
    it 'automatically creates a linked contract expiry deadline and computes 30% base commission' do
      contract = OwnerFinance::Contract.create!(
        client_name: 'Клиника Сезім', contract_number: 'OL-2026-07',
        title: 'Тариф Текстовый ИИ + РОП', status: 'active', tariff_code: 'ai_agent_rop_199k',
        monthly_amount: 199_000, one_time_amount: 100_000, currency: 'KZT',
        starts_on: Date.new(2026, 10, 1), ends_on: Date.new(2027, 10, 1),
        medelement_commission_enabled: true, medelement_commission_rate: 0.3
      )

      expect(contract.medelement_monthly_commission_kzt).to eq(BigDecimal(59_700))
      expiry_dl = OwnerFinance::Deadline.find_by(external_source_key: "contract_expiry:#{contract.id}")
      expect(expiry_dl.category).to eq('contract')
      expect(expiry_dl.due_on).to eq(Date.new(2027, 10, 1))
      expect(expiry_dl.remind_days).to eq([7, 3, 2, 1, 0])
    end

    it 'updates and removes the linked expiry deadline when ends_on changes' do
      contract = OwnerFinance::Contract.create!(
        client_name: 'Клиника Сезім', title: 'Тариф Текстовый ИИ + РОП',
        status: 'active', tariff_code: 'ai_agent_rop_199k', monthly_amount: 199_000,
        currency: 'KZT', ends_on: Date.new(2027, 10, 1)
      )
      expiry_dl = OwnerFinance::Deadline.find_by!(external_source_key: "contract_expiry:#{contract.id}")

      contract.update!(ends_on: Date.new(2027, 11, 15))
      expect(expiry_dl.reload.due_on).to eq(Date.new(2027, 11, 15))

      contract.update!(ends_on: nil)
      expect(OwnerFinance::Deadline.find_by(external_source_key: "contract_expiry:#{contract.id}")).to be_nil
    end
  end

  describe 'Deadline recurrence advance and urgency' do
    it 'advances recurring deadlines and completes one-time deadlines' do
      ref_date = Date.new(2026, 10, 30)
      yearly = OwnerFinance::Deadline.create!(
        title: 'Продление домена kuanov.kz', category: 'client_domain',
        payer_mode: 'rebill_client', related_domain: 'kuanov.kz',
        due_on: Date.new(2026, 11, 1), amount: 6500, currency: 'KZT', recurrence: 'yearly'
      )

      expect(yearly.days_left(ref_date)).to eq(2)
      expect(yearly.urgency(ref_date)).to eq('critical')
      yearly.advance_or_complete!(reference_date: ref_date)
      expect(yearly.reload.due_on).to eq(Date.new(2027, 11, 1))

      once_dl = OwnerFinance::Deadline.create!(
        title: 'Оплата счёта № 8763042 ps.kz', category: 'hosting',
        payer_mode: 'us', due_on: Date.new(2026, 11, 12), amount: 130_480, currency: 'KZT', recurrence: 'once'
      )
      once_dl.advance_or_complete!(reference_date: ref_date)
      expect(once_dl.reload.status).to eq('completed')
    end
  end
end
