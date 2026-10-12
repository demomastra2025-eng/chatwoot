require 'rails_helper'

RSpec.describe Integrations::Medelement::CabinetAttributes do
  it 'does not shadow Module#name (zero-argument call keeps working)' do
    expect(described_class.name).to eq('Integrations::Medelement::CabinetAttributes')
    expect(described_class.to_s).to eq('Integrations::Medelement::CabinetAttributes')
  end

  it 'reads the code from every supported key as a string' do
    expect(described_class.code('companyCabinetCode' => 501)).to eq('501')
    expect(described_class.code('company_cabinet_code' => 'cab-7')).to eq('cab-7')
    expect(described_class.code('COMPANY_CABINET_CODE' => '9')).to eq('9')
    expect(described_class.code('cabinetName' => 'No code')).to be_nil
  end

  it 'reads the name, number and type from the camel and snake case keys' do
    camel = { 'cabinetName' => 'Кабинет 2', 'cabinetNumber' => 2, 'cabinetType' => 'procedure' }
    snake = { 'cabinet_name' => 'Кабинет 3', 'cabinet_number' => '3', 'cabinet_type' => 'consulting' }

    expect(described_class.cabinet_name(camel)).to eq('Кабинет 2')
    expect(described_class.cabinet_number(camel)).to eq('2')
    expect(described_class.cabinet_type(camel)).to eq('procedure')
    expect(described_class.cabinet_name(snake)).to eq('Кабинет 3')
    expect(described_class.cabinet_number(snake)).to eq('3')
    expect(described_class.cabinet_type(snake)).to eq('consulting')
  end

  it 'returns nil for blank or missing details' do
    expect(described_class.cabinet_name('cabinetName' => '  ')).to be_nil
    expect(described_class.cabinet_number({})).to be_nil
    expect(described_class.cabinet_type(nil)).to be_nil
  end
end
