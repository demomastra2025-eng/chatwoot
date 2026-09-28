require 'rails_helper'
require 'timeout'

RSpec.describe 'Contact owner and phone concurrency', type: :request do
  self.use_transactional_tests = false

  it 'takes the phone advisory before the Contact row for an owner+phone PATCH racing a merge' do
    account = create(:account)
    admin = create(:user, account: account, role: :administrator)
    owner = create(:user, account: account)
    contact = create(:contact, account: account)
    mergee = create(:contact, account: account)
    headers = admin.create_new_auth_token
    merge_held = Queue.new
    release_merge = Queue.new
    patch_pid = Queue.new
    merge = ContactMergeAction.new(account: account, base_contact: Contact.find(contact.id), mergee_contact: Contact.find(mergee.id))
    merge.define_singleton_method(:lock_contacts) do
      merge_held << true
      release_merge.pop
      super()
    end

    merge_writer = Thread.new { ActiveRecord::Base.connection_pool.with_connection { merge.perform } }
    Timeout.timeout(8) { merge_held.pop }
    patch_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        patch_pid << connection.select_value('SELECT pg_backend_pid()')
        patch "/api/v1/accounts/#{account.id}/contacts/#{contact.id}",
              params: { owner_id: owner.id, phone_number: '+15551234567' }, headers: headers, as: :json
        response.status
      end
    end
    pid = Timeout.timeout(8) { patch_pid.pop }
    Timeout.timeout(8) do
      sleep(0.01) until ActiveRecord::Base.connection.select_value(
        "SELECT wait_event FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
      ) == 'advisory'
    end
    # The PATCH should wait on the account phone advisory, not lock Contact
    # first and form a cycle with the merger's advisory -> Contact order.
    expect(Contact.where(id: contact.id).lock('FOR UPDATE NOWAIT').first).to be_present
    release_merge << true
    expect(Timeout.timeout(8) { patch_writer.value }).to eq(200)
    Timeout.timeout(8) { merge_writer.value }
    expect(contact.reload).to have_attributes(owner_id: owner.id, phone_number: '+15551234567')
    expect(Contact.exists?(mergee.id)).to be(false)
  ensure
    release_merge << true if merge_writer&.alive?
    [merge_writer, patch_writer].compact.each { |worker| worker.kill if worker.alive? }
    [merge_writer, patch_writer].compact.each(&:join)
    AutomationEvent.where(account_id: account.id).delete_all if account&.persisted?
    Contact.where(account_id: account.id).destroy_all if account&.persisted?
    account.destroy! if account&.persisted?
  end
end
