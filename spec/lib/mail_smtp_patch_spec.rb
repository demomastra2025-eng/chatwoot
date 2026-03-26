# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Mail::SMTP do
  describe '#ssl_context' do
    it 'applies ssl_context_params on top of openssl verify mode' do
      smtp = described_class.new(
        openssl_verify_mode: 'none',
        ssl_context_params: {
          verify_mode: OpenSSL::SSL::VERIFY_NONE,
          verify_hostname: false
        }
      )

      context = smtp.send(:ssl_context)

      expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_NONE)
      expect(context.verify_hostname).to be(false)
    end

    it 'keeps hostname verification enabled for peer mode' do
      smtp = described_class.new(
        openssl_verify_mode: 'peer',
        ssl_context_params: {
          verify_mode: OpenSSL::SSL::VERIFY_PEER,
          verify_hostname: true
        }
      )

      context = smtp.send(:ssl_context)

      expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
      expect(context.verify_hostname).to be(true)
    end
  end

  describe '#build_smtp_session' do
    it 'propagates native net-smtp tls settings' do
      smtp = described_class.new(
        address: 'smtp.example.com',
        port: 587,
        enable_starttls_auto: true,
        openssl_verify_mode: 'none',
        ssl: false,
        tls: false,
        tls_verify: false,
        tls_hostname: 'smtp.example.com',
        ssl_context_params: {
          verify_mode: OpenSSL::SSL::VERIFY_NONE,
          verify_hostname: false
        }
      )

      session = smtp.send(:build_smtp_session)
      context = session.instance_variable_get(:@ssl_context_starttls)

      expect(session.tls_verify).to be(false)
      expect(session.tls_hostname).to eq('smtp.example.com')
      expect(session.starttls?).to eq(:auto)
      expect(session.ssl_context_params).to eq(
        verify_mode: OpenSSL::SSL::VERIFY_NONE,
        verify_hostname: false
      )
      expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_NONE)
      expect(context.verify_hostname).to be(false)
    end

    it 'does not let ssl false suppress explicit starttls configuration' do
      smtp = described_class.new(
        address: 'smtp.example.com',
        port: 587,
        ssl: false,
        enable_starttls_auto: true,
        ssl_context_params: {
          verify_mode: OpenSSL::SSL::VERIFY_NONE,
          verify_hostname: false
        }
      )

      session = smtp.send(:build_smtp_session)

      expect(session.starttls?).to eq(:auto)
      expect(session.instance_variable_get(:@ssl_context_starttls).verify_hostname).to be(false)
    end
  end
end
