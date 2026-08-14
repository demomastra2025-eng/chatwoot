require 'rails_helper'

RSpec.describe Integrations::Medelement::ReceptionServiceRows do
  describe '.active' do
    it 'accepts numeric, string and boolean active markers' do
      rows = [
        { 'NOMENCLATURE_CODE' => 'numeric', 'DELETED' => 0 },
        { 'NOMENCLATURE_CODE' => 'string', 'DELETED' => '0' },
        { 'NOMENCLATURE_CODE' => 'boolean', 'DELETED' => false }
      ]

      expect(described_class.active('SERVICES' => rows).pluck('NOMENCLATURE_CODE')).to eq(%w[numeric string boolean])
    end

    it 'rejects numeric, string and boolean deleted markers' do
      rows = [
        { 'NOMENCLATURE_CODE' => 'numeric', 'DELETED' => 1 },
        { 'NOMENCLATURE_CODE' => 'string', 'DELETED' => 'true' },
        { 'NOMENCLATURE_CODE' => 'boolean', 'DELETED' => true }
      ]

      expect(described_class.active('SERVICES' => rows)).to be_empty
    end

    it 'rejects present but malformed service snapshots' do
      [nil, {}, 'invalid', [nil], [{}], [{ 'NOMENCLATURE_CODE' => '' }]].each do |services|
        expect { described_class.active('SERVICES' => services) }
          .to raise_error(described_class::InvalidSnapshotError)
      end
    end

    it 'ignores a deleted row even when it has no nomenclature code' do
      expect(described_class.active('SERVICES' => [{ 'DELETED' => true }])).to eq([])
    end

    it 'keeps a missing services field backward compatible' do
      expect(described_class.active({})).to eq([])
    end
  end
end
