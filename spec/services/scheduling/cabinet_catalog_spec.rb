require 'rails_helper'

RSpec.describe Scheduling::CabinetCatalog do
  subject(:catalog) { described_class.new(account: account) }

  let(:account) { create(:account) }

  def create_resource(cabinets, **attributes)
    custom_attributes = attributes.delete(:custom_attributes) || {}
    create(:scheduling_resource, account: account, custom_attributes: custom_attributes.merge('medelement_cabinets' => cabinets), **attributes)
  end

  it 'is empty for an account without MedElement cabinets' do
    create(:scheduling_resource, account: account)

    expect(catalog.cabinets).to eq([])
    expect(catalog.codes).to eq([])
    expect(catalog.all_known?(['501'])).to be(false)
  end

  it 'lists cabinets with name, number and type deduplicated by code and sorted by name' do
    create_resource(
      [
        { 'companyCabinetCode' => '502', 'cabinetName' => 'Кабинет 10', 'cabinetNumber' => '10', 'cabinetType' => 'procedure' },
        { 'companyCabinetCode' => '501', 'cabinetName' => 'Кабинет 2', 'cabinetNumber' => '2' }
      ]
    )
    create_resource(
      [
        { 'companyCabinetCode' => '501', 'cabinetName' => 'Другое имя', 'cabinetNumber' => '9', 'cabinetType' => 'consulting' },
        { 'companyCabinetCode' => '503', 'cabinetName' => 'Анализы' }
      ]
    )

    expect(catalog.cabinets).to eq(
      [
        { code: '503', name: 'Анализы', number: nil, type: nil },
        { code: '501', name: 'Кабинет 2', number: '2', type: 'consulting' },
        { code: '502', name: 'Кабинет 10', number: '10', type: 'procedure' }
      ]
    )
    expect(catalog.codes).to eq(%w[503 501 502])
  end

  it 'keeps a cabinet that has no name and ignores malformed entries' do
    create_resource([{ 'companyCabinetCode' => 'cab-7' }, { 'cabinetName' => 'No code' }, 'junk', nil])

    expect(catalog.cabinets).to eq([{ code: 'cab-7', name: nil, number: nil, type: nil }])
  end

  it 'only lists cabinets of specialists available for scheduling' do
    create_resource([{ 'companyCabinetCode' => '501', 'cabinetName' => 'Active' }])
    create_resource([{ 'companyCabinetCode' => '502', 'cabinetName' => 'Inactive' }], active: false)
    create_resource([{ 'companyCabinetCode' => '503', 'cabinetName' => 'Archived' }],
                    custom_attributes: { Scheduling::Resource::DELETED_FROM_SCHEDULING_KEY => true })

    expect(catalog.codes).to eq(['501'])
  end

  it 'does not leak cabinets of other accounts' do
    create(:scheduling_resource, account: create(:account),
                                 custom_attributes: { 'medelement_cabinets' => [{ 'companyCabinetCode' => '999', 'cabinetName' => 'Foreign' }] })
    create_resource([{ 'companyCabinetCode' => '501', 'cabinetName' => 'Own' }])

    expect(catalog.codes).to eq(['501'])
  end

  describe '#all_known?' do
    let(:resource) { create_resource([{ 'companyCabinetCode' => '501', 'cabinetName' => 'Own' }]) }

    it 'accepts cabinets of available specialists' do
      resource

      expect(catalog.all_known?(['501'])).to be(true)
      expect(catalog.all_known?([501])).to be(true)
      expect(catalog.all_known?(%w[501 502])).to be(false)
      expect(catalog.all_known?([])).to be(false)
    end

    it 'accepts a code that an appointment of the account already carries' do
      archived = create_resource([{ 'companyCabinetCode' => '777', 'cabinetName' => 'Old' }], active: false)
      create(:scheduling_appointment, account: account, resource: archived, custom_attributes: { 'medelement_cabinet_code' => '777' })
      resource

      expect(catalog.all_known?(%w[501 777])).to be(true)
    end

    it 'does not trust appointment codes of another account' do
      foreign_account = create(:account)
      create(:scheduling_appointment, account: foreign_account, custom_attributes: { 'medelement_cabinet_code' => '888' })
      resource

      expect(catalog.all_known?(%w[501 888])).to be(false)
    end
  end
end
