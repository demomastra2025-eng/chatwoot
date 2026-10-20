# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::Contracts::RenewalSweepService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:pipeline) do
    Crm::Pipeline.create!(
      account: account,
      name: '2. Действующие договоры / Продления',
      code: 'od_coworking_execution',
      active: true
    )
  end
  let!(:paid_stage) do
    Crm::Stage.create!(
      account: account,
      pipeline: pipeline,
      name: '3. Действующий договор (оплачено)',
      code: 'od_exec_paid',
      outcome: 'open',
      color: '#16A34A',
      position: 3,
      active: true,
      default: true
    )
  end
  let!(:expiring_stage) do
    Crm::Stage.create!(
      account: account,
      pipeline: pipeline,
      name: '4. Истекает (< 30 дней) — на продление',
      code: 'od_exec_expiring',
      outcome: 'open',
      color: '#7C3AED',
      position: 4,
      active: true
    )
  end
  let(:reference_date) { Date.new(2026, 10, 20) }

  before do
    Crm::TaskStatus.find_or_create_by!(account: account, code: 'todo') do |s|
      s.name = 'К выполнению'
      s.category = 'open'
      s.position = 1
    end
    Crm::TaskType.find_or_create_by!(account: account, code: 'task') do |t|
      t.name = 'Задача'
      t.position = 1
    end
  end

  it 'transitions paid deals expiring within 30 days and leaves future deals untouched' do
    expiring_deal = Crm::Deal.create!(
      account: account,
      pipeline: pipeline,
      stage: paid_stage,
      owner: user,
      creator: user,
      title: 'Договор OD — Alpha Ltd.',
      expected_close_on: reference_date + 20.days,
      custom_attributes: {
        'od_contract_reference' => '№ 201025 от 20.10.2025',
        'od_source_company_name' => 'Alpha Ltd.',
        'od_renewal_state' => 'active'
      }
    )

    far_future_deal = Crm::Deal.create!(
      account: account,
      pipeline: pipeline,
      stage: paid_stage,
      owner: user,
      creator: user,
      title: 'Договор OD — Beta Ltd.',
      expected_close_on: reference_date + 120.days,
      custom_attributes: { 'od_renewal_state' => 'active' }
    )

    report = described_class.new(account: account, reference_date: reference_date).perform

    expect(report[:Transitioned] || report[:transitioned]).to eq([expiring_deal.id])
    expect(expiring_deal.reload.stage_id).to eq(expiring_stage.id)
    expect(expiring_deal.custom_attributes['od_renewal_state']).to eq('expires_soon')
    expect(far_future_deal.reload.stage_id).to eq(paid_stage.id)
  end

  it 'creates an idempotent renewal task with 7-day lead time' do
    expiring_deal = Crm::Deal.create!(
      account: account,
      pipeline: pipeline,
      stage: paid_stage,
      owner: user,
      creator: user,
      title: 'Договор OD — Alpha Ltd.',
      expected_close_on: reference_date + 20.days,
      custom_attributes: { 'od_source_company_name' => 'Alpha Ltd.' }
    )

    described_class.new(account: account, reference_date: reference_date).perform
    second_report = described_class.new(account: account, reference_date: reference_date).perform

    task = Crm::Task.find_by(account_id: account.id, deal_id: expiring_deal.id)
    expect(task.title).to include('Alpha Ltd.')
    expect(task.due_on).to eq(reference_date + 13.days)
    expect(second_report[:transitioned]).to be_empty
    expect(Crm::Task.where(account_id: account.id, deal_id: expiring_deal.id).count).to eq(1)
  end
end
