require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageServiceHelpers do
  subject(:helper) do
    Class.new do
      include Whatsapp::IncomingMessageServiceHelpers
    end.new
  end

  describe '#message_content_attributes' do
    it 'normalizes a Flow response webhook' do
      message = {
        type: 'interactive',
        interactive: {
          type: 'nfm_reply',
          nfm_reply: {
            name: 'flow',
            body: 'Sent',
            response_json: '{"flow_token":"appointment-42","slot":"10:30"}'
          }
        }
      }.with_indifferent_access

      attributes = helper.message_content_attributes(message)

      expect(helper.message_content(message)).to eq('Sent')
      expect(attributes).to include(
        whatsapp_message_type: 'interactive',
        interactive_reply_type: 'nfm_reply',
        whatsapp_flow_response: {
          'name' => 'flow',
          'body' => 'Sent',
          'response' => { 'flow_token' => 'appointment-42', 'slot' => '10:30' }
        }
      )
    end

    it 'normalizes an address message submission webhook' do
      message = {
        type: 'interactive',
        interactive: {
          type: 'nfm_reply',
          nfm_reply: {
            name: 'address_message',
            body: 'Address submitted',
            response_json: '{"name":"Ada","address":"42 Meta Way","in_pin_code":"560001"}'
          }
        }
      }.with_indifferent_access

      attributes = helper.message_content_attributes(message)

      expect(attributes[:whatsapp_address_response]).to eq(
        'name' => 'address_message',
        'body' => 'Address submitted',
        'response' => {
          'name' => 'Ada',
          'address' => '42 Meta Way',
          'in_pin_code' => '560001'
        }
      )
    end

    it 'normalizes an order webhook without treating it as media' do
      message = {
        type: 'order',
        order: {
          catalog_id: 'catalog-1',
          text: 'Love these!',
          product_items: [{
            product_retailer_id: 'sku-7',
            quantity: 2,
            item_price: 30,
            currency: 'USD'
          }]
        }
      }.with_indifferent_access

      attributes = helper.message_content_attributes(message)

      expect(helper.message_content(message)).to eq('Love these!')
      expect(attributes[:whatsapp_order]).to eq(
        'catalog_id' => 'catalog-1',
        'text' => 'Love these!',
        'product_items' => [{
          'product_retailer_id' => 'sku-7',
          'quantity' => 2,
          'item_price' => 30,
          'currency' => 'USD'
        }]
      )
    end

    it 'preserves malformed NFM response JSON without raising' do
      message = {
        type: 'interactive',
        interactive: {
          type: 'nfm_reply',
          nfm_reply: { name: 'flow', response_json: '{invalid' }
        }
      }.with_indifferent_access

      response = helper.message_content_attributes(message).dig(:whatsapp_flow_response, 'response')

      expect(response).to eq('_raw' => '{invalid', '_invalid_json' => true)
    end
  end
end
