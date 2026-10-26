# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::SearchedSlots do
  let(:cache_key) { Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY }
  let(:almaty) { 'Asia/Almaty' }

  # The compact answer of search_available_slots as the run caches it: a JSON text inside the message of the result.
  def search_result(days: [], next_available: nil)
    answer = { duration_min: 30, total: 5, days: days }
    answer[:next_available] = next_available if next_available
    { success: true, message: JSON.generate(answer) }
  end

  def day(resource_id, date, *times, more: 0)
    { resource_id: resource_id, name: 'Д-р Смит', date: date, times: times, more: more }
  end

  def context_with(*entries)
    { cache_key => entries.each_with_index.to_h { |(tool, result), index| ["digest-#{index}", { tool: tool, result: result }] } }
  end

  def returned?(context, resource_id: 217, at: '2026-10-31T14:30:00+05:00')
    described_class.new(context).returned?(resource_id: resource_id, starts_at: Time.iso8601(at), timezone: almaty)
  end

  it 'finds a start that a specialist-day of the search lists, for that specialist and that day only' do
    context = context_with(['search_available_slots', search_result(days: [day(217, '2026-10-31', '14:30', '15:00', '16:30')])])

    expect(returned?(context)).to be(true)
    expect(returned?(context, at: '2026-10-31T16:30:00+05:00')).to be(true)
    expect(returned?(context, at: '2026-10-31T14:20:00+05:00')).to be(false)
    expect(returned?(context, at: '2026-11-07T14:30:00+05:00')).to be(false)
    expect(returned?(context, resource_id: 218)).to be(false)
  end

  # Suggestion eval 26.10: the search listed 14:30 and later, and a card was prepared at 14:20.
  it 'does not find a start next to the listed ones: only the listed times were returned' do
    context = context_with(['search_available_slots', search_result(days: [day(217, '2026-10-31', '14:30', '15:00', '15:30', '16:00')])])

    expect(returned?(context, at: '2026-10-31T14:20:00+05:00')).to be(false)
    expect(returned?(context, at: '2026-10-31T14:45:00+05:00')).to be(false)
  end

  it 'reads the clock of the specialist: the same instant in another zone is the same listed time' do
    context = context_with(['search_available_slots', search_result(days: [day(217, '2026-10-31', '14:30')])])

    expect(returned?(context, at: '2026-10-31T09:30:00Z')).to be(true)
    expect(returned?(context, at: '2026-10-31T14:30:00Z')).to be(false)
  end

  it 'finds the start of an exact-time search and the starts of the nearest days after an empty range' do
    exact = context_with(['search_available_slots', search_result(days: [day(217, '2026-10-31', '14:20')])])
    empty = context_with(['search_available_slots', search_result(next_available: [day(217, '2026-11-02', '09:00', '10:30')])])

    expect(returned?(exact, at: '2026-10-31T14:20:00+05:00')).to be(true)
    expect(returned?(empty, at: '2026-11-02T10:30:00+05:00')).to be(true)
  end

  it 'opens a result that is a hash, a JSON text or a preview of the eval, and the slots that carry their own start' do
    hash_result = { success: true, message: { days: [day(217, '2026-10-31', '14:30')] } }
    preview = { success: true, message: { preview: JSON.generate(days: [day(217, '2026-10-31', '15:00')]) } }
    slots = { success: true, message: JSON.generate(slots: [{ resource_id: 217, starts_at: '2026-10-31T15:30:00+05:00' }]) }

    context = context_with(['search_available_slots', hash_result], ['search_available_slots', preview],
                           ['get_scheduling_resource_availability', slots])

    expect(returned?(context)).to be(true)
    expect(returned?(context, at: '2026-10-31T15:00:00+05:00')).to be(true)
    expect(returned?(context, at: '2026-10-31T15:30:00+05:00')).to be(true)
    expect(returned?(context, at: '2026-10-31T15:31:00+05:00')).to be(false)
  end

  it 'counts only the slot reads: the times of the schedule or of an appointment list are no free times' do
    schedule = { success: true, message: JSON.generate(days: [day(217, '2026-10-31', '14:30')]) }
    context = context_with(['get_scheduling_resource_schedule', schedule], ['list_my_appointments', schedule])

    expect(returned?(context)).to be(false)
    expect(described_class.new(context).searched?).to be(false)
  end

  it 'finds nothing in a run that read nothing, or whose answer cannot be read' do
    expect(returned?({})).to be(false)
    expect(returned?(context_with(['search_available_slots', 'ERROR: not json {']))).to be(false)
    expect(returned?(context_with(['search_available_slots', nil]))).to be(false)
    expect(described_class.new({}).searched?).to be(false)
  end
end
