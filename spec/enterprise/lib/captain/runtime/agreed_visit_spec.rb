# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::AgreedVisit do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }

  around do |example|
    travel_to(Time.zone.parse('2026-10-09 12:00:00 UTC')) { example.run }
  end

  before { account.enable_features!('scheduling') }

  def visit(starts_at, **attributes)
    create(:scheduling_appointment, account: account, contact: contact, resource: resource, starts_at: starts_at,
                                    ends_at: starts_at + 30.minutes, **attributes)
  end

  it 'is nothing without a conversation, a contact or any visit' do
    expect(described_class.for(nil)).to eq(described_class::NONE)
    expect(described_class::NONE).not_to be_agreed
    expect(described_class.for(conversation)).not_to be_agreed
    expect(described_class.for(conversation).times).to eq([])
  end

  it 'holds the local starts of the upcoming visits booked from the chat of the contact' do
    visit(Time.zone.parse('2026-10-10 05:00:00 UTC'))
    visit(Time.zone.parse('2026-10-11 09:30:00 UTC'), patient_contact: create(:contact, account: account))
    visit(Time.zone.parse('2026-10-12 05:00:00 UTC'), status: 'cancelled')
    create(:scheduling_appointment, account: account, contact: create(:contact, account: account), resource: resource,
                                    starts_at: Time.zone.parse('2026-10-13 06:00:00 UTC'))

    agreed = described_class.for(conversation)

    expect(agreed).to be_agreed
    expect(agreed).not_to be_pending
    expect(agreed.times).to eq(%w[10:00 14:30])
  end

  it 'counts a booking or a move card that waits for the approval of staff, and no other card' do
    allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:pending_for).and_return([{ 'tool_name' => 'cancel_appointment' }])
    expect(described_class.for(conversation)).not_to be_agreed

    allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:pending_for).and_return([{ 'tool_name' => 'create_appointment' }])
    expect(described_class.for(conversation)).to be_pending.and be_agreed

    allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:pending_for).and_return([{ 'tool_name' => 'update_appointment' }])
    expect(described_class.for(conversation)).to be_pending
  end

  it 'is nothing, never an error, when the visits cannot be read' do
    allow(Captain::AppointmentContext).to receive(:new).and_raise(ActiveRecord::StatementInvalid)

    expect(described_class.for(conversation)).to eq(described_class::NONE)
  end
end
