# frozen_string_literal: true

require 'rails_helper'

# The platform rules of the patient agent that came out of the suggestion eval of 27.10 (28 bad answers in 125 cases, 16 of them real,
# 13 of those curable without a change of model). The rules are the same for every business: they name no clinic, no doctor and no
# service. What each rule says is pinned here, for the prompt of a reply suggestion and for the live one.
RSpec.describe Captain::Assistant, '#agent_instructions' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:clock) do
    { now_utc: '2026-10-12T08:00:00Z', now_local: '2026-10-12T13:00:00+05:00', timezone: 'Asia/Almaty' }
  end

  def run_context(source)
    state = { source: source, runtime_clock: clock }.compact
    instance_double(Captain::Runtime::RunContext, context: { state: state })
  end

  # The platform rules of the agent (the first block of its instructions).
  def suggestion_rules
    assistant.agent_instructions(run_context('reply_suggestion')).split("\n\n").first
  end

  def live_rules
    assistant.agent_instructions(run_context(nil)).split("\n\n").first
  end

  describe 'a cancellation or a move of a visit' do
    it 'covers the linked patients in the lookups and says what to do when the visit is not found, in a suggestion' do
      expect(suggestion_rules).to include(
        'list_my_appointments shows the appointments of the patient and of the patients linked to this contact (a child, a relative; ' \
        'the card of another patient names that patient). To change or cancel the appointment of another patient, take its token from ' \
        'search_appointments (without an IIN it lists the same appointments; with an IIN it finds one that is not shown).',
        'Say that an appointment is cancelled or moved only from a tool result (the rule above), and never that there is no appointment, ' \
        'that nothing is booked or that there is nothing to cancel',
        'a lookup covers this contact and its linked patients only',
        'first ask for the patient\'s IIN and search with search_appointments',
        'hand the request to staff: do not draft a reply, set response_mode to human, leave response empty and write in operator_note ' \
        'which visit the patient meant and that the booking was not found.'
      )
    end

    it 'sends a part of a council to staff by the rules of its part, not by response_mode' do
      part = instance_double(Captain::Runtime::RunContext, context: { part_run: true, state: { source: 'reply_suggestion', runtime_clock: clock } })

      rules = assistant.agent_instructions(part).split("\n\n").first

      expect(rules).to include('hand the request to staff: end your part as the rules of your part below say, naming which visit the ' \
                               'patient meant and that the booking was not found.')
      expect(rules).not_to include('response_mode', 'operator_note')
    end

    it 'never lets a live agent tell the patient that there is nothing to cancel, and hands the request over by the handoff rule' do
      expect(live_rules).to include(
        'list_my_appointments shows the appointments of the patient and of the patients linked to this contact',
        'Never tell the patient that there is no appointment, that nothing is booked or that there is nothing to cancel',
        'first ask for the patient\'s IIN and search with search_appointments; when that finds nothing or the patient has not given it, ' \
        'hand the request to staff by the handoff rule below.'
      )
    end

    it 'says that staff will check when the live agent cannot hand over' do
      allow(assistant).to receive(:selected_agent_tool_ids).and_return(%w[faq_lookup])

      expect(live_rules).to include('say that you could not find the booking and that staff will check it.')
      expect(live_rules).not_to include('handoff rule below')
    end
  end
end
