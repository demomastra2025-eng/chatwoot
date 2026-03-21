require 'rails_helper'

RSpec.describe Integrations::Medelement::SpecialistsSyncService do
  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      time_zone: 'Asia/Almaty'
    )
  end

  before do
    allow(client).to receive(:get_specialists).and_return(
      [
        {
          'specialistCode' => '27492901726817790',
          'userName' => 'Сералиева Гульшат',
          'receptionTime' => 20,
          'isSchedulePublished' => 1,
          'cabinets' => [
            {
              'companyCabinetCode' => '37413011726129875',
              'cabinetName' => 'УЗИ ( кб. №14 )'
            }
          ]
        }
      ]
    )
  end

  it 'creates default work rules for imported specialists so they can accept manual bookings' do
    expect do
      described_class.new(account: account, client: client, configuration: configuration).perform
    end.to change(account.scheduling_resources, :count).by(1)
                                                       .and change(account.scheduling_work_rules, :count).by(7)

    resource = account.scheduling_resources.last

    expect(resource.work_rules.order(:weekday).pluck(:weekday, :start_minute, :end_minute)).to eq(
      (0..6).map { |weekday| [weekday, 0, 1440] }
    )
    expect(resource.custom_attributes['medelement_default_work_rules_seeded_at']).to be_present
  end

  it 'does not recreate work rules after the default schedule has already been seeded once' do
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => '27492901726817790',
        'medelement_default_work_rules_seeded_at' => 1.day.ago.iso8601
      }
    )
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)

    expect do
      described_class.new(account: account, client: client, configuration: configuration).perform
    end.not_to change(account.scheduling_work_rules, :count)
  end
end
