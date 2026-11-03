require 'rails_helper'

RSpec.describe Captain::Playground::SchedulingOffers do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user) }

  after { Current.reset }

  it 'preserves both concurrent read results committed through an actual session and its council view' do
    resource_ids = create_list(:scheduling_resource, 2, account: account).map(&:id)
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      view = workspace.acting_as(assistant.id)
      [workspace, view].each do |owner|
        allow(owner).to receive_messages(read_enabled?: true, permissions: { 'read' => true, 'generation' => 1 })
      end
      provenance = Captain::Playground::SchedulingReadSnapshot.for_arguments(workspace, resource_ids: resource_ids)
      offers = [described_class.new(workspace), described_class.new(view)]
      offers.each { |offer| allow(offer).to receive(:current_snapshot).and_return(provenance) }
      first_paused, release_first = pause_first_catalog_read(workspace.data)
      first = Thread.new { record(offers.first, resource_ids.first, provenance) }
      Timeout.timeout(5) { first_paused.pop }
      second = Thread.new { record(offers.last, resource_ids.last, provenance) }
      # With the monitor the second reader sleeps at commit; without it the
      # second commit completes, then the paused first commit loses its result.
      Timeout.timeout(5) { Thread.pass while second.alive? && second.status != 'sleep' }
      release_first << true
      Timeout.timeout(5) { [first, second].each(&:value) }
      expect(workspace.data.fetch('catalog_slots').pluck('resource_id')).to match_array(resource_ids)
      workspace.save!
    ensure
      release_first << true if release_first
      [first, second].compact.each(&:kill)
    end
  end

  def pause_first_catalog_read(data)
    first_paused = Queue.new
    release_first = Queue.new
    original_read = data.method(:[])
    read_once = false
    allow(data).to receive(:[]).and_call_original
    allow(data).to receive(:[]).with('catalog_slots') do
      value = original_read.call('catalog_slots')
      unless read_once
        read_once = true
        first_paused << true
        release_first.pop
      end
      value
    end
    [first_paused, release_first]
  end

  def record(offers, resource_id, provenance)
    starts_at = 1.day.from_now.change(hour: 10, min: 0, sec: 0)
    payload = { slots: [{ resource_id: resource_id, starts_at: starts_at.iso8601,
                          ends_at: (starts_at + 30.minutes).iso8601, status: 'available' }] }
    offers.record('search_available_slots', payload, {}, provenance: provenance)
  end
end
