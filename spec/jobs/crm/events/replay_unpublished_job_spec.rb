require 'rails_helper'

RSpec.describe Crm::Events::ReplayUnpublishedJob do
  let(:account) { create(:account) }

  before do
    allow(Crm::Events::PublishJob).to receive(:perform_later!)
  end

  it 'enqueues only unpublished events' do
    unpublished = create(:crm_event, account: account, published_at: nil)
    create(:crm_event, account: account, published_at: Time.current)
    expect(Crm::Events::PublishJob).to receive(:perform_later!).with(unpublished.id).once

    described_class.perform_now
  end
end
