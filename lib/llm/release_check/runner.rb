# frozen_string_literal: true

module Llm
  module ReleaseCheck
    class Runner
      def initialize(account: nil, date_range: nil, filters: {}, evaluation_model: nil, include_live_evals: true, now: Time.current)
        @account = account
        @date_range = date_range
        @filters = filters.to_h.with_indifferent_access.compact_blank
        @evaluation_model = evaluation_model
        @include_live_evals = include_live_evals
        @now = now
      end

      def call
        release_gate = operational_release_gate
        alerts = operational_alerts(release_gate)
        deterministic_evals = deterministic_eval_collection
        live_evals = live_eval_collection
        combined_evals = combined_eval_collection(deterministic_evals, live_evals)

        Report.new(
          generated_at: @now,
          account_id: @account&.id,
          date_range: @date_range,
          filters: @filters.to_h,
          operational: {
            release_gate: release_gate,
            alerts: alerts
          },
          evals: {
            status: combined_evals.status,
            deterministic: deterministic_evals.to_h,
            live: live_evals&.to_h,
            combined: combined_evals.to_h
          },
          checks: [
            operational_check(release_gate, alerts),
            eval_check('deterministic_evals', deterministic_evals),
            live_eval_check(live_evals)
          ]
        )
      end

      private

      def operational_release_gate
        return not_applicable_release_gate unless @account

        events_query.release_gate(account: @account)
      end

      def operational_alerts(release_gate)
        return { status: 'not_applicable', active_count: 0, alerts: [] } unless @account

        Llm::Monitoring::AlertEvaluator.new(release_gate_report: release_gate).call
      end

      def deterministic_eval_collection
        Llm::Evals::CollectionResult.new(
          suites: [
            Llm::Evals::ModerationSuite.new.call,
            Captain::Evals::ToolSafetySuite.new.call
          ]
        )
      end

      def live_eval_collection
        return nil unless @account && @include_live_evals

        Llm::Evals::CollectionResult.new(
          suites: [
            Captain::Evals::ConversationCompletionSuite.new(
              account: @account,
              model: @evaluation_model
            ).call
          ]
        )
      end

      def combined_eval_collection(deterministic_evals, live_evals)
        suites = deterministic_evals.suites + Array(live_evals&.suites)
        Llm::Evals::CollectionResult.new(suites: suites, generated_at: @now)
      end

      def operational_check(release_gate, alerts)
        gate_status = release_gate[:status].to_s

        {
          name: 'operational_release_gate',
          status: gate_status,
          blocking: gate_status == 'fail',
          alert_status: alerts[:status],
          active_alert_count: alerts[:active_count],
          message: operational_message(gate_status)
        }.compact
      end

      def eval_check(name, result)
        {
          name: name,
          status: result.status,
          blocking: !result.passed?,
          total_count: result.total_count,
          passed_count: result.passed_count,
          failed_count: result.failed_count,
          error_count: result.error_count,
          message: (result.passed? ? nil : "#{name.to_s.humanize} failed")
        }.compact
      end

      def live_eval_check(result)
        return {
          name: 'live_evals',
          status: 'not_applicable',
          blocking: false,
          message: live_eval_skip_message
        } if result.nil?

        eval_check('live_evals', result)
      end

      def operational_message(status)
        case status
        when 'fail'
          'Operational release gate failed against recent llm_events.'
        when 'insufficient_data'
          'Operational release gate has insufficient recent data and is advisory only.'
        when 'disabled'
          'Operational release gate is disabled in runtime preferences.'
        when 'not_applicable'
          'Operational release gate was skipped because no account scope was provided.'
        else
          nil
        end
      end

      def events_query
        @events_query ||= Llm::Monitoring::EventsQuery.new(
          scope: @account.llm_events,
          params: @filters,
          date_range: @date_range
        )
      end

      def not_applicable_release_gate
        {
          status: 'not_applicable',
          evaluated_at: @now,
          checks: [],
          current_period: nil,
          baseline_period: nil
        }
      end

      def live_eval_skip_message
        return 'Live account-scoped evals were skipped because no account was provided.' unless @account

        'Live account-scoped evals were skipped by runner configuration.'
      end
    end
  end
end
