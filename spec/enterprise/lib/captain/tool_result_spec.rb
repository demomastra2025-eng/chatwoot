# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ToolResult do
  describe '.normalize' do
    it 'wraps plain strings as success messages' do
      result = described_class.normalize('Done')

      expect(result).to include(success: true, message: 'Done')
      expect(result[:data]).to be_nil
    end

    it 'wraps error-prefixed strings as failures' do
      result = described_class.normalize('ERROR: Tool failed')

      expect(result).to include(success: false, error: 'ERROR: Tool failed')
      expect(result[:message]).to be_nil
    end

    it 'keeps normalized hashes intact and infers success from error' do
      result = described_class.normalize({ data: { id: 1 }, error: 'Boom' })

      expect(result).to include(success: false, data: { id: 1 }, error: 'Boom')
    end

    it 'captures exceptions as error messages' do
      error = StandardError.new('Bad')
      result = described_class.normalize('ok', error: error)

      expect(result[:success]).to be(false)
      expect(result[:error]).to include('StandardError')
    end

    it 'normalizes halting tool results as success messages' do
      result = described_class.normalize(RubyLLM::Tool::Halt.new('Transferred'))

      expect(result).to include(success: true, message: 'Transferred')
      expect(result[:data]).to be_nil
    end
  end

  describe '.error?' do
    it 'detects errors in normalized payloads' do
      expect(described_class.error?('ERROR: blocked')).to be(true)
      expect(described_class.error?({ success: false })).to be(true)
      expect(described_class.error?({ error: 'nope' })).to be(true)
      expect(described_class.error?('ok')).to be(false)
    end
  end

  describe '.render' do
    it 'renders normalized failures as ERROR-prefixed strings' do
      result = described_class.render(
        described_class.failure(error: 'Tool failed', retryable: true)
      )

      expect(result).to eq('ERROR: Tool failed')
    end

    it 'renders success payloads with message and data as JSON' do
      result = described_class.render(
        described_class.success(message: 'Created', data: { id: 1 })
      )

      expect(JSON.parse(result)).to eq(
        'message' => 'Created',
        'data' => { 'id' => 1 }
      )
    end

    it 'renders halting tool results as their content' do
      expect(described_class.render(RubyLLM::Tool::Halt.new('Transferred'))).to eq('Transferred')
    end
  end
end
