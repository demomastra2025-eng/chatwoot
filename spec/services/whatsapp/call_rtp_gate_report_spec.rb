require 'rails_helper'

RSpec.describe Whatsapp::CallRtpGateReport do
  describe '#call' do
    it 'flags inbound and early outbound calls when Meta to agent RTP never flows' do
      calls = [
        {
          id: 51,
          direction: 'incoming',
          status: 'completed',
          media_session_id: 'sess_inbound',
          duration_seconds: 3,
          recording_file_size_bytes: 96
        },
        {
          id: 52,
          direction: 'outgoing',
          status: 'no_answer',
          media_session_id: 'sess_early_outbound',
          duration_seconds: nil,
          recording_file_size_bytes: 96
        },
        {
          id: 53,
          direction: 'outgoing',
          status: 'completed',
          media_session_id: 'sess_late_bidirectional',
          duration_seconds: 4,
          recording_file_size_bytes: 9_918
        }
      ]

      log_lines = [
        '{"time":"2026-05-19T11:38:22.664913987Z","msg":"bridge: stopped","session_id":"sess_inbound","meta_to_agent_packets":0,"meta_to_agent_payload_bytes":0,"agent_to_meta_packets":170,"agent_to_meta_payload_bytes":5946}',
        '{"time":"2026-05-19T11:38:56.844980592Z","msg":"bridge: stopped","session_id":"sess_early_outbound","meta_to_agent_packets":0,"meta_to_agent_payload_bytes":0,"agent_to_meta_packets":868,"agent_to_meta_payload_bytes":33928}',
        '{"time":"2026-05-19T11:39:22.722542044Z","msg":"bridge: Meta audio RTP flowing to agents","session_id":"sess_late_bidirectional","packets":1,"payload_bytes":8}',
        '{"time":"2026-05-19T11:39:28.696863225Z","msg":"bridge: stopped","session_id":"sess_late_bidirectional","meta_to_agent_packets":239,"meta_to_agent_payload_bytes":3130,"agent_to_meta_packets":752,"agent_to_meta_payload_bytes":27082}'
      ]

      report = described_class.new(calls: calls, log_lines: log_lines).call

      inbound = report.fetch(:sessions).fetch('sess_inbound')
      expect(inbound).to include(
        live_pass: false,
        direction: 'incoming',
        failure_stage: 'meta_to_agent_rtp_missing'
      )
      expect(inbound.fetch(:issues)).to include('meta_to_agent_rtp_missing', 'header_only_recording')

      early_outbound = report.fetch(:sessions).fetch('sess_early_outbound')
      expect(early_outbound).to include(
        live_pass: false,
        direction: 'outgoing',
        failure_stage: 'meta_to_agent_rtp_missing'
      )
      expect(early_outbound.fetch(:issues)).to include('meta_to_agent_rtp_missing', 'header_only_recording')

      late_bidirectional = report.fetch(:sessions).fetch('sess_late_bidirectional')
      expect(late_bidirectional).to include(
        live_pass: true,
        direction: 'outgoing',
        failure_stage: nil
      )
      expect(late_bidirectional.fetch(:issues)).to be_empty

      expect(report.fetch(:summary)).to include(
        total: 3,
        live_pass: 1,
        failed: 2,
        meta_to_agent_rtp_missing: 2,
        header_only_recording: 2
      )
    end
  end
end
