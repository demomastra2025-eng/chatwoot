# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ToolResult do
  describe '.normalize' do
    it 'keeps compact booking failures nonretryable without adding provider details to the rendered result' do
      payload = '{"success":false,"reason":"staff_will_help"}'

      expect(described_class.normalize(payload)).to include(success: false, retryable: false)
      expect(described_class.render(payload)).to eq(payload)
    end

    it 'keeps a compact validation failure that names the field a failure' do
      payload = '{"success":false,"reason":"validation_error","field":"birth_date"}'

      expect(described_class.normalize(payload)).to include(success: false, retryable: false)
      expect(described_class.render(payload)).to eq(payload)
    end

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

    it 'normalizes MCP error payloads as failures with structured data' do
      result = described_class.normalize(
        {
          content: [{ type: 'text', text: '{"error":{"message":"OpenAPI request failed"}}' }],
          isError: true,
          structuredContent: {
            error: {
              code: 'openapi_http_error',
              message: 'OpenAPI request failed',
              http_status: 502
            }
          }
        }
      )

      expect(result).to include(
        success: false,
        error: 'OpenAPI request failed',
        data: {
          error: {
            code: 'openapi_http_error',
            message: 'OpenAPI request failed',
            http_status: 502
          }
        }
      )
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
      expect(described_class.error?({ isError: true, content: [] })).to be(true)
      expect(described_class.error?('ok')).to be(false)
    end
  end

  describe '.render' do
    it 'renders normalized failures with retry guidance for the model' do
      result = described_class.render(
        described_class.failure(error: 'Tool failed', retryable: true)
      )

      expect(JSON.parse(result.delete_prefix('ERROR: '))).to eq(
        'error' => 'Tool failed',
        'retryable' => true
      )
    end

    it 'keeps structured partial data in rendered failures' do
      result = described_class.render(
        described_class.failure(error: 'Delivery failed', data: { status: 'partial', request_id: 7 }, retryable: false)
      )

      payload = JSON.parse(result.delete_prefix('ERROR: '))
      expect(payload).to eq(
        'error' => 'Delivery failed',
        'data' => { 'status' => 'partial', 'request_id' => 7 },
        'retryable' => false
      )
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

    it 'normalizes binary-encoded strings before rendering JSON payloads' do
      binary_text = 'Принято'.dup.force_encoding(Encoding::ASCII_8BIT)
      rendered = nil

      expect do
        rendered = described_class.render(described_class.success(data: { status: binary_text }))
      end.not_to output(/UTF-8 string passed as BINARY/).to_stderr

      expect(JSON.parse(rendered)).to eq('status' => 'Принято')
      expect(rendered.encoding).to eq(Encoding::UTF_8)
    end

    it 'normalizes binary-encoded success messages before returning tool content' do
      binary_message = 'Принято'.dup.force_encoding(Encoding::ASCII_8BIT)
      rendered = nil

      expect do
        rendered = described_class.render(described_class.success(message: binary_message))
        JSON.generate([{ role: 'tool', content: rendered }])
      end.not_to output(/UTF-8 string passed as BINARY/).to_stderr

      expect(rendered).to eq('Принято')
      expect(rendered.encoding).to eq(Encoding::UTF_8)
    end

    it 'renders halting tool results as their content' do
      expect(described_class.render(RubyLLM::Tool::Halt.new('Transferred'))).to eq('Transferred')
    end
  end

  describe '.no_change?' do
    it 'is true for a successful result whose status says nothing was changed or created' do
      described_class::NO_CHANGE_STATUSES.each do |status|
        text = JSON.generate(success: true, appointment_id: 4, status: status, note: 'Nothing was changed.')

        expect(described_class.no_change?(text)).to be(true)
        expect(described_class.no_change?(JSON.parse(text))).to be(true)
        expect(described_class.no_change?(described_class.normalize(text))).to be(true)
        expect(described_class.no_change?(described_class.success(message: text))).to be(true)
      end
    end

    it 'is false for a result that did change or create something, and for results with no status' do
      %w[updated created cancelled].each do |status|
        expect(described_class.no_change?(JSON.generate(success: true, status: status))).to be(false)
      end
      expect(described_class.no_change?('Done')).to be(false)
      expect(described_class.no_change?(nil)).to be(false)
      expect(described_class.no_change?('{broken json')).to be(false)
      expect(described_class.no_change?({ data: { id: 1 } })).to be(false)
    end

    it 'is false for a failure, whatever its status says' do
      expect(described_class.no_change?(JSON.generate(success: false, status: 'unchanged', reason: 'staff_will_help'))).to be(false)
      expect(described_class.no_change?(described_class.failure(error: 'Boom', data: { status: 'unchanged' }))).to be(false)
      expect(described_class.no_change?('ERROR: unchanged')).to be(false)
    end
  end
end
