# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::AlertNotifier do
  describe '#call' do
    let(:account) { create(:account) }
    let!(:admin) { create(:user, account: account, role: :administrator, email: 'admin@example.com') }
    let(:report_hash) do
      {
        generated_at: Time.current.iso8601,
        operational: {
          alerts: {
            alerts: [
              {
                name: 'error_rate',
                severity: 'critical',
                message: 'Error rate crossed the configured threshold.'
              }
            ]
          }
        },
        evals: {
          deterministic: {
            suites: [
              {
                suite_id: 'llm.moderation',
                status: 'fail',
                failed_count: 1,
                error_count: 0,
                total_count: 4
              }
            ]
          },
          live: {
            suites: []
          }
        },
        checks: [
          {
            name: 'operational_release_gate',
            status: 'fail',
            blocking: true
          }
        ]
      }
    end
    let(:report) { instance_double(Llm::ReleaseCheck::Report, to_h: report_hash) }
    let(:runner) { instance_double(Llm::ReleaseCheck::Runner, call: report) }
    let(:mailer_delivery) { instance_double(ActionMailer::MessageDelivery, deliver_later: true) }
    let(:mailer_proxy) { instance_double(AdministratorNotifications::CaptainObservabilityMailer, alert_digest: mailer_delivery) }
    let(:now) { Time.zone.parse('2026-04-11 12:00:00 UTC') }

    before do
      account.update!(
        captain_observability: {
          'alert_channels' => {
            'enabled' => true,
            'minimum_severity' => 'warning',
            'email_recipients' => [],
            'webhook_url' => 'https://example.com/hooks/captain',
            'notify_on' => %w[operational_release_gate deterministic_evals]
          }
        }
      )

      allow(AdministratorNotifications::CaptainObservabilityMailer).to receive(:with)
        .with(account: account)
        .and_return(mailer_proxy)
      allow(WebhookJob).to receive(:perform_later)
    end

    it 'delivers email and webhook notifications and persists delivery state' do
      result = described_class.new(account: account, now: now, runner: runner).call

      expect(result[:status]).to eq('delivered')
      expect(result[:incident_count]).to eq(2)
      expect(result[:deliveries]).to match_array(%w[email webhook])
      expect(AdministratorNotifications::CaptainObservabilityMailer).to have_received(:with).with(account: account)
      expect(WebhookJob).to have_received(:perform_later).with(
        'https://example.com/hooks/captain',
        hash_including(event: 'captain.observability.alert_digest'),
        :account_webhook
      )

      state = described_class.state_for(account.reload)
      expect(state).to include(
        status: 'delivered',
        active_alert_count: 2,
        last_delivery_channels: match_array(%w[email webhook]),
        last_delivery_at: now.iso8601
      )
    end

    it 'throttles identical incidents during the cooldown window' do
      described_class.new(account: account, now: now, runner: runner).call

      result = described_class.new(account: account, now: now + 15.minutes, runner: runner).call

      expect(result[:status]).to eq('throttled')
      expect(AdministratorNotifications::CaptainObservabilityMailer).to have_received(:with).once
      expect(WebhookJob).to have_received(:perform_later).once
      expect(described_class.state_for(account.reload)).to include(
        status: 'throttled',
        active_alert_count: 2
      )
    end

    it 'does not enable live evals when it builds its own release-check runner' do
      generated_runner = instance_double(Llm::ReleaseCheck::Runner, call: report)
      allow(Llm::ReleaseCheck::Runner).to receive(:new).and_return(generated_runner)

      described_class.new(account: account, now: now).call

      expect(Llm::ReleaseCheck::Runner).to have_received(:new).with(
        account: account,
        date_range: kind_of(Range),
        include_live_evals: false
      )
    end
  end
end
