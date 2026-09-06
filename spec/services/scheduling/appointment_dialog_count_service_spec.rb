# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduling::AppointmentDialogCountService do
  [Conversation, CommunicationThread].each do |model|
    it "counts #{model.name} without materializing the visible relation" do
      account = create(:account)
      create(model.model_name.singular.to_sym, account: account)
      scope = model.where(account_id: account.id)
      options = { account: account }
      options["#{model.model_name.singular}_scope".to_sym] = scope
      service = described_class.new(**options)

      service.public_send("#{model.model_name.singular}_status_counts")

      expect(scope).not_to be_loaded
    end
  end
end
