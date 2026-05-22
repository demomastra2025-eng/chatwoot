# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::EventContractTraceSuite do
  it 'passes the default deterministic event-contract project cases' do
    result = described_class.new.call

    expect(result.to_h).to include(
      suite_id: 'captain.event_contract_trace',
      total_count: 7,
      passed_count: 7,
      failed_count: 0,
      error_count: 0,
      status: 'pass'
    )
    expect(result.to_h[:cases]).to include(
      include(id: 'customer_support.basic_no_tool', status: 'pass'),
      include(id: 'crm.lookup_tool', status: 'pass'),
      include(id: 'scheduling.tool_wait', status: 'pass'),
      include(id: 'semantic.invalid_artifact_ids', status: 'pass'),
      include(id: 'semantic.invalid_handoff_output', status: 'pass'),
      include(id: 'semantic.reserved_runtime_action', status: 'pass'),
      include(id: 'provider.failure', status: 'pass')
    )
  end

  it 'fails fixtures with raw content keys, bad canonical names, and unsafe UI actions' do
    Dir.mktmpdir do |dir|
      fixture_root = Rails.root.join('config/llm_evals/fixtures/captain/event_contract')
      fixture_path = fixture_root.join('unsafe_event_contract_fixture.json')
      cases_path = Pathname.new(dir).join('event_contract.yml')

      fixture_path.write(
        JSON.pretty_generate(
          [
            {
              name: 'llm.chat.complete',
              payload: {
                project_case_id: 'unsafe.case',
                canonical_event_name: 'llm.chat.wrong',
                prompt: 'private prompt',
                result_message_preview: 'private tool result',
                ui_actions: [
                  { type: 'open_deal', label: 'Open', target_id: '1', raw_url: 'javascript:alert(1)' }
                ]
              }
            }
          ]
        )
      )
      cases_path.write(
        <<~YAML
          cases:
            - id: unsafe.case
              fixture: config/llm_evals/fixtures/captain/event_contract/unsafe_event_contract_fixture.json
              expected:
                required_events: [llm.chat.complete]
                required_ui_actions: [open_deal]
                max_event_payload_bytes: 8192
        YAML
      )

      result = described_class.new(cases_path: cases_path).call

      expect(result.to_h).to include(total_count: 1, passed_count: 0, failed_count: 1, status: 'fail')
      expect(result.to_h[:cases].first[:failures].join(' ')).to include(
        'raw content keys present',
        'raw preview keys present',
        'canonical event mismatches',
        'unsafe ui_actions present'
      )
    ensure
      FileUtils.rm_f(fixture_path) if defined?(fixture_path)
    end
  end
end
