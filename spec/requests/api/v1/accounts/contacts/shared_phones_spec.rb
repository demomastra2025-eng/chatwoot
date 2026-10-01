require 'rails_helper'

# M4 option A block, M5(b) hint, preview and promotion button. Permission parity with the contact merge action.
RSpec.describe 'Contact shared phone API', type: :request do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:web_inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: nil) }
  let(:booking) { shared_phone_chat(account, mother, web_inbox, '55555@lid').last }
  let(:son) do
    card = shared_phone_card(account, mother, via: 'booking_chat')
    card.update!(custom_attributes: card.custom_attributes.merge(Contacts::SharedPhone::SHARED_CONVERSATION_KEY => booking.id))
    card
  end

  def path(contact = son, action = nil) = ["/api/v1/accounts/#{account.id}/contacts/#{contact.id}/shared_phone", action].compact.join('/')

  # The card with the capabilities switched on (they ship off, see Contacts::SharedPhoneSwitches and the context below).
  before { enable_shared_phone_switches! }

  it 'shows where the card notifications go with masked numbers only', :aggregate_failures do
    create(:scheduling_appointment, account: account, contact: mother, conversation: booking, patient_contact: son, starts_at: 2.days.from_now,
                                    ends_at: 2.days.from_now + 30.minutes)
    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('patient_card' => true, 'own_conversations_count' => 0, 'hint' => nil, 'promotion_preview' => nil)
    expect(response.parsed_body['route']).to include('kind' => 'booking_chat', 'contact' => { 'id' => mother.id, 'name' => 'Mother' },
                                                     'masked_phone' => '+7 *** ***-**-09', 'conversation_display_id' => booking.display_id)
    expect(response.body).not_to include('77000000009')
  end

  context 'with a released number (hint)' do
    let(:cloud_inbox) { shared_phone_cloud_inbox(account) }

    before do
      mother.update!(phone_number: '+77000000008')
      shared_phone_chat(account, mother, cloud_inbox, phone.delete('+'))
      son.update!(custom_attributes: son.custom_attributes.merge(Contacts::SharedPhone::SHARED_VIA_KEY => 'owner_primary'))
      Contacts::SharedPhoneHint.write!(son, phone: phone, previous_holder_id: mother.id, reason: 'released', candidate_ids: [son.id])
    end

    it 'shows the hint with the transfer preview and promotes on confirmation', :aggregate_failures do
      get path, headers: headers, as: :json
      body = response.parsed_body
      expect(body['hint']).to include('masked_phone' => '+7 *** ***-**-09', 'previous_holder' => { 'id' => mother.id, 'name' => 'Mother' })
      expect(body['promotion_preview']).to include('contact_inboxes_count' => 1, 'messages_count' => 1, 'not_moved_lid_chats_count' => 0,
                                                   'previous_holder' => { 'id' => mother.id, 'name' => 'Mother' })
      expect(response.body).not_to include('77000000009')

      post path(son, 'promote'), params: { fingerprint: body.dig('promotion_preview', 'fingerprint') }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('promoted' => true, 'moved' => { 'contact_inboxes' => 1, 'conversations' => 1, 'messages' => 1 })
      expect(son.reload.phone_number).to eq(phone)
      expect(ContactInbox.find_by(inbox: cloud_inbox, source_id: phone.delete('+')).contact_id).to eq(son.id)
      expect(booking.reload.contact_id).to eq(mother.id)
    end

    it 'answers 409 for a stale preview or a number taken meanwhile', :aggregate_failures do
      post path(son, 'promote'), params: { fingerprint: 'stale' }, headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('SHARED_PHONE_STATE_CHANGED')

      get path, headers: headers, as: :json
      fingerprint = response.parsed_body.dig('promotion_preview', 'fingerprint')
      create(:contact, account: account, phone_number: phone)
      post path(son, 'promote'), params: { fingerprint: fingerprint }, headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('SHARED_PHONE_TAKEN')
    end

    it 'dismisses the hint' do
      post path(son, 'dismiss_hint'), headers: headers, as: :json
      expect(response).to have_http_status(:no_content)

      get path, headers: headers, as: :json
      expect(response.parsed_body['hint']).to be_nil
    end

    def number_chat_state
      chat = ContactInbox.find_by(inbox: cloud_inbox, source_id: phone.delete('+'))
      senders = Message.incoming.where(conversation: chat.conversations).pluck(:sender_id)
      [son.reload.phone_number, chat.contact_id, chat.conversations.pluck(:contact_id), senders,
       son.custom_attributes.key?(Contacts::SharedPhone::TRANSFERS_KEY)]
    end

    it 'shows no hint, preview or button and refuses the promotion while manual promotion is switched off', :aggregate_failures do
      disable_shared_phone_switches!
      before_state = number_chat_state

      get path, headers: headers, as: :json
      expect(response.parsed_body).to include('manual_promotion_enabled' => false, 'hint' => nil, 'promotion_preview' => nil)
      expect(response.parsed_body['route']).to be_present

      post path(son, 'promote'), params: { fingerprint: 'any' }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('SHARED_PHONE_PROMOTION_DISABLED')
      expect(number_chat_state).to eq(before_state)
      expect(before_state.first(2)).to eq([nil, mother.id])
    end

    it 'refuses a promotion that would move the chats of the number while history transfer is switched off', :aggregate_failures do
      disable_shared_phone_switches!(Contacts::SharedPhoneSwitches::HISTORY_TRANSFER)
      before_state = number_chat_state
      get path, headers: headers, as: :json
      expect(response.parsed_body['manual_promotion_enabled']).to be(true)

      post path(son, 'promote'), params: { fingerprint: response.parsed_body.dig('promotion_preview', 'fingerprint') }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('SHARED_PHONE_HISTORY_TRANSFER_DISABLED')
      expect(number_chat_state).to eq(before_state)
    end
  end

  it 'answers 422 when the contact has no promotable number' do
    post path(create(:contact, account: account), 'promote'), params: { fingerprint: 'x' }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['code']).to eq('SHARED_PHONE_NOT_ELIGIBLE')
  end

  it 'is not available for another account contact or without authentication', :aggregate_failures do
    get "/api/v1/accounts/#{account.id}/contacts/#{create(:contact).id}/shared_phone", headers: headers, as: :json
    expect(response).to have_http_status(:not_found)

    get path, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
