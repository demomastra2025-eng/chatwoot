require 'rails_helper'

RSpec.describe Captain::Playground::SchedulingReadSnapshot do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user) }

  after { Current.reset }

  it 'captures broad candidates with one query per catalogue and keeps account scope' do
    resources = create_list(:scheduling_resource, 3, account: account)
    services = create_list(:scheduling_service, 3, account: account)
    foreign = create(:scheduling_resource)
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: false)
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| queries << payload[:sql] }
      snapshot = described_class.for_arguments(workspace, {})
      expect(snapshot.binding_for(resources.first.id, services.last.id)).to be_present
      expect(snapshot.binding_for(resources.last.id, services.first.id)).to be_present
      expect(snapshot.binding_for(foreign.id, nil)).to be_nil
      expect(queries.count { |sql| sql.include?('FROM "scheduling_resources"') }).to eq(1)
      expect(queries.count { |sql| sql.include?('FROM "scheduling_services"') }).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end

  it 'does not give an entity created during a broad read the identity of an earlier candidate' do
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: false)
      offers = Captain::Playground::SchedulingOffers.new(workspace)
      origin = offers.begin_read('search_booking_options', doctor: 'Synthetic')
      added = create(:scheduling_resource, account: account)
      starts_at = 1.day.from_now.change(hour: 10, min: 0, sec: 0)
      payload = { slots: [{ resource_id: added.id, starts_at: starts_at.iso8601, ends_at: (starts_at + 30.minutes).iso8601 }] }
      offers.record('search_booking_options', payload, {}, provenance: origin)
      expect(Array(workspace.data['catalog_slots'])).to be_empty
    end
  end

  it 'fails closed on a broad catalogue overflow but permits an explicitly bounded target' do
    resources = create_list(:scheduling_resource, 2, account: account)
    stub_const('Captain::Playground::SchedulingReadSnapshot::MAX_RESOURCES', 1)
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: false)
      expect(described_class.for_arguments(workspace, {}).valid?).to be(false)
      targeted = described_class.for_arguments(workspace, resource_id: resources.first.id)
      expect(targeted.valid?).to be(true)
      expect(targeted.binding_for(resources.first.id, nil)).to be_present
    end
  end
end
