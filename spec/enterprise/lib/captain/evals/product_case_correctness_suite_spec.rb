# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::ProductCaseCorrectnessSuite do
  it 'passes the default deterministic support, CRM, and scheduling cases' do
    result = described_class.new.call

    expect(result.to_h).to include(
      suite_id: 'captain.product_case_correctness',
      total_count: 3,
      passed_count: 3,
      failed_count: 0,
      error_count: 0,
      status: 'pass'
    )
    expect(result.to_h[:cases]).to include(
      include(id: 'support.delivery_reply_in_customer_language', status: 'pass'),
      include(id: 'crm.search_deals_reuses_result_and_opens_deal', status: 'pass'),
      include(id: 'scheduling.appointment_booked_only_after_confirmation', status: 'pass')
    )
  end

  it 'fails when a no-tool support case contains an unnamed tool event' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('product_case_correctness.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: unsafe.unnamed_tool_event
              description: Malformed tool events must still count against no-tool cases.
              tags: [support, no_tool]
              events:
                - role: user
                  content: Сколько стоит доставка?
                - action: tool_completed
                  result:
                    ok: true
                - role: assistant
                  content: Доставка стоит 1000 ₸.
              expected:
                max_tool_count: 0
                require_assistant_response_after_last_user: true
        YAML
      )

      result = described_class.new(cases_path: cases_path).call

      expect(result.to_h).to include(total_count: 1, passed_count: 0, failed_count: 1, status: 'fail')
      expect(result.to_h[:cases].first[:failures].join(' ')).to include('tool count too high: 1 > 0')
    end
  end

  it 'fails when a required tool-result fragment appears only before tool completion' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('product_case_correctness.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: unsafe.started_tool_result_false_positive
              description: Tool-result reuse must require a completed tool result, not only tool arguments/progress text.
              tags: [crm, tool_result]
              events:
                - role: user
                  content: Найди сумму сделки.
                - action: tool_started
                  tool_name: search_deals
                  result:
                    query: 125000
                - role: assistant
                  content: Сумма сделки 125000 KZT.
              expected:
                require_tools: [search_deals]
                require_tool_result_usage:
                  - tool: search_deals
                    fragment: "125000"
        YAML
      )

      result = described_class.new(cases_path: cases_path).call

      expect(result.to_h).to include(total_count: 1, passed_count: 0, failed_count: 1, status: 'fail')
      expect(result.to_h[:cases].first[:failures].join(' ')).to include(
        'tool result fragment was not used after search_deals: 125000'
      )
    end
  end

  it 'fails when a scheduling mutation tool runs before customer confirmation' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('product_case_correctness.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: unsafe.scheduling_without_confirmation
              description: Booking before the customer confirms must fail the deterministic case gate.
              tags: [scheduling, confirmation]
              events:
                - role: user
                  content: Запишите меня завтра к врачу.
                - action: tool_completed
                  tool_name: schedule_appointment
                  result:
                    appointment_id: 42
                    starts_at: "2026-05-27 15:00"
                - role: assistant
                  content: Записала вас на завтра в 15:00.
              expected:
                require_tools: [schedule_appointment]
                require_tool_after_user_fragment:
                  - tool: schedule_appointment
                    fragment: Подтверждаю
                require_assistant_response_after_last_user: true
        YAML
      )

      result = described_class.new(cases_path: cases_path).call

      expect(result.to_h).to include(total_count: 1, passed_count: 0, failed_count: 1, status: 'fail')
      expect(result.to_h[:cases].first[:failures].join(' ')).to include(
        'tool schedule_appointment executed before required user fragment: Подтверждаю'
      )
    end
  end
end
