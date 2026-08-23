require 'rails_helper'

RSpec.describe Integrations::Medelement::OutboundChangeJob do
  include ActiveJob::TestHelper

  it 'retries an outbound change when another command owns the entity' do
    service = instance_double(Integrations::Medelement::OutboundChangeService)
    allow(Integrations::Medelement::OutboundChangeService).to receive(:new).and_return(service)
    allow(service).to receive(:perform).and_raise(
      Scheduling::Error.new(
        code: 'MEDELEMENT_COMMAND_IN_PROGRESS',
        message: 'busy',
        status: :conflict
      )
    )

    expect do
      described_class.perform_now(
        entity_type: 'contact',
        entity_id: 1,
        event_name: 'contact_updated',
        change: { changed_attributes: { 'name' => %w[Before After] } }
      )
    end.to have_enqueued_job(described_class).with(
      entity_type: 'contact',
      entity_id: 1,
      event_name: 'contact_updated',
      change: { changed_attributes: { 'name' => %w[Before After] } }
    )
  end
end
