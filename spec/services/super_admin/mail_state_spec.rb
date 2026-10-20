# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::MailState do
  around do |example|
    original = ENV.fetch('SMTP_ADDRESS', nil)
    example.run
  ensure
    ENV['SMTP_ADDRESS'] = original
  end

  it 'is configured when the mail server is set' do
    ENV['SMTP_ADDRESS'] = 'smtp.example.test'

    expect(described_class).to be_configured
  end

  it 'is not configured without a mail server (outside development)' do
    ENV['SMTP_ADDRESS'] = nil

    expect(described_class).not_to be_configured
  end

  it 'answers the way the mailers do' do
    [nil, '', 'smtp.example.test'].each do |address|
      ENV['SMTP_ADDRESS'] = address

      expect(described_class.configured?).to eq(ApplicationMailer.new.smtp_config_set_or_development?)
    end
  end
end
