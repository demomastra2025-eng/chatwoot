require 'rails_helper'

RSpec.describe Crm::Appointments::PlanService do
  let(:deal) { create(:crm_deal) }
  let(:appointment) { create(:scheduling_appointment, account: deal.account, crm_deal: deal) }
  let(:actor) { create(:user, account: deal.account) }

  def save_plan(plan, **attributes)
    described_class.new(deal: deal.reload, actor: actor,
                        params: { lock_version: deal.lock_version, appointment_plan: plan, **attributes }).perform
  end

  it 'persists an explicit required plan and selected target with a native audit event' do
    save_plan([{ id: 'visit-1', label: 'First treatment', required: true, appointment_id: appointment.id },
               { id: 'visit-2', label: 'Second treatment', required: true }], selected_appointment_id: appointment.id)

    expect(deal.reload.appointment_plan.last['appointment_id']).to be_nil
    expect(deal.selected_appointment_id).to eq(appointment.id)
    expect(deal.events.last.meta['appointment_plan_changed']).to be true
  end

  it 'does not allow the same appointment to fulfill multiple required planned visits' do
    expect do
      save_plan([{ id: 'a', label: 'A', appointment_id: appointment.id }, { id: 'b', label: 'B', appointment_id: appointment.id }])
    end.to raise_error(ArgumentError, 'A visit can fulfill only one planned appointment')
    expect(deal.reload.appointment_plan).to eq([])
  end

  it 'rejects another deal or account appointment as a planned or selected target' do
    unrelated = create(:scheduling_appointment, account: deal.account)
    expect { save_plan([{ label: 'Visit', appointment_id: unrelated.id }]) }.to raise_error(ActiveRecord::RecordNotFound)
    expect { save_plan([], selected_appointment_id: create(:scheduling_appointment).id) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it 'requires the current version and preserves cancellation until an explicit plan edit' do
    save_plan([{ id: 'a', label: 'Visit', appointment_id: appointment.id }])
    appointment.update!(status: 'cancelled')
    expect(deal.reload.appointment_plan.first['appointment_id']).to eq(appointment.id)
    expect do
      described_class.new(deal: deal, actor: actor, params: { lock_version: -1, appointment_plan: [] }).perform
    end.to raise_error(ActiveRecord::StaleObjectError)
    save_plan([])
    expect(deal.reload.appointment_plan).to eq([])
    expect(appointment.reload.status).to eq('cancelled')
  end
end
