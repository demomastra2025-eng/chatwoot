# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PromptSummaryText do
  # An item of a summary as ContextSummary builds it: the card of the appointment plus its title and UTC times.
  def appointment(id:, **attributes)
    item = { status: 'scheduled', date: '15.10.2026', time: '10:30', doctor: 'Иванов Алексей Петрович', service: 'Приём терапевта (первичный)' }
           .merge(attributes)
    item.merge(id: id, title: [item[:service], item[:doctor]].compact.join(' — '),
               starts_at: '2026-10-15T05:30:00Z', ends_at: '2026-10-15T06:00:00Z')
  end

  def appointments_summary(upcoming: [], past: [], cancelled: [], totals: {})
    groups = { 'upcoming' => upcoming, 'past' => past, 'cancelled' => cancelled }.map do |key, items|
      { key: key, total: totals.fetch(key, items.size), shown: items.size, display: 'Показано', limit: 6, sort: ['starts_at ASC'], items: items }
    end
    { version: 1, kind: 'appointments', counts: {}, groups: groups, shown: 1, total: 1, display: 'Показано 1 из 1',
      scope: { kind: 'current_contact', contact_id: 77 }, selection: {}, sort: {},
      details_tool: 'get_appointment', search_tool: 'list_my_appointments' }
  end

  def deal(id:, **attributes)
    { id: id, title: 'Имплантация', pipeline_id: 4, pipeline: 'Продажи', stage_id: 9, stage: 'Консультация', outcome: 'open',
      amount: '150000', currency: 'KZT', updated_at: '2026-10-10T08:00:00Z' }.merge(attributes)
  end

  def deals_summary(active: [], history: [], totals: {})
    groups = { 'active' => active, 'history' => history }.map do |key, items|
      { key: key, total: totals.fetch(key, items.size), shown: items.size, items: items }
    end
    { version: 1, kind: 'deals', groups: groups, details_tool: 'get_deal', search_tool: 'search_deals' }
  end

  def render(summary, **)
    described_class.render(summary, **)
  end

  describe 'appointments' do
    it 'writes one upcoming appointment with the weekday, the date, the time, the service in quotes and the doctor' do
      summary = appointments_summary(upcoming: [appointment(id: 5)])

      expect(render(summary)).to eq(
        'upcoming: Thu 15.10.2026 10:30, «Приём терапевта (первичный)», Иванов Алексей Петрович; no past or cancelled appointments'
      )
    end

    it 'writes several appointments in every group and names none of the empty ones' do
      summary = appointments_summary(
        upcoming: [appointment(id: 5), appointment(id: 6, date: '19.10.2026', time: '09:00', service: 'УЗИ', doctor: 'Петров Б.')],
        past: [appointment(id: 3, date: '01.10.2026', time: '15:00', status: 'completed')],
        cancelled: [appointment(id: 2, date: '02.10.2026', time: '11:00', status: 'cancelled', service: nil)]
      )

      expect(render(summary)).to eq(
        'upcoming: Thu 15.10.2026 10:30, «Приём терапевта (первичный)», Иванов Алексей Петрович; ' \
        'Mon 19.10.2026 09:00, «УЗИ», Петров Б.; ' \
        'past: Thu 01.10.2026 15:00, «Приём терапевта (первичный)», Иванов Алексей Петрович; ' \
        'cancelled: Fri 02.10.2026 11:00, Иванов Алексей Петрович'
      )
    end

    it 'adds how many more exist when a group is cut' do
      summary = appointments_summary(
        upcoming: [appointment(id: 5)], past: [appointment(id: 3, status: 'completed')], totals: { 'upcoming' => 9, 'past' => 4 }
      )

      expect(render(summary)).to include('upcoming: Thu 15.10.2026 10:30', '(and 8 more); past:')
      expect(render(summary)).to end_with('(and 3 more); no cancelled appointments')
    end

    it 'says there are no upcoming appointments so the model does not invent one' do
      summary = appointments_summary(past: [appointment(id: 3, status: 'completed')])

      expect(render(summary)).to end_with('; no upcoming or cancelled appointments')
      expect(render(summary)).to start_with('past: Thu 15.10.2026 10:30')
    end

    it 'says there are no appointments at all' do
      expect(render(appointments_summary)).to eq('no appointments')
    end

    it 'writes an English status word only when it is not the usual status of the group' do
      summary = appointments_summary(
        upcoming: [appointment(id: 5, status: 'confirmed')],
        past: [appointment(id: 3, status: 'no_show'), appointment(id: 4, status: 'completed')]
      )

      text = render(summary)

      expect(text).to include('upcoming: Thu 15.10.2026 10:30, «Приём терапевта (первичный)», Иванов Алексей Петрович; past:')
      expect(text).to include('Иванов Алексей Петрович (no-show); Thu 15.10.2026 10:30, «Приём терапевта (первичный)», Иванов Алексей Петрович;')
      expect(text).not_to include('completed', 'scheduled')
    end

    it 'writes a move the provider has not confirmed as a request, never as the visit time' do
      reschedule = { state: 'needs_reconciliation', requested_time_confirmed: false, requested_date: '14.10.2026', requested_time: '10:30' }
      summary = appointments_summary(upcoming: [appointment(id: 5, reschedule: reschedule)])

      expect(render(summary)).to include('Иванов Алексей Петрович (move to 14.10.2026 10:30 requested, not confirmed);')
    end

    it 'writes the number of the appointment only when a bound tool takes it' do
      summary = appointments_summary(upcoming: [appointment(id: 5)])

      expect(render(summary, bound_tool_ids: %w[get_appointment])).to start_with('upcoming: #5 Thu 15.10.2026 10:30,')
      expect(render(summary, bound_tool_ids: %w[cancel_appointment faq_lookup])).to start_with('upcoming: #5 Thu')
      expect(render(summary, bound_tool_ids: %w[list_my_appointments create_appointment])).to start_with('upcoming: Thu 15.10.2026')
      expect(render(summary, bound_tool_ids: [])).to start_with('upcoming: Thu 15.10.2026')
      expect(render(summary)).to start_with('upcoming: Thu 15.10.2026')
    end

    it 'keeps going without a doctor, a service or a weekday' do
      summary = appointments_summary(
        upcoming: [appointment(id: 5, doctor: nil, service: nil), appointment(id: 6, date: 'soon', time: nil, doctor: 'Петров', service: nil)]
      )

      expect(render(summary)).to start_with('upcoming: Thu 15.10.2026 10:30; soon, Петров;')
    end

    it 'never writes the internal parts of the summary: ISO times, ids of the contact, sorting, limits or the tool names' do
      text = render(appointments_summary(upcoming: [appointment(id: 5)]), bound_tool_ids: [])

      expect(text).not_to include('2026-10-15', 'Z', '77', 'starts_at', 'limit', 'sort', 'get_appointment', 'list_my_appointments', 'Показано')
    end

    it 'reads string keys as well, as after a JSON round trip, and leaves the summary unchanged' do
      summary = JSON.parse(JSON.generate(appointments_summary(upcoming: [appointment(id: 5)])))
      before = summary.deep_dup

      expect(render(summary)).to start_with('upcoming: Thu 15.10.2026 10:30')
      expect(summary).to eq(before)
    end
  end

  describe 'deals' do
    it 'writes open deals with the title, the stage and the amount, and the closed ones with the outcome and the day' do
      summary = deals_summary(
        active: [deal(id: 501)],
        history: [
          deal(id: 430, title: 'Протезирование', stage: 'Выиграна', outcome: 'won', closed_at: '2026-09-03T08:00:00Z',
               history_at: '2026-09-03T08:00:00Z', history_at_source: 'closed_at', amount: '90000')
        ]
      )

      expect(render(summary)).to eq('open: «Имплантация», stage «Консультация», 150000 KZT; closed: «Протезирование», won 03.09.2026, 90000 KZT')
    end

    it 'writes the closing day in the zone of the run, not in UTC' do
      summary = deals_summary(history: [deal(id: 430, outcome: 'won', history_at: '2026-09-03T21:00:00Z', history_at_source: 'closed_at')])

      expect(render(summary, time_zone: 'Asia/Almaty')).to include('won 04.09.2026')
      expect(render(summary, time_zone: 'Europe/Moscow')).to include('won 04.09.2026')
      expect(render(summary, time_zone: 'America/New_York')).to include('won 03.09.2026')
    end

    it 'writes lost, archived and plainly closed deals and leaves the day out when only a creation date is known' do
      summary = deals_summary(
        history: [
          deal(id: 1, title: 'A', outcome: 'lost', history_at: '2026-09-01T08:00:00Z', history_at_source: 'closed_at'),
          deal(id: 2, title: 'B', outcome: 'open', archived_at: '2026-09-02T08:00:00Z',
               history_at: '2026-09-02T08:00:00Z', history_at_source: 'archived_at'),
          deal(id: 3, title: 'C', outcome: 'open', closed_at: '2026-09-02T08:00:00Z',
               history_at: '2026-09-02T08:00:00Z', history_at_source: 'closed_at'),
          deal(id: 4, title: 'D', outcome: 'won', history_at: '2026-01-01T08:00:00Z', history_at_source: 'created_at_fallback_event_time_unknown')
        ]
      )

      expect(render(summary, time_zone: 'Asia/Almaty')).to eq(
        'closed: «A», lost 01.09.2026, 150000 KZT; «B», archived 02.09.2026, 150000 KZT; ' \
        '«C», closed 02.09.2026, 150000 KZT; «D», won, 150000 KZT; no open deals'
      )
    end

    it 'names the pipeline only when the deals belong to several pipelines' do
      one = deals_summary(active: [deal(id: 1), deal(id: 2, title: 'Чистка')])
      two = deals_summary(active: [deal(id: 1), deal(id: 2, title: 'Чистка', pipeline: 'Поддержка')])

      expect(render(one)).not_to include('pipeline')
      expect(render(two)).to include('«Имплантация», stage «Консультация», pipeline «Продажи», 150000 KZT')
      expect(render(two)).to include('«Чистка», stage «Консультация», pipeline «Поддержка», 150000 KZT')
    end

    it 'adds how many more exist and says when there are no deals' do
      summary = deals_summary(active: [deal(id: 1)], totals: { 'active' => 5 })

      expect(render(summary)).to eq('open: «Имплантация», stage «Консультация», 150000 KZT (and 4 more); no closed deals')
      expect(render(deals_summary)).to eq('no deals')
    end

    it 'leaves out an amount that is missing' do
      summary = deals_summary(active: [deal(id: 1, amount: nil, currency: nil)])

      expect(render(summary)).to eq('open: «Имплантация», stage «Консультация»; no closed deals')
    end

    it 'writes the number of the deal only when a bound tool takes it as a main parameter' do
      summary = deals_summary(active: [deal(id: 501)])

      expect(render(summary, bound_tool_ids: %w[get_deal])).to start_with('open: #501 «Имплантация»')
      expect(render(summary, bound_tool_ids: %w[transition_deal_stage])).to start_with('open: #501 «Имплантация»')
      expect(render(summary, bound_tool_ids: %w[create_task create_appointment search_deals])).to start_with('open: «Имплантация»')
      expect(render(summary)).to start_with('open: «Имплантация»')
    end
  end

  describe 'client deals' do
    def client_deals(open: [], won: [], lost: [], totals: {})
      groups = { 'open' => open, 'won' => won, 'lost' => lost }.map do |status, deals|
        { status: status, total: totals.fetch(status, deals.size), deals: deals.map { |card| card.merge(status: status) } }
      end
      { contact_id: 77, counts: groups.to_h { |group| [group[:status], group[:total]] }, groups: groups }
    end

    it 'writes the open, won and lost groups and names the empty one' do
      summary = client_deals(
        open: [deal(id: 1)],
        won: [deal(id: 2, title: 'Протезирование', outcome: 'won', history_at: '2026-09-03T08:00:00Z', history_at_source: 'closed_at')],
        totals: { 'won' => 5 }
      )

      expect(render(summary, time_zone: 'Asia/Almaty')).to eq(
        'open: «Имплантация», stage «Консультация», 150000 KZT; won: «Протезирование», 03.09.2026, 150000 KZT (and 4 more); no lost deals'
      )
    end

    it 'says there are no deals and writes numbers by the same rule' do
      expect(render(client_deals)).to eq('no deals')
      expect(render(client_deals(open: [deal(id: 1)]), bound_tool_ids: %w[get_deal])).to start_with('open: #1 «Имплантация»')
    end
  end

  describe 'a value that is not a summary' do
    it 'renders nothing for an unknown shape, a non-hash and nil' do
      expect(render({ unknown: 'shape' })).to be_nil
      expect(render({ kind: 'other', groups: [{ key: 'x' }] })).to be_nil
      expect(render('text')).to be_nil
      expect(render(nil)).to be_nil
    end
  end

  describe 'values that come from data' do
    it 'keeps each value on one line' do
      summary = appointments_summary(upcoming: [appointment(id: 5, doctor: "Иванов\n# Врач", service: "Приём\r\n  первичный")])

      expect(render(summary)).to include('«Приём первичный», Иванов # Врач')
    end
  end
end
