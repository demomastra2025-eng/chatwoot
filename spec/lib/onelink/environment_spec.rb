require 'rails_helper'

RSpec.describe Onelink::Environment do
  it 'reads canonical values first and keeps an explicit blank authoritative' do
    with_modified_env('ONELINK_TEST_NAME' => '', 'CHATWOOT_TEST_NAME' => 'legacy') do
      expect(described_class.fetch('CHATWOOT_TEST_NAME', 'default')).to eq('')
    end
    with_modified_env('ONELINK_TEST_NAME' => 'canonical', 'CHATWOOT_TEST_NAME' => 'legacy') do
      expect(described_class.fetch('CHATWOOT_TEST_NAME')).to eq('canonical')
    end
  end

  it 'preserves the separate current and legacy image namespaces' do
    with_modified_env('ONELINK_IMAGE' => 'current', 'ONELINK_LEGACY_IMAGE' => 'retained') do
      expect(described_class.fetch('CHATWOOT_IMAGE')).to eq('current')
      expect(described_class.fetch('LEGACY_CHATWOOT_IMAGE')).to eq('retained')
    end
    expect(described_class.canonical_key('CRAFTY_WIDGET_IMAGE')).to eq('ONELINK_WIDGET_IMAGE')
  end

  it 'falls back without changing unrelated environment names' do
    with_modified_env('ONELINK_TEST_NAME' => nil, 'CHATWOOT_TEST_NAME' => 'legacy', 'UNCHANGED_TEST_NAME' => 'existing') do
      expect(described_class.fetch('CHATWOOT_TEST_NAME')).to eq('legacy')
      expect(described_class.fetch('UNCHANGED_TEST_NAME')).to eq('existing')
      expect(described_class.fetch('MISSING_TEST_NAME', 'default')).to eq('default')
    end
  end
end
