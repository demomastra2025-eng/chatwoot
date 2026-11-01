# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::DunningJob do
  include ActiveSupport::Testing::TimeHelpers

  def with_billing_env(overrides)
    previous = overrides.keys.index_with { |key| ENV.fetch(key, nil) }
    overrides.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
    yield
  ensure
    previous.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
  end

  let(:owner_user) do
    user = User.find_by(id: 6) || create(:user, id: 6)
    ActiveRecord::Base.connection.reset_pk_sequence!('users')
    user
  end
  let(:owner_workspace) do
    ws = Account.find_by(id: 48) || create(:account, id: 48, name: 'Owner Workspace')
    ActiveRecord::Base.connection.reset_pk_sequence!('accounts')
    AccountUser.find_or_create_by!(account: ws, user: owner_user) { |au| au.role = :administrator }
    ws
  end
  let(:clinic) { create(:account, name: 'ТОО Dental Plus') }
  let(:due_date) { Date.new(2026, 11, 15) }
  let(:profile) do
    Accounts::ApplyPlan.new(account: clinic, tariff: 'ai_agent_rop').call
    Billing::AccountProfile.create!(account: clinic, billing_enabled: true, paid_until: due_date, legal_name: 'ТОО Dental Plus')
  end
  let(:invoice) do
    profile
    Billing::InvoiceGeneratorService.new(account: clinic, period_start: due_date, due_on: due_date, notify: false).perform
  end

  it 'sends T-2 and T=0 gentle reminders once per stage' do
    invoice
    with_billing_env('BILLING_AUTOBILLING_ENABLED' => 'true') do
      travel_to(Time.find_zone('Asia/Almaty').local(2026, 11, 13, 10, 30, 0)) do
        described_class.perform_now
        described_class.perform_now
      end
      expect(invoice.reload.last_reminder_stage).to eq('t_minus_2')

      travel_to(Time.find_zone('Asia/Almaty').local(2026, 11, 15, 10, 30, 0)) { described_class.perform_now }
    end

    events = Array(invoice.reload.metadata['notifications']).map { |entry| entry['event'] }
    expect(invoice.last_reminder_stage).to eq('t_zero')
    expect(events).to eq(%w[dunning_t_minus_2 dunning_t_zero])
  end

  it 'escalates T+3 overdue invoice with banner and Account #48 CRM task while never disabling clinic channels' do
    inbox = create(:inbox, account: clinic)
    owner_workspace
    invoice

    with_billing_env('BILLING_AUTOBILLING_ENABLED' => 'true') do
      travel_to(Time.find_zone('Asia/Almaty').local(2026, 11, 18, 10, 30, 0)) { described_class.perform_now }
    end

    expect(invoice.reload).to have_attributes(status: 'overdue', last_reminder_stage: 't_plus_3')
    expect(profile.reload).to have_attributes(payment_overdue_banner: true, overdue_invoice_number: invoice.invoice_number)
    expect(clinic.reload.custom_attributes['payment_overdue_banner']).to be(true)
    expect(clinic.inboxes.exists?(id: inbox.id)).to be(true)
    expect(clinic.status).to eq('active')
    expect(Crm::Task.exists?(account_id: owner_workspace.id, idempotency_key: "billing:overdue:#{invoice.invoice_number}")).to be(true)
  end
end
