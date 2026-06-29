require 'rails_helper'

RSpec.describe LeadSubmission do
  it 'inherits account, inbox, and source from lead form' do
    form = create(:lead_form)
    submission = build(:lead_submission, lead_form: form, account: nil, inbox: nil, source_kind: nil)

    expect(submission).to be_valid
    expect(submission.account).to eq(form.account)
    expect(submission.inbox).to eq(form.inbox)
    expect(submission.source_kind).to eq(form.source_kind)
  end
end
