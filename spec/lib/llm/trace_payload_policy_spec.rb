# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::TracePayloadPolicy do
  after do
    described_class.reset_redaction_hooks!
  end

  describe '.capture' do
    it 'returns nil when the capture direction is disabled' do
      payload = described_class.capture(
        { secret: 'value' },
        direction: :input,
        preferences: { 'trace_input_capture' => false }
      )

      expect(payload).to be_nil
    end

    it 'sanitizes sensitive values before exporting captured payloads' do
      payload = described_class.capture(
        { api_key: 'top-secret', prompt_tokens: 15 },
        direction: :input,
        preferences: { 'trace_input_capture' => true }
      )

      expect(payload).to include('[REDACTED]')
      expect(payload).to include('15')
      expect(payload).not_to include('top-secret')
    end

    it 'applies custom redaction hooks before the sanitizer' do
      described_class.register_redaction_hook('email') do |value, **|
        value.deep_transform_values do |entry|
          entry.is_a?(String) ? entry.gsub(/[\w+\-.]+@[a-z\d\-.]+\.[a-z]+/i, '[EMAIL]') : entry
        end
      end

      payload = described_class.capture(
        { message: 'Contact me at test@example.com' },
        direction: :output,
        preferences: { 'trace_output_capture' => true }
      )

      expect(payload).to include('[EMAIL]')
      expect(payload).not_to include('test@example.com')
    end

    it 'keeps content fields when trace capture is explicitly enabled' do
      payload = described_class.capture(
        [{ role: 'user', content: [{ type: 'image_url', image_url: { url: 'https://example.com/image.jpg' } }] }],
        direction: :input,
        preferences: { 'trace_input_capture' => true }
      )

      expect(payload).to include('image_url')
      expect(payload).to include('https://example.com/image.jpg')
    end
  end

  describe '.trace_attributes' do
    it 'returns normalized capture flags' do
      expect(
        described_class.trace_attributes(
          preferences: {
            'trace_input_capture' => false,
            'trace_output_capture' => true
          }
        )
      ).to eq(
        'trace_input_capture' => false,
        'trace_output_capture' => true
      )
    end
  end
end
