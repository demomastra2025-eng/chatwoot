# frozen_string_literal: true

require 'rails_helper'

# The platform rules of the patient agent that came out of the suggestion eval of 27.10 (28 bad answers in 125 cases, 16 of them real,
# 13 of those curable without a change of model) and of the review of quality-fixes-1. The rules are the same for every business: they
# name no clinic, no doctor and no service, and the rules about an IIN are written only for the accounts that identify patients by it
# (their contact attributes hold an IIN). What each rule says is pinned here, for the prompt of a reply suggestion and for the live one.
RSpec.describe Captain::Assistant, '#agent_instructions' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:clock) do
    { now_utc: '2026-10-12T08:00:00Z', now_local: '2026-10-12T13:00:00+05:00', timezone: 'Asia/Almaty' }
  end

  def run_context(source, runtime_clock = clock)
    state = { source: source, runtime_clock: runtime_clock }.compact
    instance_double(Captain::Runtime::RunContext, context: { state: state })
  end

  def council_part
    instance_double(Captain::Runtime::RunContext,
                    context: { part_run: true, state: { source: 'reply_suggestion', runtime_clock: clock } })
  end

  # The platform rules of the agent (the first block of its instructions).
  def suggestion_rules
    assistant.agent_instructions(run_context('reply_suggestion')).split("\n\n").first
  end

  def live_rules
    assistant.agent_instructions(run_context(nil)).split("\n\n").first
  end

  def part_rules
    assistant.agent_instructions(council_part).split("\n\n").first
  end

  # The account identifies its patients by an IIN: a contact attribute holds it.
  def give_patients_an_iin
    create(:custom_attribute_definition, account: account, attribute_key: 'iin', attribute_model: :contact_attribute)
  end

  describe 'a cancellation or a move of a visit' do
    let(:list_rule) do
      'list_my_appointments shows the appointments booked from this chat: the patient\'s own and those of a child or a relative booked ' \
        'here (the card of another patient names that patient and carries its token). To change or cancel the appointment of another ' \
        'patient, take its token from list_my_appointments or search_appointments'
    end
    let(:never_rule) do
      'Say that an appointment is cancelled or moved only from a tool result (the rule above), and never that there is no appointment, ' \
        'that nothing is booked or that there is nothing to cancel: a lookup covers the visits booked from this chat only. When the ' \
        'patient asks to cancel or move a visit and your lookups did not find it (an empty list or not_found), '
    end
    let(:refused_rule) do
      'When the visit was found but the tool refused the change (for example because the appointment belongs to the clinic system and ' \
        'cannot be changed from here), do not ask for anything more: hand the request to staff the same way, naming that visit (date, ' \
        'time, specialist) and that the change was refused.'
    end
    let(:to_staff) do
      'hand the request to staff: do not draft a reply, set response_mode to human, leave response empty and write in operator_note ' \
        'which visit the patient meant and that the booking was not found.'
    end

    it 'gives the appointments booked from this chat, with the token of another patient\'s, and says what to do when the visit is not found' do
      expect(suggestion_rules).to include(list_rule, never_rule + to_staff, refused_rule)
      expect(suggestion_rules).not_to include('linked to this contact', 'linked patients')
    end

    # Review of quality-fixes-1 (M5): asking for an IIN is a rule of the accounts that identify patients by it; the others hand the visit over.
    it 'asks for the IIN of the patient and searches with it before handing the visit over only where the account has patients with an IIN' do
      expect(suggestion_rules).not_to include('IIN')
      expect(live_rules).not_to include('IIN')

      give_patients_an_iin

      expect(suggestion_rules).to include(
        "#{list_rule} (without an IIN it lists the same appointments; with an IIN it finds one that is not shown).",
        "#{never_rule}first ask for the patient's IIN and search with search_appointments; when that finds nothing or the patient has " \
        "not given it, #{to_staff}"
      )
      expect(live_rules).to include('first ask for the patient\'s IIN and search with search_appointments; when that finds nothing or ' \
                                    'the patient has not given it, hand the request to staff by the handoff rule below.')
    end

    # Review of quality-fixes-1 (M3): a visit that was found and refused is not a visit to look up again.
    it 'sends a visit that the tool refused to staff, naming that visit, without a look-up for it first' do
      give_patients_an_iin

      expect(suggestion_rules).to include(refused_rule)
      expect(live_rules).to include('When the visit was found but the tool refused the change (for example because the appointment ' \
                                    'belongs to the clinic system and cannot be changed from here), do not ask for anything more: hand ' \
                                    'the request to staff by the handoff rule below, naming that visit and that the change was refused.')
    end

    it 'sends a part of a council to staff by the rules of its part, not by response_mode' do
      expect(part_rules).to include(never_rule + 'hand the request to staff: end your part as the rules of your part below say, naming ' \
                                                 'which visit the patient meant and that the booking was not found.')
      expect(part_rules).not_to include('response_mode', 'operator_note')
    end

    it 'never lets a live agent tell the patient that there is nothing to cancel, and hands the request over by the handoff rule' do
      expect(live_rules).to include(
        'list_my_appointments shows the appointments booked from this chat',
        'Never tell the patient that there is no appointment, that nothing is booked or that there is nothing to cancel',
        'your lookups did not find it (an empty list or not_found), hand the request to staff by the handoff rule below.'
      )
    end

    it 'says that staff will check when the live agent cannot hand over' do
      allow(assistant).to receive(:selected_agent_tool_ids).and_return(%w[faq_lookup])

      expect(live_rules).to include('say that you could not find the booking and that staff will check it.')
      expect(live_rules).to include('say that staff will make the change.')
      expect(live_rules).not_to include('handoff rule below')
    end
  end

  # Suggestion eval 27.10 (c76-1205215, c78-1186457, c77-1198258): after an agreed time (the voice notes of the operator had no text)
  # the patient wrote «Принял / Буду» and the agent booked the same time again, asked for the data again or greeted. Review of
  # quality-fixes-1 (M1): a silence is safe only after a visit that exists; an unknown voice note is answered by staff.
  describe 'a bare confirmation after an agreed time and the voice notes of staff' do
    let(:voice_note) { Captain::ReplySuggestion::HistoryBuilder::STAFF_VOICE_NOTE }

    it 'tells a suggestion to stay silent for a thanks, ok or confirmation of a visit that exists, and to leave a voice note to staff' do
      expect(suggestion_rules).to include(
        "- A voice note of staff in the history shows its transcript as text, or the line \"#{voice_note}\" when it has none.",
        'never offer or book again what it may have settled.',
        'When the patient\'s message follows a voice note without a transcript (a thanks, an ok, a yes, a confirmation), leave the reply ' \
        'to staff: response_mode human, operator_note naming the voice note; never suppress it.',
        'A thanks, ok or confirmation that the patient will come ("спасибо, буду", "хорошо, придём", "рахмет, келемін") after a time or a ' \
        'visit that the history shows in a message or a transcript as agreed, booked, confirmed or reminded, while the patient has an ' \
        'upcoming appointment or a booking that waits for approval, needs no reply: set response_mode to suppress; never answer it with a ' \
        'greeting alone, a new booking or a question for data already given.',
        'A yes or ok to a time that staff offered, which is not the time of an appointment the patient has, accepts it: book that time.'
      )
    end

    it 'names the exact line the history builder writes for a voice note without a transcript, in neutral words' do
      expect(suggestion_rules).to include(voice_note)
      expect(voice_note).to eq('[Voice note of a staff member; its words are not available to you]')
      expect(voice_note).not_to include('clinic')
    end

    it 'keeps the voice note rule out of the live prompt and the council parts, and widens the no-action rule of the live prompt' do
      expect(live_rules).not_to include('Voice note of a staff member')
      expect(part_rules).not_to include('Voice note of a staff member')
      expect(live_rules).to include('(after prices or information, a reminder, a time already agreed, or a visit already booked), also ' \
                                    'one that says the patient will come ("спасибо, буду", "рахмет, келемін"), asks for no action')
    end
  end

  # Suggestion eval 27.10 (c43-1214353, c78-1250261): a request for the personal number of a doctor was handed to staff although the
  # rules of the clinic answer it (no personal numbers, contacts through the registry), and a plain question about a booking was sent
  # to staff by the router.
  describe 'a request that a rule of the clinic covers' do
    it 'gives a rule that refuses the request as the answer, and hands over only when no source covers it or a person is asked for' do
      expect(suggestion_rules).to include(
        '- A rule of the clinic instructions that covers the request is an answer, also a rule that refuses it (the personal number of a ' \
        'staff member is not given, a service is not provided): give that answer with what the clinic offers instead, and do not hand ' \
        'the request to staff. Hand over only when no source covers the request, or when the patient asks for a person, complains, asks ' \
        'for a refund or raises a legal matter.'
      )
      expect(live_rules).to include(
        '- A rule of the clinic instructions that covers the request is an answer, also a rule that refuses it (the personal number of a ' \
        'staff member is not given, a service is not provided): give that answer with what the clinic offers instead of handing the ' \
        'request over.'
      )
    end
  end

  # Suggestion eval 27.10 (c74-1245386): a payment phone number the patient sent was read as the ID number, and a card was raised to
  # write it into the card of the patient. Review of quality-fixes-1 (M5): the rule is written for the accounts that have patients with
  # an IIN (a contact attribute "iin"), not for every business.
  describe 'the IIN' do
    let(:iin_rule) do
      '- An IIN is 12 digits. Never take another number the patient sent (a phone number, a payment or card number) for the IIN, and ' \
        'never write one to a card; when the IIN is needed and not known, ask for it.'
    end

    it 'is 12 digits and never another number the patient sent, in a suggestion, in a live run and in a council part' do
      give_patients_an_iin

      expect(suggestion_rules).to include(iin_rule)
      expect(live_rules).to include(iin_rule)
      expect(part_rules).to include(iin_rule)
    end

    it 'is not written for an account whose contacts have no IIN attribute' do
      expect(suggestion_rules).not_to include(iin_rule)
      expect(live_rules).not_to include(iin_rule)
      expect(part_rules).not_to include(iin_rule)
    end
  end

  # Suggestion eval 27.10 (c43-1233247, c76-1195118, c74-1233747): a draft said it could not check a time it had not searched, one asked
  # the patient for the doctor when a search of the time names the doctors who have it, one gave the times of a gynecologist under the
  # name of the other.
  describe 'a time alone and the name under which a time is given' do
    let(:time_rule) do
      '- A time alone (a time the patient named, or "which doctor has 11:40?") is a question about free times: search that exact time ' \
        '(from = to) across the specialists of the specialty or service, all of them when none is named, and answer with those who have ' \
        'it free; never ask the patient to name the specialist while a search can tell, and never say that you cannot check a time ' \
        'before you searched it. Write each time under the name of the specialist whose search result lists it, and never give the ' \
        'times of one specialist under the name of another.'
    end

    it 'searches a time alone across the specialists and gives each time under the specialist whose result lists it, in both prompts' do
      expect(suggestion_rules).to include(time_rule)
      expect(live_rules).to include(time_rule)
    end

    it 'gives a council part the same rule' do
      expect(part_rules).to include(time_rule)
    end
  end

  # Suggestion eval 27.10 (c77-1167712, c78-1194483, c74-1245884): "tomorrow 09:00" written the day before was offered for the wrong
  # day because the model counted from the clock; a search for earlier or later times started from tomorrow and skipped today's.
  describe 'the days a patient names and where a search of free times starts' do
    let(:day_rule) do
      'the patient\'s last message has no stamp, its day is written under Now when it was sent before today. Read today, tomorrow, the ' \
        'day after tomorrow and weekdays in every patient message from the day that message was sent, never from Now (under Now they ' \
        'are written out for the last message); if the day the patient meant has passed, say so and offer the nearest free times with ' \
        'full dates.'
    end
    # Review of quality-fixes-1 (M6): later only on a day the patient named; a notice before a visit comes from the clinic instructions.
    let(:search_rule) do
      '- Search free times from today: when the patient names no day, or asks for the nearest, an earlier or a later time, start the ' \
        'search today (from = today\'s date; the free times of today that are later than Now are offered too) and offer a later day ' \
        'only when today has none; start the search later than today only on a day the patient named. A minimum notice before a visit ' \
        'or a ban on same-day booking comes from the clinic instructions, never from you.'
    end

    it 'reads the days of every patient message from the day it was sent, and starts a search today, in a suggestion and in a live run' do
      [suggestion_rules, live_rules].each do |rules|
        expect(rules).to include(day_rule, search_rule)
        expect(rules).not_to include('not from Now;', 'never start the search from tomorrow')
      end
    end

    it 'shows the day of the last message of the patient under Now with its relative days written out when it was sent before today' do
      monday_clock = { now_utc: '2026-10-26T04:00:00Z', now_local: '2026-10-26T09:00:00+05:00', timezone: 'Asia/Almaty',
                       message_sent_at: '2026-10-24T04:50:00Z' }

      rendered = assistant.agent_instructions(run_context('reply_suggestion', monday_clock))

      expect(rendered).to include('Monday, 26 October 2026 (2026-10-26), 09:00, Almaty (UTC+5). Tomorrow: Tuesday, 27 October 2026',
                                  "Patient's last message was sent Saturday, 24 October 2026 (2026-10-24), 09:50 (2 days ago).",
                                  'tomorrow (завтра, ертең) = Sunday, 25 October 2026 (2026-10-25)')
    end
  end
end
