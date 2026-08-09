require 'rails_helper'

RSpec.describe Scheduling::Appointments::UpsertService do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: resource) }

  def perform(params)
    described_class.new(account: account, appointment: appointment, params: params).perform
  end

  it 'rejects generic mutations of imported Medelement appointments' do
    appointment.update!(source: 'medelement', external_ref: 'medelement:reception:upsert')

    expect { perform(client_comment: 'Changed') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_READ_ONLY')
    end
    expect(appointment.reload.client_comment).to be_nil
  end

  it 'rejects direct assignment of appointment provenance' do
    expect { perform(source: 'medelement') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_SOURCE_READ_ONLY')
    end
    expect(appointment.reload.source).to eq('manual')
  end

  it 'reserves Medelement external references for the provider importer' do
    expect { perform(external_ref: ' medelement:reception:spoofed') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_EXTERNAL_REF_RESERVED')
    end
    expect(appointment.reload.external_ref).to be_nil
  end

  it 'stores structured patient names while requiring only the first name locally' do
    perform(client_first_name: 'Айжан', client_last_name: '', client_middle_name: '')

    expect(appointment.reload).to have_attributes(
      client_first_name: 'Айжан',
      client_last_name: nil,
      client_middle_name: nil,
      client_name: 'Айжан'
    )
  end

  it 'composes the display name from all structured patient name fields' do
    perform(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна'
    )

    expect(appointment.reload).to have_attributes(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна',
      client_name: 'Айжан Касымова Ерлановна'
    )
  end
end
