# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/onelink/dev_runtime')

RSpec.describe Onelink::DevRuntime do
  describe 'development flags' do
    it 'keeps both modes disabled by default' do
      runtime = described_class.new({})

      expect(runtime.fast?).to be(false)
      expect(runtime.built_assets?).to be(false)
      expect(runtime.log_level).to eq(:info)
    end

    it 'enables modes only for the explicit value 1' do
      runtime = described_class.new('ONELINK_DEV_FAST' => 'true', 'ONELINK_DEV_BUILT_ASSETS' => 'yes')

      expect(runtime.fast?).to be(false)
      expect(runtime.built_assets?).to be(false)
      expect(described_class.new('ONELINK_DEV_FAST' => '1').fast?).to be(true)
      expect(described_class.new('ONELINK_DEV_BUILT_ASSETS' => '1').built_assets?).to be(true)
    end

    it 'preserves LOG_LEVEL when fast mode is off' do
      runtime = described_class.new('LOG_LEVEL' => 'warn', 'ONELINK_DEV_LOG_LEVEL' => 'debug')

      expect(runtime.log_level).to eq(:warn)
    end

    it 'uses the fast mode log override and otherwise defaults to info' do
      runtime = described_class.new('ONELINK_DEV_FAST' => '1', 'LOG_LEVEL' => 'debug')
      overridden = described_class.new('ONELINK_DEV_FAST' => '1', 'ONELINK_DEV_LOG_LEVEL' => 'error')

      expect(runtime.log_level).to eq(:info)
      expect(overridden.log_level).to eq(:error)
    end
  end
end
